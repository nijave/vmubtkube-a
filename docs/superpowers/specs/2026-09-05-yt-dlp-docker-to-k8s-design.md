# yt-dlp migration: Docker host → Kubernetes (`vmubtkube-a`)

Date: 2026-09-05
Status: approved design, pending implementation
Related: media-stack siblings already in-cluster (`sabnzbd.yaml`, `jellyfin.yaml`,
`sonarr.yaml`, `radarr.yaml`, `prowlarr.yaml`). This is a greenfield add — a
repo-wide grep for `yt-dlp`/`ytdlp`/`bgutil` returns nothing.

## Context

`yt-dlp` is the last piece of the media-download stack still running on the
standalone Docker host (`ssh docker`). Everything it touches already lives in the
cluster or on shared infra: the media library is the same NAS export the arr apps
and Jellyfin mount, and it has no external dependencies (no VPN, no API keys, no
persistent config beyond the per-folder download archive that lives on the NAS).
The move carries low risk.

Decision: move the same two-container setup into the `media` namespace, keeping
the same self-built image. The only behavioral change replaces the app's internal
2-hour sleep loop with a native Kubernetes CronJob (user's call), which needs a
small backward-compatible one-shot flag in the download script.

## Current state (`ssh docker`)

Two containers, both on a private bridge network `ytdlp-net`, started by
`infra/docker/50_yt-dlp.sh` (plain `docker run`; no compose project, no systemd
unit). The sibling infra repo versions the build source under `infra/docker/`
(`Dockerfile.yt-dlp`, `usr/share/yt-dlp/download.py`, `etc/yt-dlp.conf`).

| Container | Image | Role |
|---|---|---|
| `yt-dlp` | `registry.apps.nickv.me/yt-dlp:latest` (linuxserver ffmpeg base) | Runs custom `download.py` |
| `bgutil-provider` | `brainicism/bgutil-ytdlp-pot-provider:1.3.1` | YouTube proof-of-origin token (POT) HTTP service on :4416 |

How the app works:

- **`download.py`** loops forever: every `CHECK_FREQUENCY=7200`s (2h) it globs
  `$MEDIA_ROOT/**/.yt-dlp` and runs each match as a bash script with `cwd` set to
  that folder. Each `.yt-dlp` script is a per-show `yt-dlp` invocation that writes
  into its own directory and tracks progress with a per-folder
  `--download-archive .yt-dlp.log`. Downloaded state lives **on the NAS tree**,
  not in the container — the workload stays stateless beyond the media mount.
  (Currently 1 active script: "Good Mythical Morning".)
- **`/etc/yt-dlp.conf`** (baked into the image) supplies system-wide defaults —
  rate limiting, SponsorBlock marking, NFS retry tuning, and the POT provider
  pointer: `--extractor-args youtubepot-bgutilhttp:base_url=http://bgutil-provider:4416`.
  The app reaches the POT provider **by container name** over `ytdlp-net`.

Runtime facts that must survive the move:

- Runs as **UID 1002 / GID 1001** (`--user 1002:1001`); UID 1002 / GID 1001 owns
  the NAS files, and root-squash blocks root writes.
- Media mount: the `nas-video` NFS volume (`nas.apps.somemissing.info:/media/av`)
  mounted at `/media` via **subpath `TVShows`** — so the app only sees
  `/media/av/TVShows` and globs `.yt-dlp` scripts under it.
- **No GPU**: runtime `runc`, no device requests. The jobs download and
  stream-copy/remux (`-S ext:mp4:m4a`; the transcoding postprocessor stays
  commented out), so the jobs need no Intel QuickSync / i915 resource despite the
  ffmpeg base image carrying HW-accel libraries.

## Design

Everything lands in one new flat file **`yt-dlp.yaml`** at the repo root
(namespace `media`, already owned by `media.yaml` — do not redeclare the
Namespace). The root ArgoCD app-of-apps (`application.vmubtkube-a.yaml`)
recursively applies every root YAML, so this needs no `application.yt-dlp.yaml`
and no Kustomize/Helm — matching the hand-written image deployments
(`sabnzbd.yaml`, `jellyfin.yaml`).

### Workload topology (namespace `media`)

Three logical pieces:

1. **CronJob `yt-dlp`** — `schedule: "0 */2 * * *"` (every 2h, replacing the
   internal loop), `concurrencyPolicy: Forbid` (a long run skips the next tick
   rather than overlapping on the shared archive). `restartPolicy: Never`,
   `backoffLimit: 1`, `ttlSecondsAfterFinished` to reap finished jobs, and
   `activeDeadlineSeconds` as a runaway cap. Reuses the existing image with
   `RUN_ONCE=1` (see next section).
2. **Deployment `bgutil-provider`** (`replicas: 1`) — the POT provider, always-on
   and warm whenever a CronJob run fires. TCP readiness/liveness on :4416.
3. **Service `bgutil-provider`** (ClusterIP, :4416) — naming it `bgutil-provider`
   in the same namespace lets the baked `base_url=http://bgutil-provider:4416` in
   `yt-dlp.conf` resolve **unchanged** via cluster DNS. This is why bgutil takes a
   separate Deployment+Service rather than an in-pod sidecar: zero image edits,
   and it can restart/update independently of the download jobs.

The `yt-dlp` CronJob needs no inbound Service (nothing connects to it).

### The one-shot change (`download.py`)

A CronJob supplies the scheduling, so the container must run one pass and exit
instead of looping. Add a backward-compatible flag to the versioned
`infra/docker/usr/share/yt-dlp/download.py`:

```python
if __name__ == "__main__":
    if os.environ.get("RUN_ONCE", "").lower() in ("1", "true", "yes"):
        raise SystemExit(run_downloads())
    check_frequency = int(os.environ.get("CHECK_FREQUENCY", 8 * 60 * 60))
    # ... existing while-True loop unchanged ...
```

- Default (no `RUN_ONCE`) keeps the infinite loop, so the **same image still
  works on the Docker host** during and after transition.
- The CronJob sets `RUN_ONCE=1`; the container runs one pass and exits.
- **Recommended companion change:** have `run_downloads()` return a failure count
  (increment on each non-zero `yt-dlp` return, which it already logs) and, in
  one-shot mode, exit non-zero when any script failed. Today `run_downloads()`
  swallows per-script failures, so without this a broken download still exits 0
  and the CronJob looks green. Propagating the failure lets Kubernetes mark the
  Job failed and makes a `kube_job_status_failed` alert possible. Keep the loop
  mode's behavior (log-and-continue) as it stands.

This needs one image rebuild + push (see Prerequisites) and no edit to
`yt-dlp.conf` or the `Dockerfile`.

### Storage

Own PV+PVC pair, copying the sabnzbd/jellyfin NFS pattern verbatim (no shared
PVC, no nfs-subdir provisioner):

- **PV `yt-dlp-media`** → inline `nfs: {server: nas.apps.somemissing.info, path:
  /media/av}`, RWX, `persistentVolumeReclaimPolicy: Retain`. Capacity is advisory
  on static PVs; size generously (10Ti).
- **PVC `yt-dlp-media`** (namespace `media`) binds it via `volumeName` +
  `storageClassName: ""`, annotated `argocd.argoproj.io/sync-options:
  Prune=confirm` so ArgoCD never prunes the media binding automatically.
- Mounted at `/media` with **`subPath: TVShows`** to preserve the current scope
  exactly (the app globs `.yt-dlp` under `/media`, i.e. `/media/av/TVShows`).

### Security context

Match current UID/GID and the repo's NFS convention (jellyfin sets
runAsUser/runAsGroup and no fsGroup):

```yaml
securityContext:
  runAsUser: 1002
  runAsGroup: 1001
  runAsNonRoot: true
```

No `fsGroup` — the process already matches file ownership (1002:1001), and an
fsGroup chown against a root-squash NFS export does nothing useful and can stall
volume attach. The image already bakes `USER 1002:1001`, so running as 1002 comes
naturally.

### Images

- **yt-dlp**: reuse `registry.apps.nickv.me/yt-dlp:latest`. Follow the
  jellyfin/cukk convention for self-built `:latest` images — a
  `# renovate: datasource=custom.private-registry depName=registry.apps.nickv.me/yt-dlp`
  comment immediately above the `image:` line, with Renovate tracking the newest
  CI build by digest (match jellyfin.yaml's exact line shape, including any
  `@sha256:` pin, when writing the manifest).
- **bgutil-provider**: `registry.apps.nickv.me/brainicism/bgutil-ytdlp-pot-provider:1.3.1`,
  pulled through the registry's Docker Hub mirror (`renovate.json`
  `registryAliases`). Pin the minor tag; `datasource=docker` Renovate tracking.
- **No imagePullSecret** anywhere in this repo — the registry is an
  unauthenticated pull-through mirror. Reference the images directly.

### Resources

Media-downloader norms (from sabnzbd): yt-dlp `requests {cpu: 25m, memory:
256Mi}` / `limits {cpu: "2", memory: 4Gi}`. bgutil runs light: `requests {cpu:
10m, memory: 64Mi}` / `limits {cpu: 500m, memory: 512Mi}`.

### Labels & monitoring

- Labels: `app.kubernetes.io/name: yt-dlp` + `app.kubernetes.io/component:
  {yt-dlp,bgutil-provider}`. Deliberately **not** `name: arr` — the `media.yaml`
  ServiceMonitor selects `app.kubernetes.io/name: arr` on a `metrics` port, and
  yt-dlp exposes no metrics, so a different `name` keeps it out of that selector.
- No ServiceMonitor. Optional follow-up: a CronJob-health PrometheusRule off
  kube-state-metrics (`kube_job_status_failed`, or "no successful run in N hours"
  via `kube_cronjob_status_last_successful_time`) once the one-shot exit code
  propagates failures.

## Prerequisites (before the manifest merges)

1. **Rebuild + push the image** from `infra/docker/` with the `RUN_ONCE`
   change to `download.py` (and the recommended failure-propagation tweak), to
   `registry.apps.nickv.me/yt-dlp:latest`. Verify `RUN_ONCE=1 python3
   download.py` runs one pass and exits (locally or on the Docker host against a
   scratch dir). The Docker host container keeps working because the default
   behavior does not change.
2. Confirm the NAS export path and that `nas.apps.somemissing.info:/media/av`
   contains `TVShows` (it does — the current mount uses that subpath).

## Cutover runbook

No shared-identity constraint (unlike the torrent VPN migration) — the Docker
container and the CronJob can safely run against the same NAS archive during
overlap. The `--download-archive` files make double-runs idempotent.

1. Land `yt-dlp.yaml` on a branch; PR + merge. ArgoCD autosync applies it.
2. Verify the bgutil Deployment reads `Available` and the Service has an endpoint
   (`kubectl -n media get deploy,svc bgutil-provider`).
3. Trigger a manual one-off run instead of waiting for the schedule:
   `kubectl -n media create job --from=cronjob/yt-dlp yt-dlp-manual-1`. Watch
   logs: it should find the `.yt-dlp` script(s) under `/media`, reach the POT
   provider, and download/skip via the archive. Confirm it writes as 1002:1001
   and the Job completes (exit 0, or a non-zero surfaced correctly if the
   failure-propagation tweak lands).
   - Note: the **first** run can be long if the archive lags (each show allows up
     to `-I 0:50:1` items over `--dateafter now-365days`). If it risks exceeding
     `activeDeadlineSeconds`, run this initial backfill as a manual Job with a
     raised deadline, then let the scheduled CronJob handle steady-state
     increments (minutes per run).
4. Let one scheduled tick fire on its own; confirm `concurrencyPolicy: Forbid`
   and TTL cleanup behave (old Jobs reaped, no overlap).
5. **Decommission the Docker host stack**: `docker rm -f yt-dlp bgutil-provider`
   and remove the `ytdlp-net` network (or stop `50_yt-dlp.sh` from re-creating
   them). Keep the image build source in `infra/docker/` — it now doubles as the
   k8s image source.

## Rollback (fast)

The CronJob is additive and idempotent. To back out: delete `yt-dlp.yaml`
(ArgoCD prunes the CronJob/Deployment/Service; the PV/PVC are
`Prune=confirm`/`Retain` and stay), and re-run `infra/docker/50_yt-dlp.sh` on the
host to restore the containers. The move involves no data migration — the archive
lives on the NAS the whole time — so there is nothing to reconcile.

## Risks & mitigations

- **Silent failures look green** — `run_downloads()` swallows per-script
  non-zero exits. Mitigated by the recommended one-shot failure-propagation
  change plus an optional CronJob-failed alert. Without it, watch the logs.
- **Long first run vs `activeDeadlineSeconds`** — the archive makes runs
  resumable, so a truncated first pass just continues next tick; or run the
  backfill as a manual Job with a raised deadline (runbook step 3).
- **bgutil unavailable at run time** — if the POT provider pod is down, YouTube
  extraction may degrade/fail for that run. Mitigated by readiness/liveness on
  the always-on Deployment; the next tick recovers.
- **`:latest` image drift** — pin/track by digest via the Renovate custom
  datasource exactly like jellyfin/cukk, so ArgoCD deploys a known digest rather
  than whatever `:latest` currently points to.
- **NFS ownership** — writes must land as 1002:1001; verify in runbook step 3
  before decommissioning the host.

## Follow-ups / cleanup

- Retire the Docker host stack and note it wherever the host inventory /
  running-services list lives.
- Consider adding new `.yt-dlp` scripts (channels) directly on the NAS tree — the
  app picks them up automatically, no manifest change.
- Optional: CronJob-health PrometheusRule (above) and, if useful later, ship the
  yt-dlp logs to the cluster log pipeline.

## Appendix: reference manifest (`yt-dlp.yaml`)

Concrete starting point; reconcile the yt-dlp `image:` line with jellyfin.yaml's
exact self-built-image shape (renovate comment + digest) before merge.

```yaml
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: yt-dlp-media
spec:
  capacity:
    storage: 10Ti
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  volumeMode: Filesystem
  nfs:
    server: nas.apps.somemissing.info
    path: /media/av
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: yt-dlp-media
  namespace: media
  annotations:
    argocd.argoproj.io/sync-options: Prune=confirm
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Ti
  volumeName: yt-dlp-media
  storageClassName: ""
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bgutil-provider
  namespace: media
  labels:
    app.kubernetes.io/name: yt-dlp
    app.kubernetes.io/component: bgutil-provider
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: yt-dlp
      app.kubernetes.io/component: bgutil-provider
  template:
    metadata:
      labels:
        app.kubernetes.io/name: yt-dlp
        app.kubernetes.io/component: bgutil-provider
    spec:
      securityContext:
        runAsNonRoot: true
      containers:
        - name: bgutil-provider
          # renovate: datasource=docker depName=registry.apps.nickv.me/brainicism/bgutil-ytdlp-pot-provider
          image: registry.apps.nickv.me/brainicism/bgutil-ytdlp-pot-provider:1.3.1
          ports:
            - name: http
              containerPort: 4416
          readinessProbe:
            tcpSocket:
              port: 4416
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: 4416
            initialDelaySeconds: 10
            periodSeconds: 30
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: bgutil-provider
  namespace: media
  labels:
    app.kubernetes.io/name: yt-dlp
    app.kubernetes.io/component: bgutil-provider
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: yt-dlp
    app.kubernetes.io/component: bgutil-provider
  ports:
    - name: http
      port: 4416
      targetPort: 4416
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: yt-dlp
  namespace: media
  labels:
    app.kubernetes.io/name: yt-dlp
    app.kubernetes.io/component: yt-dlp
spec:
  schedule: "0 */2 * * *"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 200
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 10800
      ttlSecondsAfterFinished: 86400
      template:
        metadata:
          labels:
            app.kubernetes.io/name: yt-dlp
            app.kubernetes.io/component: yt-dlp
        spec:
          restartPolicy: Never
          securityContext:
            runAsUser: 1002
            runAsGroup: 1001
            runAsNonRoot: true
          containers:
            - name: yt-dlp
              # renovate: datasource=custom.private-registry depName=registry.apps.nickv.me/yt-dlp
              image: registry.apps.nickv.me/yt-dlp:latest
              imagePullPolicy: Always
              env:
                - name: TZ
                  value: America/New_York
                - name: MEDIA_ROOT
                  value: /media
                - name: RUN_ONCE
                  value: "1"
              volumeMounts:
                - name: media
                  mountPath: /media
                  subPath: TVShows
              resources:
                requests:
                  cpu: 25m
                  memory: 256Mi
                limits:
                  cpu: "2"
                  memory: 4Gi
          volumes:
            - name: media
              persistentVolumeClaim:
                claimName: yt-dlp-media
```
