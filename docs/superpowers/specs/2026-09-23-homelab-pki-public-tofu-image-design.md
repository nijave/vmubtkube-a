# homelab-pki: public OpenTofu image, ConfigMap config, PVC provider cache

**Date**: 2026-09-23
**Status**: Design — approved in session, pending implementation plan

---

## Problem

`registry.apps.nickv.me/nijave/homelab-pki` is a hand-built image bundling the
OpenTofu binary and the `tofu/` config. Every HCL change (device add/remove,
revocation, provider bump) requires a local `docker build`/`push`, a tag bump
in the manifest, and an Argo sync. Each in-cluster run also starts from an
empty workspace: `tofu init` re-resolves and re-downloads providers on every
reconcile. The image exists only to carry a static binary and five small text
files.

## Solution

Delete the image. Run the Job/CronJob on the official
`ghcr.io/opentofu/opentofu` image (Alpine-based; git/bash/openssh/ca-certs
included; `ENTRYPOINT tofu` overridden by the pod `command`). Ship the config
as a kustomize-generated, hash-suffixed ConfigMap mounted read-only at
`/config`. Commit `.terraform.lock.hcl` so provider versions are pinned in
git. Point `TF_DATA_DIR` and the plugin cache at a 10Gi PVC so nothing is
re-downloaded after the first run. Renovate owns both the image tag (docker
datasource) and provider bumps (terraform manager rewrites the lock file in
the same PR). The result: HCL changes are commit-and-sync; ad-hoc tofu runs
use the same image and mounts.

Direct `ghcr.io` pulls at runtime (user decision); no mirror entry.

On OpenTofu's "official images not supported for direct use" (1.10+): the
blocker is an `ONBUILD RUN exit 1` trap that breaks builds which `FROM` the
image. Runtime use never evaluates `ONBUILD`, so the image runs as-is. The
unsupported-ness is an upstream support policy, accepted here.

## Design decisions

| Concern | Decision |
|---|---|
| Image | `ghcr.io/opentofu/opentofu:<exact semver>`, direct pull, `imagePullPolicy: IfNotPresent`, renovate annotation `# renovate: datasource=docker depName=ghcr.io/opentofu/opentofu` |
| Config delivery | kustomize `configMapGenerator` (`homelab-pki-tofu-config`) from the six files in `tofu/`, hash-suffixed, mounted read-only at `/config` |
| Version pinning | `.terraform.lock.hcl` committed in `homelab-pki/tofu/`, included in the ConfigMap; `tofu init -lockfile=readonly` as the drift backstop |
| Tofu writes | `TF_DATA_DIR=/tofu/data`, `TOFU_PLUGIN_CACHE_DIR=/tofu/plugin-cache` — both on the PVC, never on `/config` |
| Cache volume | PVC `pki-tofu-cache`, 10Gi, RWO, `zfs-generic-iscsi-csi`, no annotations (regenerable cache; plain prune is fine, no volsync backup) |
| App structure | `homelab-pki/` kustomize app (fluentbit pattern) + root `application.homelab-pki.yaml` child Application; root `homelab-pki.yaml` deleted |
| Provider bumps | Renovate terraform manager (default `**/*.tf` patterns already cover the dir): constraint + lock file in one PR; repo-wide `lockFileMaintenance` refreshes locked versions |
| State | Unchanged: `kubernetes` backend, Secret in `homelab-pki`, `in_cluster_config` |

## Repo layout after the change

```
homelab-pki/
  kustomization.yaml          # namespace: homelab-pki; resources + configMapGenerator
  rbac.yaml                   # SA/Role/RoleBinding pki-reconciler + ExternalSecret pki-ca
  pvc.yaml                    # pki-tofu-cache
  reconcile-job.yaml          # Argo Sync-hook Job
  crl-refresh-cronjob.yaml    # 6h CronJob
  tofu/                       # *.tf + committed .terraform.lock.hcl
  README.md                   # rewritten runbook
application.homelab-pki.yaml  # root child-Application (like application.fluentbit.yaml)
namespace.homelab-pki.yaml    # unchanged, stays root-managed
```

`namespace.homelab-pki.yaml` stays at the root so the child app never manages
its own namespace.

The `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: homelab-pki
resources:
  - rbac.yaml
  - pvc.yaml
  - reconcile-job.yaml
  - crl-refresh-cronjob.yaml
configMapGenerator:
  - name: homelab-pki-tofu-config
    files:
      - tofu/main.tf
      - tofu/ca.tf
      - tofu/devices.tf
      - tofu/locals.tf
      - tofu/crl.tf
      - tofu/.terraform.lock.hcl
```

Hash suffixes stay enabled: any `.tf`/lock change produces a new ConfigMap
name, kustomize's nameReference rewrite updates the Job/CronJob volume refs,
and the child app sync rolls both. Workload manifests rely on the
kustomization-level `namespace` (fluentbit pattern); no per-resource
namespace fields inside the dir.

### projectcontour RBAC move

The `pki-crl-reader` trio (ServiceAccount in `projectcontour`, Role +
RoleBinding in `homelab-pki`) cannot live under `namespace: homelab-pki` —
the kustomize namespace transformer would rewrite the ServiceAccount into
`homelab-pki`. The trio moves verbatim into root `python-envoy-authz.yaml`,
next to the CRL-copy ExternalSecret that consumes it. It stays root-app-owned
(no ownership migration for these three objects).

## Workload runtime

Job `pki-reconcile` (Argo Sync hook, `BeforeHookCreation`) and CronJob
`pki-crl-refresh` (`0 */6 * * *`, `Forbid`) keep their names, ServiceAccount,
RBAC, resources (50m/128Mi → 1/512Mi), backoff/ttl settings. The container
becomes:

```yaml
containers:
  - name: reconcile
    # renovate: datasource=docker depName=ghcr.io/opentofu/opentofu
    image: ghcr.io/opentofu/opentofu:<exact semver pinned at implementation>
    imagePullPolicy: IfNotPresent
    command: ["/bin/sh", "-c"]
    args:
      - |
        set -eux
        tofu -chdir=/config init -input=false -no-color -lockfile=readonly
        tofu -chdir=/config apply -input=false -auto-approve -no-color
    env:
      - name: TF_DATA_DIR
        value: /tofu/data
      - name: TOFU_PLUGIN_CACHE_DIR
        value: /tofu/plugin-cache
    volumeMounts:
      - name: config
        mountPath: /config
        readOnly: true
      - name: tofu-cache
        mountPath: /tofu
    resources: ...
volumes:
  - name: config
    configMap:
      name: homelab-pki-tofu-config   # kustomize rewrites to the hashed name
  - name: tofu-cache
    persistentVolumeClaim:
      claimName: pki-tofu-cache
```

- `-chdir=/config` plus `TF_DATA_DIR` keeps every tofu write off the
  read-only mount; `-lockfile=readonly` turns lock/config drift into a loud
  job failure instead of silent re-resolution.
- The first run warms the plugin cache (one download per provider); later
  runs resolve from the lock and hardlink from the cache (`TF_DATA_DIR` and
  the cache share the PVC filesystem). No registry traffic on routine runs.
- Env var spellings (`TF_DATA_DIR`, `TOFU_PLUGIN_CACHE_DIR`) and
  `-lockfile=readonly` support are verified against the running `tofu`
  during implementation; adjust names there if OpenTofu expects others.
- Pin the tag to the newest stable OpenTofu at implementation time (the
  retired Dockerfile used the 1.12 line; `main.tf` requires `>= 1.11.0`).

### Reconcile trigger change

Today the Sync-hook Job runs on every **root** app sync — any repo change
triggers a tofu apply. After the move it fires on **child app** syncs only
(homelab-pki dir changes: HCL, lock, image tag). CRL freshness between
changes stays covered by the 6h CronJob. Fewer no-op reconciles; same
convergence.

## Lock file workflow

1. Bootstrap once, locally: `cd homelab-pki/tofu && tofu init -backend=false`
   → commit the generated `.terraform.lock.hcl`. Local host and cluster
   workers are both linux/amd64, so the `h1:` checksum set covers the
   cluster platform.
2. Renovate handles updates from there: provider constraint bumps rewrite
   the lock in the same PR (sibling-lockfile discovery, registry-computed
   signed hashes — verified in current Renovate source), and the
   repo-wide `lockFileMaintenance` refreshes locked versions within
   constraints.
3. Manual fallback for hand-edited constraints: regen locally with
   `tofu init -backend=false`, commit constraint + lock together.
4. `homelab-pki/tofu/.terraform/` goes into `.gitignore`.

If a constraint ever lands without its lock update, the job fails at
`init -lockfile=readonly` — visible in the child app, not silent drift.

## Cleanup

- Delete `homelab-pki/Dockerfile`.
- `renovate.json`: remove the `registry.apps.nickv.me/nijave/homelab-pki`
  package rule. No terraform rules added (defaults cover the dir; the
  kubernetes manager does not scan `homelab-pki/`, so no duplicate-dep
  conflict).
- `application.blackbox-exporter.yaml`: remove the
  `renovate-releases-homelab-pki` scrape target. The renovate-release-api
  service stays (cukk, python-envoy-authz, yt-dlp, cpu-benchmark still use
  it).
- `.ci/validate.sh`: add `homelab-pki/` to the hand-written exclusion regex
  (line 93) — the kustomize-overlays loop picks up the new kustomization
  automatically.
- `TODO.md` line 72 mentions homelab-pki's renovate tag handling — touch up.
- Rewrite `homelab-pki/README.md` (below).
- Deleting the old image/tags from `registry.apps.nickv.me` is a manual
  registry task, out of scope.

## Ad-hoc runs (README runbook)

- On-demand full reconcile:
  `kubectl -n homelab-pki create job --from=cronjob/pki-crl-refresh pki-manual-<name>`
- Rotations and one-off tofu invocations (e.g.
  `tofu -chdir=/config apply -auto-approve -replace='pki_private_key.device["<name>"]'`):
  commit a temporary Job manifest into `homelab-pki/` and list it in
  `kustomization.yaml` resources — reference the ConfigMap by its base name
  and let the nameReference rewrite fill in the current hash. Argo applies
  it once; remove the file afterward (`ttlSecondsAfterFinished` also ages
  it out; Argo prunes it on the next sync).
- README also documents: device add/remove = edit `locals.tf`, commit;
  revocation = add serial to `local.revoked_serials`, commit; provider
  bump workflow per the lock file section.

## Migration sequencing

All changes land in one commit/PR:

1. Add `homelab-pki/{kustomization.yaml,rbac.yaml,pvc.yaml,reconcile-job.yaml,crl-refresh-cronjob.yaml}`,
   the committed lock file, rewritten README; delete the Dockerfile.
2. Root: delete `homelab-pki.yaml`, add `application.homelab-pki.yaml`,
   move the projectcontour RBAC trio into `python-envoy-authz.yaml`.
3. renovate.json rule removal, blackbox scrape removal, validate.sh
   exclusion, `.gitignore` entry, TODO touch-up.

Rollout: the root app sync creates the child Application and prunes what it
still tracks. Expected path: the child app's SSA apply flips Argo's tracking
labels on the existing objects first (PruneLast defers the root's prune), so
the handoff is seamless. Worst case: a seconds-long delete/recreate of the
ExternalSecret/CronJob/RBAC if the root's prune wins the race. Cert Secrets,
per-device Secrets, and the tofu state Secret are not Argo-managed — nothing
irreplaceable is exposed to the race.

## Risks (homelab-calibrated)

| Risk | Rating | Notes |
|---|---|---|
| Concurrent `tofu init` on the shared plugin cache (Sync-hook Job overlapping the CronJob) | Low | Tofu documents the cache as not concurrency-safe; worst case is a corrupted cached provider → job fails → retry re-downloads. State lock already serializes applies. |
| RWO attach race if both pods land on different nodes | Low | Brief Pending pod, self-resolving. |
| Root→child ownership handoff race | Low | Covered above; converges either way. |
| `ghcr.io` availability at pod start | Accepted | Direct-pull decision; `IfNotPresent` plus node-cached image dampens it. |
| Renovate lockfile updates misbehave | Low | Verified in source; if a PR produces a bad lock, `-lockfile=readonly` fails the job visibly and the fallback is a manual regen. |

## Verification checklist (implementation gates)

1. `kustomize build homelab-pki/` renders; the hashed ConfigMap name appears
   in both workload volume refs; `.terraform.lock.hcl` is a ConfigMap key;
   kubeconform passes (CI validate step green).
2. Local: `cd homelab-pki/tofu && tofu init -backend=false && tofu validate`
   succeeds; lock contains linux_amd64 `h1:` hashes.
3. Confirm env spellings against the pinned image (`tofu help environment`
   or equivalent): `TF_DATA_DIR`, `TOFU_PLUGIN_CACHE_DIR`; confirm
   `-lockfile=readonly` is accepted by `tofu init`.
4. After sync: child app Synced/Healthy; `pki-tofu-cache` Bound; hook Job
   completes; `pki-crl` Secret refresh timestamp advances; CRL consumers
   (`python-envoy-authz`, HA HTTPProxy) still healthy.
5. Second run (CronJob or manual `--from=cronjob`): job logs show no
   provider downloads (cache hit) and no lock-file writes.
6. Renovate picks up the tofu image dep (next run or dry-run) and still
   detects the terraform providers in `homelab-pki/tofu/`.

## Out of scope

- Deleting the old `nijave/homelab-pki` image from the private registry.
- CI step running `tofu init -lockfile=readonly` on PRs — dropped; the job's
  own readonly check is the backstop and renovate now writes the lock.
- Provider-cache pruning keyed on version hash (from the 2026-07-22 design):
  lock-pinned versions make stale entries harmless disk; 10Gi holds hundreds
  of provider versions at current sizes.
- Any change to the CA, cert profile, or reconciliation semantics.
