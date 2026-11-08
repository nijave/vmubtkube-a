# CI flakiness investigation (2026-11-06)

Scope: the Woodpecker pipeline in `.woodpecker.yaml` / `.ci/`, plus the cluster-side
Woodpecker server + agent that run it. Evidence comes from Woodpecker's own step
metrics (`woodpecker_step_failures_total`, `woodpecker_step_duration_seconds`) in the
`thanos-query` API and from container logs retained in HyperDX ClickHouse
(`otel.otel_logs`, ns `woodpecker`, 30-day retention).

## What actually fails

Hard failures (red X) over the last 90 days, all repos on this agent:

| repo | step | failures (90d) | first observed cause |
|---|---|---|---|
| nijave/vmubtkube-a | `validate-helm` | 2 | `context deadline exceeded` fetching an upstream chart index |
| nijave/vmubtkube-a | `validate` | 13 (2026-10-08..10-10 only) | `could not find schema for SecretStore` (CRDs-catalog regression, since pinned) |
| nijave/vmubtkube-a | `vendir-sync` | 1 | (2026-10-13) |
| nijave/cukk | `lint` | 1 | |

So the current red-X rate is low (2 failures in 90 days for this repo), but the tail
is expensive and the system burns a lot of work per pipeline. p50/p95 step duration
(7-day rate window):

| step | p50 | p95 |
|---|---|---|
| `validate` | 41 s | 187 s |
| `validate-helm` | 49 s | 248 s |
| `validate-prom-selectors` | 50 s | 250 s |
| `validate-pluto` | 19 s | 29 s |
| `mirror-images` | 19 s | 29 s |
| `git` (clone) | 20 s | 29 s |

The two failing runs, verbatim:

```
2026-11-04 18:21:30  Error: looks like "https://charts.external-secrets.io" is not a valid
                     chart repository or cannot be reached: Get ".../index.yaml":
                     context deadline exceeded (Client.Timeout exceeded while awaiting headers)
2026-11-06 13:38:47  Error: looks like "https://open-telemetry.github.io/opentelemetry-helm-charts"
                     is not a valid chart repository or cannot be reached: ...
```

Both are `helm`'s 150 s client timeout on a public chart index, i.e. a pure
external-network flake on the critical path of a required check.

## Root cause 1 (dominant, mostly latent): concurrent schema-mirror init in a shared workspace

`.ci/validate.sh` and `.ci/validate-helm.sh` both call `.ci/sync-schemas.sh` with
`SCHEMA_MIRROR=.tmp/schemas`, and they start at the same second. All step pods of a
workflow share one workspace PVC (see `woodpecker/application.woodpecker.yaml`:
`WOODPECKER_BACKEND_K8S_STORAGE_RWX: "false"` + hard pod affinity, single
`wp-<workflow>-0-default` PVC), so both run git against the *same* directory. Neither
clone-into-place nor `sparse-checkout add` is safe under that concurrency:

```
2026-11-06 22:47:14  (validate)         schema mirrors ready in .tmp/schemas (v1.36.6-standalone-strict)
2026-11-06 22:47:16  (validate-helm)    fatal: no sparse-checkout to add to
2026-11-06 22:47:16  (validate-helm)    WARNING: schema mirror sync failed; continuing with what's on disk
2026-11-06 22:47:16  (validate-helm)    WARNING: schema mirror unusable; validating against remote locations
```

Also seen: `fatal: Unable to create '.../kubernetes-json-schema/.git/index.lock': File exists.`

Frequency (last 30 days, `wp-*` pods): the loser of the race is `validate-helm` on
**~90% of pipelines** — 18/20 on 2026-11-06, 28/31 on 2026-11-01, 18/35 on 2026-10-30,
and on every day checked back to 2026-10-29.

Consequence: `validate-helm` falls back to the remote schema locations and does
hundreds of `raw.githubusercontent.com` object fetches per run (kubeconform never
caches misses) for all 27 Helm renders. That is exactly the path the file headers in
`.ci/validate.sh` / `sync-schemas.sh` call "flaky, unauthenticated". It costs wall
time and widens the window for the chart-download timeouts above.

Cost of the mirror itself: the mirror is **734 MB** (499 MB
`kubernetes-json-schema` + 236 MB `CRDs-catalog`), cloned from scratch into the
ephemeral per-workflow iSCSI PVC on every pipeline (~21 pipelines/day ≈ 15 GB/day of
clone + iSCSI write + teardown), and ~20 s of the critical path of `validate`.

## Root cause 2: every chart is downloaded twice per pipeline, from the public internet

`validate-helm.sh` and `validate-prom-selectors.sh` each render **all 27 Helm-source
Applications** through `.ci/lib/render-helm.sh`, which for HTTP repos does
`helm template --repo` (index download + tarball per app) and for OCI does `helm pull`.
That is ~54 chart fetches per pipeline across ~25 upstream repos, with no cache
(all step pods are ephemeral), no retry, and no local mirror. `helm`'s default 150 s
client timeout means a single slow index costs 2.5 minutes before failing.

`vendir.yml` already vendors some charts, but chart *validation* still goes upstream.

## Root cause 3: control-plane restarts drop in-flight workflows

Server-side log classes over 30 days (`woodpecker-server-0`):

- 4× `error running server: http: Server closed` (2026-10-17, 10-28, 10-31, 11-01) —
  pod rolled/replaced (node reboot window or ArgoCD rollout of a chart bump).
- 14× `queue: task not found` (workflow lease extension failed because the queued task
  vanished), most right after those restarts: 2 at 00:42 and 02:28 following the
  2026-11-01 00:39 restart. Agent side: `failed to extend workflow lease` +
  `connection to server lost, shutting down agent` + `grpc: connection lost, giving up`.
- 8× `error setting commit status …: context deadline exceeded` and 9×
  `POST https://api.github.com/.../statuses/...: 500` — GitHub's status API flaking.
  When that call fails the required check can stay stale/pending on the PR, which looks
  exactly like "CI is stuck" to the merge queue.

Note `WOODPECKER_GRPC_SECRET` is unset (only `WOODPECKER_DATABASE_*` is in
`woodpecker-server-env`), so every server start generates a throwaway gRPC secret and
logs a warning; that also blocks ever running 2 server replicas. And the agent keeps
`WOODPECKER_RETRY_TIMEOUT` at its 2 min default, so a restart longer than that turns
into "giving up" and a lost workflow.

## Recommendations (ordered by impact per unit of effort)

### 1. One cache-preparing step, so caches are written by exactly one pod

Add a `prepare` step with no dependencies that (a) materializes the schema mirror and
(b) `helm pull`s every chart tarball once into `.tmp/charts` with retries. Everything
else `depends_on: [prepare]` and only reads. This single change removes root cause 1 by
construction, halves chart fetches, and gives one place to put retries.

Sketch:

```yaml
steps:
  prepare:
    image: alpine/k8s:1.37.2
    environment:
      SCHEMA_MIRROR: .tmp/schemas
      HELM_CHART_CACHE: .tmp/charts
    commands:
      - sh .ci/prepare-cache.sh
  validate:
    depends_on: [prepare]
  validate-helm:
    depends_on: [prepare]   # and drop the `when: path` gate's independent start
  validate-prom-selectors:
    depends_on: [prepare]
```

### 2. Make `sync-schemas.sh` concurrency-safe anyway (belt and braces)

Cheap and removes a whole class of silent fallback:

- Guard the whole body with an atomic `mkdir "$MIRROR/.lock"` spin (busybox `flock` is
  also available on alpine), with stale-lock age check and a bounded wait.
- Clone into `$MIRROR/.kjs.$$` and `mv` into place (atomic on the same filesystem)
  instead of cloning directly into the final path.
- On failure, print the git error and exit non-zero so CI fails fast with the real
  message, rather than three "WARNING: … continuing" lines and a remote crawl.

### 3. Stop downloading the schema mirror per pipeline

Either of these removes ~734 MB of churn and ~20 s per pipeline:

- **Bake it into a CI tools image** (see #4): schemas as a layer are pulled once per
  node by containerd and reused by every step pod.
- **Serve it in-cluster**: a small static mirror (PVC + web server + a weekly CronJob
  that re-syncs), and have `sync-schemas.sh` fetch one tarball over the cluster
  network. No external dependency at run time, no per-pipeline iSCSI write.

### 4. Build a pinned CI tools image

The pipeline currently downloads four GitHub release tarballs per pipeline
(kubeconform, pluto, vendir ×1, plus each step's own copy) plus `apk add yq jq git` in
`mirror-images`, with no checksum verification. One image on
`registry.apps.nickv.me/ci/woodpecker-tools:<ver>` containing kubeconform, pluto,
vendir, helm, yq, jq, kustomize, git, curl, regctl:

- removes 5+ network fetches and their flake surface per pipeline;
- removes the `datasource=github-releases` pins from `.woodpecker.yaml` (Renovate then
  tracks one image instead of four binaries);
- makes the toolchain reproducible by digest.

Keep the `alpine/k8s` image only where `kubectl` is needed, or include it too.

### 5. Retry and cache at the network edges

Independent of the above, and worth doing even if #1/#4 land:

- Wrap `helm pull`/`helm template` in 3 attempts with backoff, and replace
  `helm template --repo` with `helm pull --repo ... -d $cache` + `helm template
  $cache/<chart>-<ver>.tgz`, so a chart is fetched at most once and can be retried
  per chart instead of failing the whole step.
- `wget --tries=3 --timeout=30 --waitretry=5` for tool downloads.
- Consider `helm template --timeout` reduction so a dead repo fails in ~30 s instead of
  150 s, with retries absorbing the transient case.

### 6. Merge `validate-helm` and `validate-prom-selectors`

Both render the same 27 Applications. Render once, then run kubeconform+pluto and the
jq selector check over the same output. Fewer steps, fewer required-check failure
points, ~50 s less work per pipeline, and it removes the second consumer that makes
the cache race in #1 possible in the first place.

### 7. Control-plane resilience

In `woodpecker/application.woodpecker.yaml`:

- `WOODPECKER_GRPC_SECRET` from a persistent secret (silences the per-start warning,
  makes restarts deterministic, and is a prerequisite for ever running 2 replicas).
- Agent: `WOODPECKER_RETRY_TIMEOUT: "0"` (retry forever) or a long value, plus
  `WOODPECKER_KEEPALIVE_TIME: 30s` so a dead gRPC connection is noticed before the
  workflow lease expires. This is what turns a server restart from "workflow lost, PR
  needs a manual re-run" into "pipeline resumes".
- Set the repo's pipeline timeout (repo settings, default 60 min) to ~15 min, so a
  hung step fails in minutes instead of leaving the PR check pending for an hour.

### 8. Alert on the flake classes instead of discovering them via stuck PRs

Add a `woodpecker-alerts.yaml` next to the existing `argocd-alerts.yaml` /
`scrape-failure-alerts.yaml` rules:

- `increase(woodpecker_step_failures_total[1h]) > 0` (per step) — catches real failures
  and flake alike;
- `woodpecker_pending_steps > 0` for 10 min — stuck queue / lost lease;
- `changes(kube_pod_container_status_restarts_total{namespace="woodpecker"}[1h]) > 0`
  or pod-age reset on `woodpecker-server-0` — restarts that silently drop workflows;
- Loki/ClickHouse-style log rule for `error setting commit status` — a stale check is
  otherwise invisible until someone stares at the PR.

### 9. Uncomment the push-to-main backstop

`mirror-images` was designed to also re-mirror on push to main ("self-healing
backstop"), but that `when:` block is commented out, so a missed PR mirror is never
repaired. Enable it once #1 makes the pipeline cheap enough to run twice per change.

## What we are not changing

- The clone depth (25) and `partial: false` are fine: `git` step p50 is 20 s.
- `mirror-images` is not a flake source (p50 19 s, p95 29 s, 0 failures in 90 days).
