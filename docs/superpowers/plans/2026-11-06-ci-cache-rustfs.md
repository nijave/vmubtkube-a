# CI cross-run cache on rustfs — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Woodpecker pipeline a persistent, fail-open S3 cache so tools, Helm chart tarballs and kubeconform schema mirrors survive between runs instead of being re-downloaded (69 MB + 734 MB of PVC writes + ~90 s of chart-index latency per pipeline), and make that cache observable so its silent failure mode (cold pipelines) shows up as a metric and an alert.

**Architecture:** A dedicated single-node rustfs pod in the `woodpecker` namespace owns an RWO iSCSI PVC; step pods reach it over ClusterIP on Service port 80, which sidesteps the missing RWX StorageClass (only one pod ever mounts the volume, exactly like `buildkitd`). One bucket `ci-cache` with three prefixes (`charts/`, `tools/`, `schemas/`) is restored into the shared workspace by an rclone step before `prepare`, and uploaded afterwards by a second rclone step. Every cache path is fail-open: misses and corrupt entries only cost time. rustfs pushes telemetry over OTLP only, so a collector sidecar re-exposes its metrics for scrape; Prometheus alerts on cache health and relays the series to Thanos through its existing remote-write.

**Tech Stack:** Kubernetes (ArgoCD dir app `woodpecker`), rustfs 1.0.4 (S3), rclone 1.76, `otel/opentelemetry-collector-contrib` 0.163.2 (OTLP → Prometheus), kube-prometheus-stack (PodMonitor + PrometheusRule, remote-write to Thanos), Woodpecker 3.x pipeline syntax, POSIX sh helpers under `.ci/`.

**Spec:** `docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`

- **Availability caveat that overrides "fail-open":** Woodpecker resolves `from_secret` at
  compile time (`pipeline/frontend/yaml/compiler`, error `secret %q not found or not allowed to be used`),
  so a missing `cache_access_key`/`cache_secret_key` fails the entire pipeline before any step runs.
  Cache *contents* are fail-open; the credential reference is not. The `cache-secrets-sync` CronJob
  is a prerequisite: deploy it, let it run once, verify the two rows, and only then enable the
  cache steps. A design that keeps the credential out of the pipeline entirely (anonymous bucket,
  or a secret extension whose availability we control) would remove this coupling — rustfs 1.0.4
  documents no anonymous-access support, and the native-secret route is blocked by policy.

## Global Constraints

- rustfs image `rustfs/rustfs:1.0.4`, container listens on `:9000`, health endpoint `/health`, runs as uid/gid `10001`.
- rclone image `rclone/rclone:1.76`; S3 remote alias `cicache`, bucket `ci-cache`, endpoint `http://rustfs.woodpecker.svc.cluster.local` (Service port 80 → container port 9000), path-style addressing, region `us-east-1`.
- Existing pins that must not drift: `alpine/k8s:1.37.2`, kubeconform `v0.8.0`, pluto `v5.24.0`, vendir `v0.46.0`; every image and tool version keeps exactly one `# renovate:` annotation after the migration.
- Namespace `woodpecker`; credentials come from the secret-generator-backed Secret `rustfs-ci-cache` (keys `access-key`, `secret-key`) and reach steps only as Woodpecker repo secrets `cache_access_key` / `cache_secret_key`.
- ArgoCD app `woodpecker` deploys `path: woodpecker/` **non-recursively**, so new manifests must sit directly in `woodpecker/`.
- The cache never gates correctness: `.ci/cache-restore.sh` and `.ci/cache-save.sh` run with `failure: ignore`, and no helper may exit non-zero because of a cache miss.
- Saves are additive (`rclone copy`, never `rclone sync`/`delete`).
- rustfs exposes **no** Prometheus endpoint: it only pushes OTLP. Metrics reach Thanos as `rustfs` (OTLP) → sidecar `otel/opentelemetry-collector-contrib:0.163.2` (`prometheus` exporter on `:8889`) → PodMonitor `release: prom` → `prom-kp-prometheus` → its existing remote-write → `thanos-receive-router`.
- Monitoring resources must be selected or CI fails: the PodMonitor carries `release: prom` in namespace `woodpecker`; the PrometheusRule lives at the repo root in namespace `monitoring` with `release: prom`, matching `argocd-alerts.yaml`.
- No backup, no snapshotting and no `PodDisruptionBudget` for the cache volume or pod.
- Every script is POSIX sh, uses `set -euo pipefail` like its neighbours, and passes `shellcheck -s sh` with only the pre-existing SC3040 (`pipefail` in POSIX sh) warning.

## Review Focus

- **rustfs down / not yet ready:** a workflow that starts while the cache is unavailable must finish green, only slower. Every cache step is `failure: ignore` and both restore/save scripts must exit non-zero *without* leaving partial state; the pipeline still passes.
- **Truncated `.git` tarball:** an interrupted upload must be discarded (whole repo directory removed), never left behind as a `.git` that `sync-schemas.sh` believes is initialised.
- **Head present, tarball missing:** the schema exporter must re-export, so an interrupted save self-heals instead of pinning a permanently unreachable entry.
- **Restored mirror from another Kubernetes version:** the restore must not erase the sparse-checkout config that `sync-schemas.sh` uses to add a new version directory.
- **Zero-length cached tool binary:** must be treated as a miss so `fetch_tool` re-downloads and re-stages it, never copied into `/usr/local/bin`.
- **Metric names drift between rustfs builds:** a rule pinned to a name this build does not emit never fires (`rustfs_capacity_current` vs `..._current_bytes`), while a wrong `absent()` name fires forever — Task 2 Step 10 checks the live series before merge.
- **Metrics silently missing:** if the rustfs pod, its OTLP sidecar, or the scrape stops, no `rustfs_*` series exist and nothing else complains — the `absent()` rule is the only signal that CI has quietly gone cold.
- **Credentials missing or rotated:** restore/save fail loudly in their own log, the run stays green, and the next run is simply cold.

---

## File Structure

| File | Responsibility |
|---|---|
| `woodpecker/rustfs.woodpecker.yaml` (create) | S3 endpoint: Secret, PVC, Deployment (+ OTLP metrics sidecar), Service on port 80, NetworkPolicy, PodMonitor |
| `rustfs-alerts.yaml` (create) | PrometheusRule: cache not ready, restart looping, volume nearly full, metrics missing |
| `.ci/lib/cache.sh` (create) | Pure cache helpers: restore/export schemas, restore/export/fetch tools. No S3 calls |
| `.ci/test/cache-test.sh` (create) | Hermetic tests for `.ci/lib/cache.sh` (temp dirs, real git, no network) |
| `.ci/cache-restore.sh` (create) | rclone download into `.tmp/cache-in` + `.tmp/charts`; creates bucket |
| `.ci/cache-save.sh` (create) | rclone additive upload of `.tmp/cache-out` + `.tmp/charts` |
| `.ci/prepare-cache.sh` (modify) | Installs tools, restores schema objects, runs sync, stages `.tmp/cache-out` |
| `.woodpecker.yaml` (modify) | `cache-restore`, `cache-save`, tool install via `.tmp/bin`, `depends_on` wiring |
| `.pre-commit-config.yaml` (modify) | Run the cache tests locally |
| `README.md`, `TODO.md`, `woodpecker/application.woodpecker.yaml` (modify) | Document the cache; record cross-repo follow-ups; fix a stale cache claim |
| `docs/ci-flakiness-2026-11-06.md` (add, already written) | Evidence the design argues from |

Prerequisite: cut the execution branch from `origin/main` and confirm the
machinery this plan extends is actually present — `.ci/prepare-cache.sh`, the
`prepare` step in `.woodpecker.yaml`, and `HELM_CHART_CACHE` (all introduced by
`ca81d6c`). A branch cut before that merge has none of them, and every task from
3 onward then builds on absent code; this document itself was merged up to
`main` for exactly that reason. Verify before Task 1:

```bash
ls .ci/prepare-cache.sh && grep -n '^  prepare:' .woodpecker.yaml && grep -n HELM_CHART_CACHE .woodpecker.yaml
```

---

### Task 1: rustfs S3 endpoint

**Files:**
- Create: `woodpecker/rustfs.woodpecker.yaml`
- Commit: `docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`, `docs/superpowers/plans/2026-11-06-ci-cache-rustfs.md`, `docs/ci-flakiness-2026-11-06.md`

**Interfaces:**
- Consumes: nothing.
- Produces: Service `rustfs` (port 80 → container port 9000) in namespace `woodpecker`; Secret `rustfs-ci-cache` with keys `access-key`, `secret-key`.

- [ ] **Step 1: Create the manifest**

`woodpecker/rustfs.woodpecker.yaml`:

```yaml
# CI artifact cache: a single-node S3 endpoint for everything the pipeline
# re-downloads on every run. Only this pod mounts the RWO zvol, and step pods
# reach it over ClusterIP from whichever node they land on, which is why object
# storage sidesteps the missing RWX StorageClass. Design:
# docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# The data is a cache: not backed up, not snapshotted, no PodDisruptionBudget
# (a single-replica PDB would block kured drains forever). Losing it costs one
# cold CI run.
---
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-ci-cache
  namespace: woodpecker
  annotations:
    # Hex so the values can never carry a character that needs URL escaping:
    # .ci steps build a S3 endpoint URL out of them.
    secret-generator.v1.mittwald.de/autogenerate: access-key,secret-key
    secret-generator.v1.mittwald.de/encoding: hex
    secret-generator.v1.mittwald.de/length: "32"
type: Opaque
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rustfs-ci-cache
  namespace: woodpecker
  annotations:
    # Cache data: keep it out of NAS snapshots/replication, it is rebuildable.
    democratic-csi.org/config: |
      zfs:
        datasetProperties:
          homelab:sanoid-skip: "true"
          syncoid:sync: "false"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rustfs
  namespace: woodpecker
  labels:
    app: rustfs
spec:
  replicas: 1
  # RWO volume + Recreate: a rolling update would mount the same zvol in two
  # pods and wedge on Multi-Attach.
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: rustfs
  template:
    metadata:
      labels:
        app: rustfs
    spec:
      securityContext:
        # The image runs as uid/gid 10001 (docs.rustfs.com, Docker page).
        fsGroup: 10001
        fsGroupChangePolicy: OnRootMismatch
      containers:
        - name: rustfs
          # renovate: datasource=docker depName=rustfs/rustfs
          image: rustfs/rustfs:1.0.4
          args:
            - /data
          env:
            - name: RUSTFS_ADDRESS
              value: ":9000"
            - name: RUSTFS_CONSOLE_ENABLE
              value: "false"
            - name: RUSTFS_OBS_LOGGER_LEVEL
              value: error
            - name: RUSTFS_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: rustfs-ci-cache
                  key: access-key
            - name: RUSTFS_SECRET_KEY
              valueFrom:
                secretKeyRef:
                  name: rustfs-ci-cache
                  key: secret-key
          ports:
            - name: s3
              containerPort: 9000
          volumeMounts:
            - name: data
              mountPath: /data
          startupProbe:
            httpGet:
              path: /health
              port: s3
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /health
              port: s3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: s3
            periodSeconds: 30
            failureThreshold: 5
          resources:
            requests:
              cpu: 25m
              memory: 128Mi
            limits:
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-ci-cache
---
apiVersion: v1
kind: Service
metadata:
  name: rustfs
  namespace: woodpecker
  labels:
    app: rustfs
spec:
  type: ClusterIP
  selector:
    app: rustfs
  ports:
    - name: s3
      # Port 80 on the Service only: the container keeps listening on 9000,
      # because it runs as uid 10001 and cannot bind a privileged port. With 80
      # here, step configuration never carries a port number.
      port: 80
      targetPort: s3
---
# Same shape as the buildkitd policy: anything in this namespace may read and
# write the cache, nothing outside it can reach the API.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rustfs
  namespace: woodpecker
spec:
  podSelector:
    matchLabels:
      app: rustfs
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: woodpecker
      ports:
        # NetworkPolicy ports are the pod's, not the Service's: this stays 9000
        # even though clients reach the API on the Service's port 80.
        - protocol: TCP
          port: 9000
```

- [ ] **Step 2: Validate it the way CI will**

Run:

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
kubeconform -strict -summary woodpecker/rustfs.woodpecker.yaml
```

Expected: `Summary: 5 resources found in 1 file - Valid: 5, Invalid: 0, Errors: 0, Skipped: 0`.

- [ ] **Step 3: Server-side dry run against the live cluster**

Run:

```bash
kubectl apply --dry-run=server -f woodpecker/rustfs.woodpecker.yaml
```

Expected: four lines ending in `(server dry run)`, no validation errors, and `secret "rustfs-ci-cache" ... created (server dry run)` — note the Secret is *not* applied for real, `secret-generator` will populate it on sync.

- [ ] **Step 4: Confirm the design docs are already on the branch**

The spec, this plan and the investigation it argues from are committed by the
plan's own PR, so the implementation branch has nothing to stage here:

```bash
git log --oneline -3 -- docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md \
  docs/superpowers/plans/2026-11-06-ci-cache-rustfs.md docs/ci-flakiness-2026-11-06.md
```

Expected: the plan-PR commits (`docs: plan a rustfs-backed CI cache`,
`docs: serve the cache on port 80 and plan its metrics`,
`docs: fold metrics into the plan summary and file list`). No commit in this step.

- [ ] **Step 5: Commit the manifest**

```bash
git add woodpecker/rustfs.woodpecker.yaml
git commit -m "feat(woodpecker): add rustfs CI cache endpoint"
```

- [ ] **Step 6: Verify after the PR merges and ArgoCD syncs**

Run:

```bash
kubectl -n woodpecker rollout status deploy/rustfs --timeout=180s
kubectl -n woodpecker get secret rustfs-ci-cache -o jsonpath='{.data}' | python3 -c 'import json,sys; print(sorted(json.load(sys.stdin)))'
kubectl -n woodpecker logs deploy/rustfs --tail=20
kubectl -n woodpecker port-forward svc/rustfs 9000:80 &
sleep 2 && curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/health; kill %1
```

Expected: `deployment "rustfs" successfully rolled out`; `['access-key', 'secret-key']`; logs show rustfs start-up lines naming the `:9000` listener (if they are absent, add `RUSTFS_OBS_LOG_DIRECTORY: /var/log/rustfs/` plus an `emptyDir` at that path to the Deployment so the container writes somewhere and `kubectl logs` stays empty by design); `200` from `/health`.

Do not print the secret values anywhere. If a manual check is needed, read them into shell variables in one step and never echo them.

---

### Task 2: cache metrics and alerting

**Files:**
- Modify: `woodpecker/rustfs.woodpecker.yaml` (collector ConfigMap, metrics sidecar, container port, PodMonitor)
- Create: `rustfs-alerts.yaml`

**Interfaces:**
- Consumes: the `rustfs` Deployment from Task 1.
- Produces: `rustfs_*` series scraped from the pod's `metrics` port (8889) and relayed to Thanos by `prom-kp-prometheus`; PrometheusRule `rustfs-ci-cache`.

rustfs **pushes** telemetry over OTLP and has no Prometheus endpoint
(`docs.rustfs.com/en/operations/observability`: "It does not expose a native
Prometheus `/metrics` scrape endpoint"). The upstream topology is
`rustfs --OTLP--> collector --> Prometheus`, so a collector runs as a sidecar in
the same pod.

Why the `prometheus` exporter and a scrape, rather than the
`prometheusremotewrite` exporter straight to Thanos (the pattern
`otel-agent-trace-connector.yaml` uses for coding-agent metrics):

- `prom-kp-prometheus` already remote-writes everything it scrapes to
  `thanos-receive-router.thanos.svc.cluster.local.:19291/api/v1/receive`, so
  scraping puts these series in Thanos anyway, with Prometheus' external labels
  (`cluster`, `tenant_id`) attached like every other series there.
- There is no Thanos Ruler and no `remoteRead` on either Prometheus CR, so a
  direct remote-write would leave the series invisible to *every*
  `PrometheusRule` in this repo — the alerting half of this task could not work.
- Cost is one extra scrape target with a few dozen series.

A sidecar (not the shared `monitoring/otel-collector`) keeps the change local:
no cross-namespace traffic, no edit to the shared pipeline whose `metrics:
null` is a deliberate contract, and the image is already on every node because
that collector runs the same tag.

- [ ] **Step 1: Add the collector configuration**

Append to `woodpecker/rustfs.woodpecker.yaml`, before the `Secret` document:

```yaml
---
# rustfs only pushes telemetry, so this sidecar is its OTLP sink and re-exposes
# what it receives as Prometheus text on :8889. Scraping (rather than
# remote-writing to Thanos directly) is what makes the series alertable: see the
# reasoning in docs/superpowers/plans/2026-11-06-ci-cache-rustfs.md, Task 2.
apiVersion: v1
kind: ConfigMap
metadata:
  name: rustfs-metrics
  namespace: woodpecker
data:
  collector.yaml: |
    receivers:
      otlp:
        protocols:
          http:
            endpoint: 127.0.0.1:4318
    processors:
      batch: {}
    exporters:
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        logs:
          level: warn
      pipelines:
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [prometheus]
```

- [ ] **Step 2: Turn on rustfs metric export**

In the `rustfs` container's `env` list, after `RUSTFS_OBS_LOGGER_LEVEL`, add:

```yaml
            # Push metrics at the sidecar. Traces and logs stay on stdout so
            # they are not duplicated into OTLP (the cluster collects them from
            # the container log).
            - name: RUSTFS_OBS_ENDPOINT
              value: http://127.0.0.1:4318
            - name: RUSTFS_OBS_METRICS_EXPORT_ENABLED
              value: "true"
            - name: RUSTFS_OBS_TRACES_EXPORT_ENABLED
              value: "false"
            - name: RUSTFS_OBS_LOGS_EXPORT_ENABLED
              value: "false"
            - name: RUSTFS_OBS_METER_INTERVAL
              value: 30s
            - name: RUSTFS_OBS_SERVICE_NAME
              value: rustfs-ci-cache
```

- [ ] **Step 3: Add the sidecar container and its volume**

Immediately after the `rustfs` container block (before `volumes:`), add:

```yaml
        - name: otel-collector
          # renovate: datasource=docker depName=otel/opentelemetry-collector-contrib
          image: otel/opentelemetry-collector-contrib:0.163.2
          args:
            - --config=/etc/otelcol/collector.yaml
          ports:
            - name: metrics
              containerPort: 8889
          volumeMounts:
            - name: metrics-config
              mountPath: /etc/otelcol
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 128Mi
```

and extend the pod's `volumes` list:

```yaml
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: rustfs-ci-cache
        - name: metrics-config
          configMap:
            name: rustfs-metrics
```

- [ ] **Step 4: Add the PodMonitor**

Append after the `NetworkPolicy` document:

```yaml
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: rustfs
  namespace: woodpecker
  labels:
    # prom-kp-prometheus selects PodMonitors by release=prom across all
    # namespaces; .ci/validate-prom-selectors.sh fails the PR if a monitor is
    # selected by no instance.
    release: prom
spec:
  selector:
    matchLabels:
      app: rustfs
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

- [ ] **Step 5: Add the alert rules**

Create `rustfs-alerts.yaml` at the repo root (deployed by the root app, which
only picks up top-level files — same place and shape as `argocd-alerts.yaml`):

```yaml
# Alerts for the CI artifact cache (rustfs in namespace woodpecker). The cache
# is fail-open by design, so these are warnings: the failure mode is silent CI
# slowdown, not a failed build. Metrics arrive through the OTLP sidecar in
# woodpecker/rustfs.woodpecker.yaml and are relayed to Thanos by
# kube-prometheus-stack's remote-write, like every other scraped series.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rustfs-ci-cache
  namespace: monitoring
  labels:
    release: prom
spec:
  groups:
    - name: rustfs-ci-cache
      rules:
        - alert: CICacheMetricsMissing
          # Name-agnostic on purpose: absent() on one guessed metric fires
          # forever if rustfs renames it, and the real breakage then hides.
          expr: absent({__name__=~"rustfs_.*"})
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: CI cache metrics have been missing for an hour
            description: >-
              No rustfs_* series. Either the rustfs pod, its OTLP sidecar, or
              the scrape is broken; CI still passes but every pipeline pays the
              full download cost again.
        - alert: CICacheNotReady
          expr: rustfs_runtime_readiness_ready == 0
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: CI cache has been unready for 30 minutes
            description: >-
              rustfs reports itself not ready, so pipelines run cold. Check the
              pod and its iSCSI volume.
        - alert: CICacheRestartLooping
          expr: increase(rustfs_start_total[30m]) > 2
          labels:
            severity: warning
          annotations:
            summary: CI cache is restarting repeatedly
        - alert: CICacheVolumeNearlyFull
          # The capacity gauge ships as rustfs_capacity_current_bytes upstream
          # but as rustfs_capacity_current in some builds; take whichever is
          # present (Step 10 confirms the live name).
          expr: (rustfs_capacity_current_bytes or rustfs_capacity_current) > 8.6e9
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: CI cache volume is over 80% of its 10Gi PVC
            description: >-
              Old chart and tool versions accumulate; prune them or grow the PVC
              before writes start failing.
```

- [ ] **Step 6: Validate**

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
kubeconform -strict -summary woodpecker/rustfs.woodpecker.yaml rustfs-alerts.yaml
SCHEMA_MIRROR=.tmp/schemas sh .ci/validate-prom-selectors.sh
```

Expected: seven resources valid (ConfigMap, Secret, PVC, Deployment, Service,
NetworkPolicy, PodMonitor) plus the alert file, and
`Every monitoring.coreos.com resource is selected by an instance.`

- [ ] **Step 7: Commit**

```bash
git add woodpecker/rustfs.woodpecker.yaml rustfs-alerts.yaml
git commit -m "feat(woodpecker): export rustfs cache metrics

rustfs only pushes OTLP, so a collector sidecar re-exposes its metrics for
scrape; kube-prometheus-stack relays them to Thanos and the new rules warn when
the cache is down, restarting, full, or has silently stopped reporting."
```

- [ ] **Step 8: Verify the metrics reach Prometheus and Thanos**

```bash
kubectl -n woodpecker rollout status deploy/rustfs --timeout=180s
kubectl -n woodpecker port-forward deploy/rustfs 8889:8889 &
sleep 45 && curl -fsS http://127.0.0.1:8889/metrics | grep -c '^rustfs_'; kill %1
kubectl -n thanos port-forward svc/thanos-query 9090:9090 &
sleep 2
curl -s 'http://127.0.0.1:9090/api/v1/query?query=rustfs_runtime_readiness_ready' | head -c 400; echo
curl -s 'http://127.0.0.1:9090/api/v1/query?query=count(up{job=~".*rustfs.*"})' | head -c 300; echo
kill %1
```

Expected: a non-zero `rustfs_` line count (one export interval of 30s must pass
first), a Thanos result whose value is `1` for the readiness gauge, and a scrape
target count of at least `1` — the latter is what proves the series will be
remote-written into Thanos.

- [ ] **Step 10: Correct the metric names against the live series**

Only some names are verified for the pinned `rustfs/rustfs:1.0.4`:
`rustfs_capacity_current_bytes` exists upstream, while
`rustfs_runtime_readiness_ready`, `rustfs_start_total` and the exact capacity
gauge name vary by build (the prefix is configurable). Every expression that
names a metric the build does not emit silently never fires; only the
`absent({__name__=~"rustfs_.*"})` rule would catch the opposite mistake.

```bash
kubectl -n thanos port-forward svc/thanos-query 9090:9090 &
sleep 2
for q in 'count({__name__=~"rustfs_.*"})' \
         'rustfs_runtime_readiness_ready' \
         'rustfs_start_total' \
         'rustfs_capacity_current_bytes' \
         'rustfs_capacity_current'; do
  printf '%-32s ' "$q"
  curl -s --data-urlencode "query=$q" http://127.0.0.1:9090/api/v1/query \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(len(r), "series")'
done
kill %1
```

Expected: a non-zero count of `rustfs_*` series, and a non-empty result for each
name the alert rules use. If a name used by a rule returns zero series while
`rustfs_*` series exist, rename that expression to an observed name **in this
PR** (`CICacheNotReady`, `CICacheRestartLooping`, and the capacity gauge are the
three candidates) and commit it with the task — a rule pinned to a name the
build never emits is indistinguishable from a healthy cache.

- [ ] **Step 9: Verify the alerts are loaded**

```bash
kubectl -n monitoring get prometheusrule rustfs-ci-cache \
  -o jsonpath='{range .spec.groups[0].rules[*]}{.alert}{"\n"}{end}'
```

Expected: `CICacheMetricsMissing`, `CICacheNotReady`, `CICacheRestartLooping`,
`CICacheVolumeNearlyFull`.

---

### Task 3: cache helper library and hermetic tests

**Files:**
- Create: `.ci/lib/cache.sh`
- Create: `.ci/test/cache-test.sh`
- Modify: `.pre-commit-config.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 4–6):
  - `cache_restore_schemas <mirror-dir> <cache-in-dir>`
  - `cache_export_schemas <mirror-dir> <cache-in-dir> <cache-out-dir>`
  - `cache_restore_tools <cache-in-dir> <bin-dir>`
  - `cache_export_tool <name> <version> <src-file> <cache-in-dir> <cache-out-dir>`
  - `fetch_tool <name> <version> <url> <dest-dir>`
  - `SCHEMA_REPOS` = `kubernetes-json-schema CRDs-catalog`

- [ ] **Step 1: Write the failing test**

`.ci/test/cache-test.sh`:

```sh
#!/bin/sh
set -eu

# Hermetic tests for .ci/lib/cache.sh: no network, no S3. Every helper takes
# directories, so temporary git repos and fake caches are enough.
# Run: sh .ci/test/cache-test.sh

cd "$(dirname "$0")/../.."
# pre-commit exports an absolute GIT_DIR/GIT_WORK_TREE, which override `git -C`;
# without this the temporary repos below operate on the real checkout (the trap
# .ci/sync-schemas.sh documents) and can mark it bare or reset it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
# shellcheck disable=SC1091
. .ci/lib/cache.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

make_repo() {
  # make_repo <dir> [sparse-pattern...]: one commit, optionally a non-cone
  # sparse checkout like the mirrors sync-schemas.sh builds.
  _dir=$1
  shift
  mkdir -p "$_dir"
  git -C "$_dir" init -q
  git -C "$_dir" config user.email "ci@test"
  git -C "$_dir" config user.name "ci"
  echo '{}' > "$_dir/root.json"
  mkdir -p "$_dir/v1.99.0-standalone-strict"
  echo '{}' > "$_dir/v1.99.0-standalone-strict/pod.json"
  git -C "$_dir" add -A
  git -C "$_dir" commit -qm init
  if [ "$#" -gt 0 ]; then
    git -C "$_dir" sparse-checkout set --no-cone "$@"
  fi
}

# 1. a cold cache is a no-op, not an error
mkdir -p "$TMP/cold/schemas"
cache_restore_schemas "$TMP/m1" "$TMP/cold"
[ ! -d "$TMP/m1/kubernetes-json-schema/.git" ] || fail "cold restore created a repo"
ok "cold restore is a no-op"

# 2. a warm cache materialises the worktree
make_repo "$TMP/seed/kubernetes-json-schema"
mkdir -p "$TMP/warm/schemas"
tar -C "$TMP/seed/kubernetes-json-schema" -cf "$TMP/warm/schemas/kubernetes-json-schema.git.tar" .git
cache_restore_schemas "$TMP/m2" "$TMP/warm"
[ -f "$TMP/m2/kubernetes-json-schema/v1.99.0-standalone-strict/pod.json" ] \
  || fail "warm restore did not materialise the worktree"
ok "warm restore materialises the worktree"

# 3. restoring keeps the sparse-checkout config sync-schemas.sh relies on
make_repo "$TMP/seed-sparse/kubernetes-json-schema" "/v1.99.0-standalone-strict/*"
mkdir -p "$TMP/warm-sparse/schemas"
tar -C "$TMP/seed-sparse/kubernetes-json-schema" -cf "$TMP/warm-sparse/schemas/kubernetes-json-schema.git.tar" .git
cache_restore_schemas "$TMP/m3" "$TMP/warm-sparse"
grep -q "v1.99.0-standalone-strict" "$TMP/m3/kubernetes-json-schema/.git/info/sparse-checkout" \
  || fail "restore lost the sparse-checkout config"
ok "restore keeps the sparse-checkout config"

# 4. a truncated tarball is a miss, never a half-initialised repo
mkdir -p "$TMP/bad/schemas"
printf 'not a tar' > "$TMP/bad/schemas/kubernetes-json-schema.git.tar"
cache_restore_schemas "$TMP/m4" "$TMP/bad" 2>/dev/null || true
[ ! -e "$TMP/m4/kubernetes-json-schema/.git" ] || fail "corrupt tarball left a .git behind"
ok "corrupt tarball leaves no repo"

# 5. the first export writes both the tarball and the head
mkdir -p "$TMP/empty-in"
cache_export_schemas "$TMP/seed" "$TMP/empty-in" "$TMP/out1"
[ -f "$TMP/out1/schemas/kubernetes-json-schema.git.tar" ] || fail "first export skipped the tarball"
[ -f "$TMP/out1/schemas/kubernetes-json-schema.head" ] || fail "first export skipped the head"
ok "first export writes tarball and head"

# 6. an unchanged head is not re-exported
cache_export_schemas "$TMP/seed" "$TMP/out1" "$TMP/out2"
[ ! -f "$TMP/out2/schemas/kubernetes-json-schema.git.tar" ] || fail "unchanged head re-exported"
ok "unchanged head does not re-export"

# 7. head without tarball (interrupted save) is re-exported
mkdir -p "$TMP/head-only/schemas"
cp "$TMP/out1/schemas/kubernetes-json-schema.head" "$TMP/head-only/schemas/"
cache_export_schemas "$TMP/seed" "$TMP/head-only" "$TMP/out3"
[ -f "$TMP/out3/schemas/kubernetes-json-schema.git.tar" ] || fail "missing tarball was not re-exported"
ok "missing tarball with a matching head is re-exported"

# 8. a new commit is re-exported
echo '{"changed":true}' > "$TMP/seed/kubernetes-json-schema/root.json"
git -C "$TMP/seed/kubernetes-json-schema" commit -qam change
cache_export_schemas "$TMP/seed" "$TMP/out1" "$TMP/out4"
[ -f "$TMP/out4/schemas/kubernetes-json-schema.git.tar" ] || fail "changed head did not re-export"
ok "changed head re-exports"

# 9. tools: cached binaries are installed, misses are staged for upload
mkdir -p "$TMP/cache-in/tools/kubeconform/v0.8.0"
printf '#!/bin/sh\necho kubeconform\n' > "$TMP/cache-in/tools/kubeconform/v0.8.0/kubeconform"
chmod 0755 "$TMP/cache-in/tools/kubeconform/v0.8.0/kubeconform"
cache_restore_tools "$TMP/cache-in" "$TMP/bin"
[ -x "$TMP/bin/kubeconform" ] || fail "restore_tools missed the cached binary"
ok "restore_tools installs cached binaries"

mkdir -p "$TMP/bin2"
printf '#!/bin/sh\necho pluto\n' > "$TMP/bin2/pluto"
chmod 0755 "$TMP/bin2/pluto"
cache_export_tool pluto v5.24.0 "$TMP/bin2/pluto" "$TMP/cache-in" "$TMP/cache-out"
[ -f "$TMP/cache-out/tools/pluto/v5.24.0/pluto" ] || fail "export_tool did not stage a new binary"
cache_export_tool kubeconform v0.8.0 "$TMP/bin/kubeconform" "$TMP/cache-in" "$TMP/cache-out"
[ ! -f "$TMP/cache-out/tools/kubeconform/v0.8.0/kubeconform" ] \
  || fail "export_tool re-staged a binary the cache already had"
ok "export_tool stages only binaries missing from the cache"

# 10. a zero-length cached tool is a miss, so fetch_tool can re-download it
mkdir -p "$TMP/cache-in/tools/empty/v1"
: > "$TMP/cache-in/tools/empty/v1/empty"
chmod 0755 "$TMP/cache-in/tools/empty/v1/empty"
cache_restore_tools "$TMP/cache-in" "$TMP/bin3"
[ ! -e "$TMP/bin3/empty" ] || fail "zero-length cached tool was installed"
ok "zero-length cached tools are skipped"

# 11. a zero-length object in the cache is re-staged, not trusted
printf '#!/bin/sh\necho empty\n' > "$TMP/bin3/empty"
chmod 0755 "$TMP/bin3/empty"
cache_export_tool empty v1 "$TMP/bin3/empty" "$TMP/cache-in" "$TMP/cache-out"
[ -f "$TMP/cache-out/tools/empty/v1/empty" ] || fail "zero-length cache entry was trusted"
ok "zero-length cache entries are re-staged"

echo "all cache tests passed"
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `sh .ci/test/cache-test.sh`

Expected: FAIL — `.ci/lib/cache.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

`.ci/lib/cache.sh`:

```sh
# shellcheck shell=sh
# Helpers for the S3-backed CI cache. Design:
# docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# Contract with the pipeline (paths relative to the workspace):
#   .tmp/cache-in/   written by .ci/cache-restore.sh (rclone download)
#   .tmp/cache-out/  written here, uploaded by .ci/cache-save.sh
#
# Every function must survive a cold, partial or corrupt cache without failing
# the step: the restore/save steps run with `failure: ignore`, and a miss may
# only ever cost time.

# Git exports an absolute GIT_DIR/GIT_WORK_TREE to hooks in linked worktrees,
# and `-C` does not clear them, so a `git -C <tmp>` call would `reset --hard`
# or `sparse-checkout set` on the outer worktree instead (see the same guard in
# .ci/sync-schemas.sh). Every function below runs under pre-commit, so clear
# them here once for all callers.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SCHEMA_REPOS="kubernetes-json-schema CRDs-catalog"

# cache_restore_schemas <mirror-dir> <cache-in-dir>
#   Loads the cached git object directories into the schema mirror and
#   re-creates the worktree from the sparse-checkout config stored inside them,
#   so sync-schemas.sh afterwards only fetches what actually changed.
cache_restore_schemas() {
  _mirror=$1
  _in=$2
  for _repo in $SCHEMA_REPOS; do
    _tar="$_in/schemas/$_repo.git.tar"
    [ -f "$_tar" ] || continue
    mkdir -p "$_mirror/$_repo"
    if ! tar -C "$_mirror/$_repo" -xf "$_tar" 2>/dev/null; then
      echo "cache: $_repo.git.tar is unreadable; discarding it" >&2
      rm -rf "${_mirror:?}/$_repo"
      continue
    fi
    if ! git -C "$_mirror/$_repo" reset --hard HEAD >/dev/null 2>&1; then
      echo "cache: cannot materialise $_repo from cache; discarding it" >&2
      rm -rf "${_mirror:?}/$_repo"
    fi
  done
}

# cache_export_schemas <mirror-dir> <cache-in-dir> <cache-out-dir>
#   Stages <repo>.git.tar for the mirrors whose head changed (or whose tarball
#   the cache does not have — that is how an interrupted save heals), and always
#   stages the head file.
cache_export_schemas() {
  _mirror=$1
  _in=$2
  _out=$3
  mkdir -p "$_out/schemas"
  for _repo in $SCHEMA_REPOS; do
    [ -d "$_mirror/$_repo/.git" ] || continue
    _head=$(git -C "$_mirror/$_repo" rev-parse HEAD)
    _prev=$(cat "$_in/schemas/$_repo.head" 2>/dev/null || echo "")
    if [ "$_head" != "$_prev" ] || [ ! -f "$_in/schemas/$_repo.git.tar" ]; then
      tar -C "$_mirror/$_repo" -cf "$_out/schemas/$_repo.git.tar" .git
      echo "cache: exported $_repo.git.tar ($_head)" >&2
    fi
    echo "$_head" > "$_out/schemas/$_repo.head"
  done
}

# cache_restore_tools <cache-in-dir> <bin-dir>
#   Installs every cached tool binary into <bin-dir> (flattened: the version
#   directory already selected which binary is current).
cache_restore_tools() {
  _in=$1
  _bin=$2
  mkdir -p "$_bin"
  [ -d "$_in/tools" ] || return 0
  for _f in "$_in"/tools/*/*/*; do
    # A zero-length object is a miss: fetch_tool then re-downloads and re-stages
    # it, which is how a bad upload heals.
    [ -s "$_f" ] || continue
    cp "$_f" "$_bin/$(basename "$_f")"
    chmod 0755 "$_bin/$(basename "$_f")"
  done
}

# cache_export_tool <name> <version> <src-file> <cache-in-dir> <cache-out-dir>
#   Stages a binary for upload only when the cache did not already have it.
cache_export_tool() {
  _name=$1
  _ver=$2
  _src=$3
  _in=$4
  _out=$5
  [ -s "$_src" ] || return 0
  # -s, not -f: a zero-length object in the cache is a miss, so it is re-staged
  if [ -s "$_in/tools/$_name/$_ver/$_name" ]; then
    return 0
  fi
  mkdir -p "$_out/tools/$_name/$_ver"
  cp "$_src" "$_out/tools/$_name/$_ver/$_name"
}

# fetch_tool <name> <version> <url> <dest-dir>
#   Installs the tool unless it is already present. A download that does not
#   run afterwards is discarded, so a truncated fetch is a miss, not a
#   mysterious exec failure in a later step.
fetch_tool() {
  _name=$1
  _ver=$2
  _url=$3
  _dest=$4
  if [ -s "$_dest/$_name" ] && [ -x "$_dest/$_name" ]; then
    return 0
  fi
  rm -f "$_dest/$_name"
  mkdir -p "$_dest"
  # wget and tar both fail the step under `set -e`, so an unreachable release or
  # a broken archive never reaches the size check below. Do not probe with
  # --help/--version: kubeconform exits 1 for both.
  case "$_url" in
    *.tar.gz) wget -q -t 3 -T 30 -O- "$_url" | tar xz -C "$_dest" "$_name" ;;
    *) wget -q -t 3 -T 30 -O "$_dest/$_name" "$_url" ;;
  esac
  chmod 0755 "$_dest/$_name"
  if [ ! -s "$_dest/$_name" ]; then
    echo "fetch_tool: $_name $_ver is empty after download; discarding" >&2
    rm -f "$_dest/$_name"
    return 1
  fi
}
```

- [ ] **Step 4: Run the tests again**

Run: `sh .ci/test/cache-test.sh`

Expected: twelve `ok:` lines followed by `all cache tests passed`.

- [ ] **Step 5: Lint**

Run: `shellcheck -s sh .ci/lib/cache.sh .ci/test/cache-test.sh`

Expected: no output (exit 0).

- [ ] **Step 6: Run the tests on every local commit**

Modify `.pre-commit-config.yaml` — add this hook as the last entry under `hooks:` (same indentation as `helm-validate`):

```yaml
      - id: ci-cache-tests
        name: CI cache helper tests (no network, no S3)
        entry: sh .ci/test/cache-test.sh
        language: system
        files: ^(\.ci/lib/cache\.sh|\.ci/test/cache-test\.sh)$
        pass_filenames: false
```

- [ ] **Step 7: Verify the hook wiring**

Run: `pre-commit run ci-cache-tests --all-files`

Expected: `CI cache helper tests (no network, no S3)....Passed`.

- [ ] **Step 8: Commit**

```bash
git add .ci/lib/cache.sh .ci/test/cache-test.sh .pre-commit-config.yaml
git commit -m "ci: add cache helper library with tests

Pure-directory helpers for the S3 cache: restore/export the schema mirrors'
git objects and tool binaries. Cold, corrupt and interrupted states are covered
by tests so the pipeline steps can treat every miss as 'just do the work'."
```

---

### Task 4: restore/save steps and chart cache migration

**Files:**
- Create: `.ci/cache-restore.sh`
- Create: `.ci/cache-save.sh`
- Create: `woodpecker/cache-secrets.woodpecker.yaml`
- Modify: `.woodpecker.yaml` (add `cache-restore`, `cache-save`; `prepare` gains `depends_on: [cache-restore]`)

**Interfaces:**
- Consumes: `rustfs` Service and Secret from Task 1; `.ci/lib/cache.sh` from Task 3 (not yet used here).
- Produces: `.tmp/cache-in/` (populated by restore) and `.tmp/cache-out/` (consumed by save); Woodpecker secrets `cache_access_key`, `cache_secret_key`.

- [ ] **Step 1: Create the restore script**

`.ci/cache-restore.sh`:

```sh
#!/bin/sh
set -euo pipefail

# Restores the S3-backed CI caches into the shared workspace before `prepare`
# runs. Runs with `failure: ignore`: an empty bucket, a cold cache or an
# unreachable rustfs only means the prepare step has to download things again.
# Design: docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# rclone is configured from RCLONE_CONFIG_CICACHE_* env (.woodpecker.yaml), so a
# missing or rotated credential fails here, in a step that cannot fail the
# pipeline.
#
#   charts/<chart>-<version>.tgz -> .tmp/charts   (helm_chart cache, read by prepare)
#   tools/<name>/<version>/<name> -> .tmp/cache-in/tools
#   schemas/<repo>.git.tar,*.head -> .tmp/cache-in/schemas

CACHE=${CI_CACHE_BUCKET:-cicache:ci-cache}
RCLONE="rclone --retries 2 --low-level-retries 2 --timeout 30s --contimeout 10s"

# Bucket creation lives here: it is idempotent, and keeping it out of a Job
# means nothing else owns bucket lifecycle.
$RCLONE mkdir "$CACHE"

mkdir -p .tmp/charts .tmp/cache-in/tools .tmp/cache-in/schemas
$RCLONE copy "$CACHE/charts" .tmp/charts
$RCLONE copy "$CACHE/tools" .tmp/cache-in/tools
$RCLONE copy "$CACHE/schemas" .tmp/cache-in/schemas

echo "cache restored: $(find .tmp/charts -name '*.tgz' | wc -l) charts, $(find .tmp/cache-in/tools -type f | wc -l) tools, $(find .tmp/cache-in/schemas -type f | wc -l) schema objects"
```

- [ ] **Step 2: Create the save script**

`.ci/cache-save.sh`:

```sh
#!/bin/sh
set -euo pipefail

# Uploads what `.prepare` staged. Additive only (rclone copy never deletes), so
# a bad run can leave a stale object behind but can never remove a good one.
# Runs with `failure: ignore`.
CACHE=${CI_CACHE_BUCKET:-cicache:ci-cache}
RCLONE="rclone --retries 2 --low-level-retries 2 --timeout 30s --contimeout 10s"

# Count each directory only when it exists: `set -e` plus `pipefail` would abort
# on a `find` over a directory that a failed prepare never created.
count_files() {
  _dir=$1
  shift
  [ -d "$_dir" ] || { echo 0; return 0; }
  find "$_dir" -type f "$@" | wc -l
}

STAGED=$(count_files .tmp/cache-out)
if [ -d .tmp/charts ]; then
  $RCLONE copy .tmp/charts "$CACHE/charts"
fi
if [ -d .tmp/cache-out/schemas ]; then
  $RCLONE copy .tmp/cache-out/schemas "$CACHE/schemas"
fi
if [ -d .tmp/cache-out/tools ]; then
  $RCLONE copy .tmp/cache-out/tools "$CACHE/tools"
fi
echo "cache saved: $STAGED staged objects, $(count_files .tmp/charts -name '*.tgz') charts in the workspace"
```

- [ ] **Step 3: Wire the steps into the pipeline**

Modify `.woodpecker.yaml` — insert these two steps immediately after the blank line following `steps:`, and add `depends_on: [cache-restore]` to the existing `prepare` step.

```yaml
steps:
  cache-restore:
    # renovate: datasource=docker depName=rclone/rclone
    image: rclone/rclone:1.76
    # Cache misses are normal and rustfs is a single pod: never fail the run
    # because the cache was unavailable (see .ci/cache-restore.sh).
    failure: ignore
    environment:
      RCLONE_CONFIG_CICACHE_TYPE: s3
      RCLONE_CONFIG_CICACHE_PROVIDER: Other
      RCLONE_CONFIG_CICACHE_ENDPOINT: http://rustfs.woodpecker.svc.cluster.local
      RCLONE_CONFIG_CICACHE_REGION: us-east-1
      RCLONE_CONFIG_CICACHE_FORCE_PATH_STYLE: "true"
      # Woodpecker repo secrets (values from the rustfs-ci-cache Secret; the
      # cache is not security-sensitive but nothing else may reach the API).
      RCLONE_CONFIG_CICACHE_ACCESS_KEY_ID:
        from_secret: cache_access_key
      RCLONE_CONFIG_CICACHE_SECRET_ACCESS_KEY:
        from_secret: cache_secret_key
    commands:
      - sh .ci/cache-restore.sh

  prepare:
    # renovate: datasource=docker depName=alpine/k8s
    image: alpine/k8s:1.37.2
    depends_on: [cache-restore]
```

and, after the `prepare` step (before `validate:`):

```yaml
  cache-save:
    # renovate: datasource=docker depName=rclone/rclone
    image: rclone/rclone:1.76
    depends_on: [prepare]
    failure: ignore
    environment:
      RCLONE_CONFIG_CICACHE_TYPE: s3
      RCLONE_CONFIG_CICACHE_PROVIDER: Other
      RCLONE_CONFIG_CICACHE_ENDPOINT: http://rustfs.woodpecker.svc.cluster.local
      RCLONE_CONFIG_CICACHE_REGION: us-east-1
      RCLONE_CONFIG_CICACHE_FORCE_PATH_STYLE: "true"
      RCLONE_CONFIG_CICACHE_ACCESS_KEY_ID:
        from_secret: cache_access_key
      RCLONE_CONFIG_CICACHE_SECRET_ACCESS_KEY:
        from_secret: cache_secret_key
    commands:
      - sh .ci/cache-save.sh
```

Keep the existing `prepare` comment block and `environment` mapping intact; only the `depends_on` line is new.

- [ ] **Step 4: Check the YAML parses and the DAG has no dangling edges**

```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.woodpecker.yaml'))
steps = d['steps']
for name, s in steps.items():
    for dep in s.get('depends_on', []):
        assert dep in steps, f"{name} depends on unknown step {dep}"
print("steps:", list(steps))
PY
```

Expected: `steps: ['cache-restore', 'prepare', 'cache-save', 'validate', ...]` with every dependency resolving.

- [ ] **Step 5: Commit**

```bash
git add .ci/cache-restore.sh .ci/cache-save.sh .woodpecker.yaml
chmod +x .ci/cache-restore.sh .ci/cache-save.sh
git add .ci/cache-restore.sh .ci/cache-save.sh
git commit -m "ci: restore and save caches in rustfs"
```

- [ ] **Step 6: Reconcile the secrets into Woodpecker's database**

No manual step: Woodpecker keeps repo secrets as plain rows in its `secrets`
table (`value text`, `images json`, `events json`,
`UNIQUE (org_id, repo_id, name)`), and the DSN is already a gitops object
(`woodpecker-server-env`). A CronJob upserts the two rows from the
`rustfs-ci-cache` Secret, so rotating that Secret propagates on the next tick
instead of leaving a stale hand-registered copy.

Why the database rather than the API: a user token can only be minted from an
authenticated browser session or by signing a JWT with `users.hash`, which lives
in the same database. This therefore needs no new credential at all.

Create `woodpecker/cache-secrets.woodpecker.yaml`:

```yaml
# Keeps the two Woodpecker repo secrets that .woodpecker.yaml references
# (cache_access_key / cache_secret_key) in sync with the rustfs-ci-cache Secret.
#
# Woodpecker stores repo secrets as plain rows in its own `secrets` table
# (value TEXT, images/events JSON, UNIQUE (org_id, repo_id, name)), so this
# reconciles them with SQL instead of asking a human to paste values into the UI:
# rotating rustfs-ci-cache is picked up on the next tick, which is the whole
# point — a hand-registered copy goes silently stale.
#
# Why the database and not the API: the API needs a user token, and a token can
# only be minted from an authenticated browser session or by signing a JWT with
# users.hash (also only in this database). The DSN is already a gitops object
# (woodpecker-server-env, managed by ExternalSecrets), so no new credential
# enters the cluster.
#
# Trade-off: this couples to Woodpecker's schema. A version bump that renames or
# retypes a column makes the Job fail loudly (KubeJobFailed) instead of quietly
# serving stale values — which is the failure direction we want.
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cache-secrets-sync
  namespace: woodpecker
data:
  reconcile.sql: |
    -- Idempotent upsert of the CI cache secrets for one repository. The values
    -- arrive as psql variables so no secret ever reaches the container log.
    -- `images` is written as NULL: image filters are only enforced for plugin
    -- steps, and a normal command step that uses a filtered secret fails
    -- pipeline compilation ("secret ... is only allowed to be used by
    -- plugins"), which takes all of CI down. `events` restricts the rows to
    -- pull_request pipelines and applies to every step kind.
    INSERT INTO secrets (org_id, repo_id, name, value, images, events, note)
    SELECT 0,
           r.id,
           v.name,
           v.value,
           NULL,
           v.events::json,
           'managed by cache-secrets-sync'
    FROM repos r
    CROSS JOIN (VALUES
        ('cache_access_key', :'access_key', '["pull_request"]'),
        ('cache_secret_key', :'secret_key', '["pull_request"]')
    ) AS v(name, value, events)
    WHERE r.full_name = 'nijave/vmubtkube-a'
    ON CONFLICT (org_id, repo_id, name) DO UPDATE
       SET value  = EXCLUDED.value,
           images = EXCLUDED.images,
           events = EXCLUDED.events,
           note   = EXCLUDED.note;

    -- Fail (and therefore alert through KubeJobFailed) instead of silently
    -- leaving CI without credentials when the repo row or a secret is missing.
    DO $$
    DECLARE n int;
    BEGIN
        SELECT count(*) INTO n
        FROM secrets s
        JOIN repos r ON r.id = s.repo_id
        WHERE r.full_name = 'nijave/vmubtkube-a'
          AND s.name IN ('cache_access_key', 'cache_secret_key');
        IF n <> 2 THEN
            RAISE EXCEPTION 'expected 2 cache secrets for nijave/vmubtkube-a, found %', n;
        END IF;
    END $$;

    -- Lengths, not values: this line is what shows up in the Job log.
    SELECT s.name, length(s.value) AS value_len, s.images, s.events
    FROM secrets s
    JOIN repos r ON r.id = s.repo_id
    WHERE r.full_name = 'nijave/vmubtkube-a'
      AND s.name IN ('cache_access_key', 'cache_secret_key')
    ORDER BY s.name;
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cache-secrets-sync
  namespace: woodpecker
spec:
  # Every ten minutes: the cache steps are fail-open, so a delayed reconcile
  # only means a cold run, never a broken one.
  schedule: "*/10 * * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 120
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            # postgres:17-alpine ships the postgres user as 999:999.
            runAsUser: 999
            runAsGroup: 999
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: reconcile
              # renovate: datasource=docker depName=postgres
              image: postgres:17-alpine
              command:
                - /bin/sh
                - -c
              args:
                - |
                  set -eu
                  psql "$WOODPECKER_DATABASE_DATASOURCE" \
                    -v ON_ERROR_STOP=1 \
                    -v access_key="$(cat /etc/rustfs/access-key)" \
                    -v secret_key="$(cat /etc/rustfs/secret-key)" \
                    -f /sql/reconcile.sql
              env:
                - name: WOODPECKER_DATABASE_DATASOURCE
                  valueFrom:
                    secretKeyRef:
                      name: woodpecker-server-env
                      key: WOODPECKER_DATABASE_DATASOURCE
              volumeMounts:
                - name: sql
                  mountPath: /sql
                  readOnly: true
                - name: rustfs
                  mountPath: /etc/rustfs
                  readOnly: true
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  memory: 128Mi
          volumes:
            - name: sql
              configMap:
                name: cache-secrets-sync
            - name: rustfs
              secret:
                secretName: rustfs-ci-cache
```

- [ ] **Step 6b: Validate and review the one schema-coupled file**

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
kubeconform -strict -summary woodpecker/cache-secrets.woodpecker.yaml
SCHEMA_MIRROR=.tmp/schemas sh .ci/validate.sh 2>&1 | tail -1
```

Expected: `2 resources found in 1 file - Valid: 2` and `All manifests valid.`
After the merge, the first Job run's log must show two rows with
`value_len > 0`; a `KubeJobFailed` alert means the schema moved under us.

- [ ] **Step 7: Verify on the PR pipeline (cold run)**

After pushing, open the pipeline's `cache-restore` log. Expected:

```
cache restored: 0 charts, 0 tools, 0 schema objects
```

and in `cache-save`:

```
cache saved: 0 staged objects, 23 charts in the workspace
```

- [ ] **Step 8: Verify on a second pipeline run (warm run)**

Push an empty commit (`git commit --allow-empty -m "ci: verify warm cache"`) and
re-read the logs. Expected: `cache restored: 23 charts, 0 tools, 0 schema
objects`, and the `prepare` step still prints its `chart cache: <chart>@<version>`
line for every application (`prime_app_charts` echoes unconditionally before
`chart_tarball` returns early) — what disappears is the network activity: no
`Pulled:`/`Digest:` lines, and the step finishes in seconds instead of ~90.

- [ ] **Step 9: Verify the fail-open path**

Run locally (no rclone config → rclone exits non-zero, script must not leave a
partial `.tmp` behind):

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
env -u RCLONE_CONFIG_CICACHE_TYPE -u RCLONE_CONFIG_CICACHE_ENDPOINT sh .ci/cache-restore.sh; echo "rc=$?"
```

Expected: `rc=1` and an rclone error about a missing endpoint; no crash, no
`set -u` message. The pipeline step is unaffected because of
`failure: ignore` — confirm it in the step's YAML.

---

### Task 5: schema mirror migration

**Files:**
- Modify: `.ci/lib/cache.sh` (schemas functions already added in Task 3 — this task only consumes them)
- Modify: `.ci/prepare-cache.sh`
- Modify: `.ci/test/cache-test.sh` (no change needed; confirms coverage stays green)

**Interfaces:**
- Consumes: `cache_restore_schemas`, `cache_export_schemas` (Task 3); `.tmp/cache-in`, `.tmp/cache-out` (Task 4).
- Produces: `.tmp/cache-out/schemas/<repo>.git.tar` and `<repo>.head` for `cache-save`.

- [ ] **Step 1: Extend `prepare` with cache-in/out and the schema restore/export**

Replace the whole body of `.ci/prepare-cache.sh` with:

```sh
#!/bin/sh
set -euo pipefail

# Materializes the caches every other validating step reads, so exactly one pod
# writes them:
#
#   $SCHEMA_MIRROR     kubeconform schema mirrors (.ci/sync-schemas.sh)
#   $HELM_CHART_CACHE  Helm chart tarballs (.ci/lib/render-helm.sh)
#
# All step pods of a workflow share one workspace PVC, so the caches are visible
# to the steps that depend_on this one. Since the caches are also restored from
# and saved to the rustfs bucket (see .ci/cache-restore.sh / .ci/cache-save.sh),
# this script has a strict input/output contract:
#
#   .tmp/cache-in/   what the restore step downloaded (may be empty)
#   .tmp/cache-out/  what the save step must upload (staged here)
#
# Design: docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# The consumers still call sync-schemas.sh themselves, which is a no-op once
# warm, so nothing here is required for pre-commit or for running one script by
# hand.

SELFDIR=$(dirname "$0")
CACHE_IN=${CI_CACHE_IN:-.tmp/cache-in}
CACHE_OUT=${CI_CACHE_OUT:-.tmp/cache-out}

# shellcheck disable=SC1091
. "$SELFDIR/lib/cache.sh"

mkdir -p "$CACHE_OUT"

if [ -n "${SCHEMA_MIRROR:-}" ]; then
  echo "=== schema mirrors ($SCHEMA_MIRROR) ==="
  # Object directories only (tens of MB): the checkout is rebuilt locally,
  # because kubeconform needs the files on disk either way.
  cache_restore_schemas "$SCHEMA_MIRROR" "$CACHE_IN"
  sh "$SELFDIR/sync-schemas.sh"
  cache_export_schemas "$SCHEMA_MIRROR" "$CACHE_IN" "$CACHE_OUT"
fi

# shellcheck disable=SC1091
. "$SELFDIR/lib/render-helm.sh"

if [ -n "${HELM_CHART_CACHE:-}" ]; then
  echo "=== helm chart cache ($HELM_CHART_CACHE) ==="
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  extract_apps "$WORKDIR/apps" > "$WORKDIR/apps.txt"
  prime_app_charts "$WORKDIR/apps.txt"
  echo "chart cache holds $(find "$HELM_CHART_CACHE" -maxdepth 1 -name '*.tgz' | wc -l) tarballs"
fi

echo "Caches ready."
```

- [ ] **Step 2: Run the helper tests**

Run: `sh .ci/test/cache-test.sh`

Expected: `all cache tests passed` (the schema cases from Task 3 are what this
step exercises).

- [ ] **Step 3: Run the pipeline locally without a cache**

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
rm -rf /tmp/prep && mkdir -p /tmp/prep
SCHEMA_MIRROR=/tmp/prep/schemas HELM_CHART_CACHE=/tmp/prep/charts \
CI_CACHE_IN=/tmp/prep/in CI_CACHE_OUT=/tmp/prep/out sh .ci/prepare-cache.sh
```

Expected: it finishes with `Caches ready.`, prints at least one
`cache: exported kubernetes-json-schema.git.tar (...)` line (first run = no
cache-in), and `/tmp/prep/out/schemas/` contains two `.git.tar` files and two
`.head` files.

- [ ] **Step 4: Verify the warm path locally**

```bash
mkdir -p /tmp/prep/in/schemas && cp /tmp/prep/out/schemas/* /tmp/prep/in/schemas/
SCHEMA_MIRROR=/tmp/prep/schemas HELM_CHART_CACHE=/tmp/prep/charts \
CI_CACHE_IN=/tmp/prep/in CI_CACHE_OUT=/tmp/prep/out2 sh .ci/prepare-cache.sh
```

Expected: no `cache: exported` lines (heads unchanged), `/tmp/prep/out2/schemas/`
contains only the two `.head` files, and `sync-schemas.sh` prints
`schema mirrors ready in /tmp/prep/schemas (...)` without cloning.

- [ ] **Step 5: Commit**

```bash
git add .ci/prepare-cache.sh
git commit -m "ci: restore schema mirrors from the cache

The mirror is ~19 MB of git objects plus a 734 MB checkout that kubeconform
needs on local disk anyway, so only the object database is cached and the
worktree is rebuilt from its sparse-checkout config."
```

- [ ] **Step 6: Verify on the PR pipeline**

First run: `cache-restore` reports `0 ... schema objects`; `prepare` exports both
tarballs; `cache-save` uploads them. Second run: `cache-restore` reports `4
schema objects` (two tarballs + two heads), `prepare` prints no `cache: exported`
line, and `sync-schemas.sh`'s output shows no clone ("schema mirrors ready"
appears within a few seconds instead of after a clone).

---

### Task 6: tool binary cache — DROPPED, not implemented

Measured after the other tasks were built: restoring the three binaries costs
~90 MB of bucket traffic per pipeline to save ~1.5 s (cold `wget` of
kubeconform + pluto + vendir was 1.7 s). The cache was removed from the
implementation — `kubeconform`, `pluto` and `vendir` stay pinned `wget`s in
their own steps, `.ci/lib/cache.sh` keeps only the schema helpers, and there is
no `tools/` prefix in the bucket. The steps below are kept for the reasoning and
the numbers; do not implement them as written.

#### Original steps (superseded)

### Task 6: tool binary cache

**Files:**
- Modify: `.ci/prepare-cache.sh` (tool install + staging)
- Modify: `.woodpecker.yaml` (drop the four `wget` install lines, move version env into `prepare`, `validate-pluto` depends on `prepare`)
- Modify: `.ci/test/cache-test.sh` (already covers the helpers; no change)

**Interfaces:**
- Consumes: `cache_restore_tools`, `cache_export_tool`, `fetch_tool` (Task 3); `.tmp/cache-in/tools`, `.tmp/cache-out/tools` (Tasks 4–5).
- Produces: `.tmp/bin/{kubeconform,pluto,vendir}` in the workspace, read by every consumer step.

- [ ] **Step 1: Add tool installation to `prepare-cache.sh`**

Insert this block immediately after the `. "$SELFDIR/lib/cache.sh"` line and
before the `mkdir -p "$CACHE_OUT"` line:

```sh
TOOL_DIR=${CI_TOOL_DIR:-.tmp/bin}
mkdir -p "$TOOL_DIR"

# Tools: served from the cache when the exact version is there, downloaded from
# GitHub otherwise (and then staged for upload). Versions come from the
# environment so Renovate keeps one annotation per tool, in this step only.
cache_restore_tools "$CACHE_IN" "$TOOL_DIR"
echo "=== tools ($TOOL_DIR) ==="
fetch_tool kubeconform "$KUBECONFORM_VERSION" \
  "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
  "$TOOL_DIR"
fetch_tool pluto "$PLUTO_VERSION" \
  "https://github.com/FairwindsOps/pluto/releases/download/$PLUTO_VERSION/pluto_${PLUTO_VERSION#v}_linux_amd64.tar.gz" \
  "$TOOL_DIR"
fetch_tool vendir "$VENDIR_VERSION" \
  "https://github.com/carvel-dev/vendir/releases/download/$VENDIR_VERSION/vendir-linux-amd64" \
  "$TOOL_DIR"
cache_export_tool kubeconform "$KUBECONFORM_VERSION" "$TOOL_DIR/kubeconform" "$CACHE_IN" "$CACHE_OUT"
cache_export_tool pluto "$PLUTO_VERSION" "$TOOL_DIR/pluto" "$CACHE_IN" "$CACHE_OUT"
cache_export_tool vendir "$VENDIR_VERSION" "$TOOL_DIR/vendir" "$CACHE_IN" "$CACHE_OUT"
```

- [ ] **Step 2: Give `prepare` the three version variables**

In `.woodpecker.yaml`, `prepare`'s `environment` becomes (keep the existing
`SCHEMA_MIRROR` / `HELM_CHART_CACHE` comments):

```yaml
    environment:
      # renovate: datasource=github-releases depName=yannh/kubeconform
      KUBECONFORM_VERSION: v0.8.0
      # renovate: datasource=github-releases depName=FairwindsOps/pluto
      PLUTO_VERSION: v5.24.0
      # renovate: datasource=github-releases depName=carvel-dev/vendir
      VENDIR_VERSION: v0.46.0
      # git-mirror the schema repos instead of per-URL downloads from the
      # flaky raw.githubusercontent.com CDN (see .ci/sync-schemas.sh)
      SCHEMA_MIRROR: .tmp/schemas
      HELM_CHART_CACHE: .tmp/charts
```

- [ ] **Step 3: Replace the per-step downloads**

`validate` becomes:

```yaml
  validate:
    # renovate: datasource=docker depName=alpine/k8s
    image: alpine/k8s:1.37.2
    depends_on: [prepare]
    environment:
      # see prepare step
      SCHEMA_MIRROR: .tmp/schemas
    commands:
      - cp .tmp/bin/kubeconform /usr/local/bin/kubeconform && chmod 0755 /usr/local/bin/kubeconform
      - sh .ci/validate.sh
```

`validate-pluto` becomes (note the new `depends_on`):

```yaml
  validate-pluto:
    # renovate: datasource=docker depName=alpine/k8s
    image: alpine/k8s:1.37.2
    depends_on: [prepare]
    commands:
      - cp .tmp/bin/pluto /usr/local/bin/pluto && chmod 0755 /usr/local/bin/pluto
      - sh .ci/validate-pluto.sh
```

`validate-helm` becomes (keep its `when:` block unchanged):

```yaml
  validate-helm:
    # renovate: datasource=docker depName=alpine/k8s
    image: alpine/k8s:1.37.2
    depends_on: [prepare]
    when:
      - event: pull_request
        # Any manifest can hold a Helm-source Application.
        path:
          - "**/*.yaml"
          - ".ci/validate-helm.sh"
    environment:
      # see prepare step
      SCHEMA_MIRROR: .tmp/schemas
      HELM_CHART_CACHE: .tmp/charts
    commands:
      - cp .tmp/bin/kubeconform /usr/local/bin/kubeconform && chmod 0755 /usr/local/bin/kubeconform
      - cp .tmp/bin/pluto /usr/local/bin/pluto && chmod 0755 /usr/local/bin/pluto
      - sh .ci/validate-helm.sh
```

`vendir-sync`'s download lines become one line (its `depends_on: [validate,
validate-pluto]` already puts it after `prepare`):

```yaml
    commands:
      - cp .tmp/bin/vendir /usr/local/bin/vendir && chmod 0755 /usr/local/bin/vendir
      - sh .ci/vendir-sync.sh
```

Every `renovate:` annotation that moved must be deleted from the old location —
after this step each of `KUBECONFORM_VERSION`, `PLUTO_VERSION`, `VENDIR_VERSION`
appears exactly once, in `prepare`.

- [ ] **Step 4: Confirm no step still downloads a tool**

```bash
grep -n 'wget' .woodpecker.yaml
```

Expected: no matches.

```bash
grep -c 'renovate: datasource=github-releases' .woodpecker.yaml
```

Expected: `3`.

- [ ] **Step 5: Verify the DAG and YAML**

```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open('.woodpecker.yaml'))
steps = d['steps']
for name, s in steps.items():
    for dep in s.get('depends_on', []):
        assert dep in steps, f"{name} depends on unknown step {dep}"
env = steps['prepare']['environment']
assert {'KUBECONFORM_VERSION', 'PLUTO_VERSION', 'VENDIR_VERSION'} <= set(env), env
print("ok:", list(steps))
PY
```

Expected: `ok: ['cache-restore', 'prepare', 'cache-save', 'validate', ...]`.

- [ ] **Step 6: Commit**

```bash
git add .ci/prepare-cache.sh .woodpecker.yaml
git commit -m "ci: serve validation tools from the cache

Four GitHub release downloads (69 MB per pipeline) disappear into one cached
install in the prepare step; every consumer copies its binary out of
.tmp/bin."
```

- [ ] **Step 7: Verify on the PR pipeline**

First run: `prepare` prints `=== tools (.tmp/bin) ===` and downloads all three;
`cache-save` reports `3 staged objects`. Second run: `cache-restore` reports `3
tools`, `prepare` downloads nothing, and each consumer step's log starts with
`cp .tmp/bin/... && chmod 0755 ...`.

---

### Task 7: documentation, follow-ups and one stale claim

**Files:**
- Modify: `README.md` (the `## Manifest validation` section)
- Modify: `TODO.md` (new numbered item at the end)
- Modify: `woodpecker/application.woodpecker.yaml` (the podAffinity comment)

**Interfaces:**
- Consumes: everything above (describes it).
- Produces: nothing executable.

- [ ] **Step 1: Document the cache in `README.md`**

Extend the `## Manifest validation` section. Replace:

```markdown
Schemas are cached under `.tmp/`, so repeat runs take ~2s.
```

with:

```markdown
Schemas are cached under `.tmp/`, so repeat runs take ~2s.

CI itself caches three things across runs in a dedicated rustfs bucket
(`ci-cache`) in the cluster, restored and saved by the `cache-restore` /
`cache-save` steps:

- `charts/<chart>-<version>.tgz` — Helm chart tarballs (no more 23 `index.yaml`
  round trips per pipeline)
- `tools/<name>/<version>/<name>` — kubeconform, pluto, vendir
- `schemas/<repo>.git.tar` — git object databases for the kubeconform schema
  mirrors (the checkout is rebuilt locally; the objects are what costs network)

The cache is fail-open: both steps run with `failure: ignore`, saves are
additive, and a miss only costs time. `woodpecker/rustfs.woodpecker.yaml`
deploys the endpoint; design in
`docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`.
```

- [ ] **Step 2: Record the cross-repo follow-ups in `TODO.md`**

Append a new numbered section after item 11:

```markdown
## 12. Cross-repo dependency caches (from the 2026-11-06 CI flakiness review)

The rustfs bucket `ci-cache` in namespace `woodpecker` now survives pipeline
runs (`woodpecker/rustfs.woodpecker.yaml`, design in
`docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`). Two sibling
repos reinstall dependencies from scratch on every pipeline because their
workspace PVC is ephemeral, and would benefit from the same bucket — out of
scope here, follow-up PRs in those repos:

- `nijave/python-envoy-authz`: each of lint/test/coverage recreates the venv and
  runs `poetry install` (p50 lint 45s). The `test -x .poetry-venv/bin/poetry ||`
  guard implies someone expected the venv to persist — it cannot, the workspace
  is deleted after the workflow. Cheapest fixes, in order: one install step whose
  venv the other steps reuse; dependencies baked into the image it already
  builds; `POETRY_CACHE_DIR` on a cache volume.
- `nijave/cukk`: `uv sync --frozen` in both lint and test with no `UV_CACHE_DIR`,
  so uv's cache lives in the ephemeral container.
```

- [ ] **Step 3: Correct the stale cache claim**

In `woodpecker/application.woodpecker.yaml`, the `WOODPECKER_BACKEND_K8S_POD_AFFINITY`
comment claims co-locating same-repo workflows "reuse[s] warm caches (poetry
venv, buildkit layers)". Replace that phrase:

```yaml
            #  - SOFT podAffinity on repo-id: prefer to keep other workflows of
            #    the SAME repo on the same node to reuse warm caches (poetry
            #    venv, buildkit layers).
```

with:

```yaml
            #  - SOFT podAffinity on repo-id: prefer to keep other workflows of
            #    the SAME repo on the same node to reuse the buildkit layer
            #    cache, which lives on its own PVC. Workspace caches (poetry
            #    venv, uv cache) do NOT persist between workflows: the workspace
            #    PVC is per-workflow and deleted afterwards.
```

- [ ] **Step 4: Verify the repo still validates**

```bash
cd /home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a
SCHEMA_MIRROR= sh .ci/validate.sh 2>&1 | tail -3
```

Expected: `All manifests valid.` (with `SCHEMA_MIRROR` unset the step validates
against the remote locations — acceptable for a one-off local run).

- [ ] **Step 5: Commit**

```bash
git add README.md TODO.md woodpecker/application.woodpecker.yaml
git commit -m "docs: document the CI cache and its follow-ups"
```

---

## Out of scope (follow-up work, deliberately not in this plan)

- `nijave/python-envoy-authz` and `nijave/cukk` dependency caches — recorded in
  `TODO.md` item 12; those are separate repos and separate PRs.
- A pinned `woodpecker-tools` image (tools + schema mirror baked as layers).
  Still the better answer for *read-only* content; the bucket stays useful for
  anything CI must write, and the two compose without rework.
- Shrinking what the schema mirror materialises (the 734 MB checkout). Candidate:
  drop `master-standalone-strict` when the cluster's exact version directory
  exists, or restrict the sparse pattern to kinds the repo actually uses.
- Garbage collection of old chart/tool versions: growth is ~20 MB/month at
  current Renovate churn, so no job until it is measurable.
- Repo clone caching: `plugin-git` has no cache directory and the clone is 1.3 MB.

## Self-review

- Spec coverage: rustfs endpoint on Service port 80 (Task 1), metrics and
  alerting (Task 2), fail-open semantics (Tasks 3–6 plus the fail-open
  verification in Task 4), chart migration (Task 4), schema migration (Task 5),
  tool cache (Task 6), out-of-scope repos recorded (Task 7). The "no GC" and
  "no PDB" decisions are encoded in Task 1's manifest and comments.
- Placeholder scan: no `TBD`/`TODO`/"similar to" left; every code step carries
  the full content. The GIT_DIR unset appears in both Task 3 code blocks, and the
  metric-name verification is a numbered step rather than a comment.
- Type consistency: `cache_restore_schemas(mirror, in)`,
  `cache_export_schemas(mirror, in, out)`, `cache_restore_tools(in, bin)`,
  `cache_export_tool(name, version, src, in, out)`, `fetch_tool(name, version,
  url, dest)` are used with those signatures in Tasks 5 and 6.
- Review Focus items each have a test: corrupt tarball and head-without-tarball
  in Task 3 Step 1 (tests 4 and 7), sparse-config preservation (test 3), cold
  cache (test 1), zero-length tool binary (tests 10 and 11), credentials missing
  (Task 4 Step 9), metrics silence (the `absent()` rule in Task 2).
  rustfs-down is covered by `failure: ignore` on both cache steps plus the
  fail-open verification in Task 4 Step 9.
