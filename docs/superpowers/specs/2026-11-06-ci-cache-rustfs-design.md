# CI cross-run cache on rustfs — design

Status: proposed, 2026-11-07. Evidence base: `docs/ci-flakiness-2026-11-06.md`
(step metrics + retained CI logs) and the follow-up artifact survey in the same
investigation.

## Problem

Every pipeline of `nijave/vmubtkube-a` builds its caches from scratch, because
every workflow gets its own ephemeral 10 Gi iSCSI workspace PVC and nothing
outside it persists. Measured per pipeline (~21 pipelines/day):

| Artifact | Per run | Notes |
|---|---|---|
| kubeconform ×2, pluto ×2, vendir | 69 MB from github.com releases | no cache, no checksum |
| k8s schema mirror | 19 MB git objects + **734 MB** written into the ephemeral PVC | `sync-schemas.sh` |
| 23 Helm chart tarballs | 2.2 MB but ~60–90 s | 23 `index.yaml` round trips; the only reproducible red build (PRs #1140, #1141) |

Woodpecker's k8s backend cannot mount an existing PVC into step pods unless it
is `ReadWriteMany`, and the cluster has no RWX StorageClass (only
`zfs-generic-iscsi-csi*`, RWO iSCSI; NFS is a "FUTURE" note in
`woodpecker/application.woodpecker.yaml`). Pinning all CI to one node to allow
an RWO cache volume would also pin all concurrency to that node.

## Decision

Run a dedicated single-node S3 endpoint (rustfs) in the `woodpecker` namespace,
backed by its own RWO iSCSI PVC, and let pipeline steps talk to it over
ClusterIP. Object storage sidesteps the RWX requirement: exactly one pod ever
mounts the volume, and any step pod on any node reaches the API over the
network — the same shape as the existing `buildkitd` service.

- `woodpecker/rustfs.woodpecker.yaml` — Secret (seed), PVC, Deployment
  (`replicas: 1`, `strategy: Recreate`) with the OTLP metrics sidecar, Service
  (port 80 → container 9000), NetworkPolicy, PodMonitor. Deployed by the existing
  ArgoCD app `woodpecker` (`path: woodpecker/`, non-recursive).
- `rustfs-alerts.yaml` — PrometheusRule at the repo root (namespace
  `monitoring`, `release: prom`, like `argocd-alerts.yaml`): not ready, restart
  looping, volume nearly full, metrics missing.
- Credentials: `secret-generator.v1.mittwald.de/autogenerate: access-key,secret-key`
  with hex encoding, mirroring `postgres-woodpecker-user`. The pipeline gets a
  copy through Woodpecker repo secrets (`cache_access_key`, `cache_secret_key`)
  rather than `WOODPECKER_BACKEND_K8S_ALLOW_NATIVE_SECRETS`, so no agent-wide
  permission is widened.
- Client: `rclone` (S3-provider-agnostic, documented copy/sync/delete semantics,
  and it works against any S3, so the cache is not tied to rustfs).
- Buckets: one bucket `ci-cache`, remote alias `cicache`. Layout:
  `charts/<chart>-<version>.tgz`, `tools/<name>/<version>/<name>`,
  `schemas/<repo>.git.tar` + `schemas/<repo>.head`.

### Cache semantics (the part that keeps CI green)

The cache is an optimisation, never a dependency:

1. **Fail open.** The restore and save steps are `failure: ignore`; every helper
   treats a missing file as a miss and never exits non-zero because of the cache.
2. **Additive saves.** Saves use `rclone copy` (never `sync`/`delete`), so a bad
   run cannot poison the cache.
3. **Version in the key.** Tools are keyed `<name>/<version>`; charts are keyed
   `<chart>-<version>`; a Renovate bump is a miss, not a stale hit.
4. **Download-then-publish ordering.** A `.head` file is written after the
   matching tarball, and the exporter re-exports when the head matches but the
   tarball is absent, so an interrupted save degrades to a miss instead of a
   permanently unreachable entry.
5. **Restores are materialised.** Only git object directories are cached for
   schemas (19 MB), never the 734 MB checkout; the worktree is re-created with
   `git reset --hard HEAD`, which honours the sparse-checkout config stored in
   the cached `.git`.

## Metrics and alerting

rustfs only *pushes* telemetry: it has no Prometheus scrape endpoint
(`docs.rustfs.com/en/operations/observability`). Metrics therefore need a
collector in the path, and that collector can either re-expose them for a scrape
or remote-write them straight to Thanos.

Chosen: **scrape**. An `otel/opentelemetry-collector-contrib` sidecar in the
rustfs pod receives OTLP on `127.0.0.1:4318` and serves the `prometheus` exporter
on `:8889`; a `PodMonitor` (`release: prom`) feeds `prom-kp-prometheus`, which
remote-writes to `thanos-receive-router` exactly as it does for every other
scraped series. So the metrics do land in Thanos — through the relay that already
exists — and they keep the external labels (`cluster`, `tenant_id`) the rest of
the data has.

Rejected: the `prometheusremotewrite` exporter pointed directly at Thanos (the
pattern `otel-agent-trace-connector.yaml` uses for coding-agent metrics). It is
fine for dashboards, but this cluster runs no Thanos Ruler and configures no
`remoteRead` on either Prometheus CR, so a series that never reaches a Prometheus
TSDB is invisible to every `PrometheusRule` — the alerting side of the feature
would be dead on arrival. It would also arrive in Thanos without the external
labels every other series carries.

The sidecar is preferred over reusing `monitoring/otel-collector` because that
collector's `metrics: null` pipeline is a deliberate contract for the
logs/traces path, the sidecar needs no cross-namespace traffic or Service, and
the image is already cached on every node at the same tag.

Alerts are warnings, not pages: the cache is fail-open, so the failure mode is
quietly cold pipelines. The `absent()` rule is what catches a broken metrics
path, which is otherwise indistinguishable from a healthy but unused cache.

### What is deliberately not cached

- Repository clone (1.3 MB at `depth: 25`); `plugin-git` has no cache directory
  and the win is 20 s at most.
- The schema checkout (734 MB). The bytes must exist on the step's disk for
  kubeconform; caching them would move the cost, not remove it. Shrinking the
  sparse set is a separate follow-up.
- Rustfs data is not backed up, not snapshotted (`homelab:sanoid-skip`,
  `syncoid:sync: false` on the zvol) and carries no `PodDisruptionBudget` — a
  single-replica PDB would deadlock node drains. Losing the cache costs one cold
  run.
- Garbage collection: chart/tool entries only grow when a version changes
  (≈20 MB/month at current Renovate churn). No GC job until that is measurable.

## Alternatives considered

- **Bake tools + schemas into a CI image.** Best bytes/time ratio for read-only
  content and no new service, but it cannot hold anything CI must write (dep
  caches, per-repo artifacts) and it makes the k8s version pinned at build time.
  Kept as a future option; the rustfs layout does not conflict with it.
- **RWX NFS StorageClass + shared PVC.** Simplest data model, but it is
  infrastructure the cluster does not have yet and it makes the cache a
  scheduling constraint. Rustfs needs neither.
- **Reuse the existing external rustfs (`vmubthh01`).** No new pod, but it is
  outside the cluster, has a documented aws-cli hang quirk, and would couple CI
  to the NAS being up. A cache wants to be local and expendable.
- **Persist the workspace between runs.** Not supported by the backend.

## Out of scope (follow-ups in other repositories)

`nijave/python-envoy-authz` recreates its venv and reinstalls Poetry plus the
full dependency tree in three separate steps per pipeline (p50: lint 45 s, test
20 s, coverage 20 s); `nijave/cukk` runs `uv sync --frozen` in two steps with no
`UV_CACHE_DIR`, so uv's cache lives in an ephemeral container. Both would benefit
from this bucket (keyed per repo + lockfile hash) or from moving dependencies
into the images they already build. Recorded in `TODO.md`; no changes here.
