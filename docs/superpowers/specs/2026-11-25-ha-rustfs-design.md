# HA rustfs (general in-cluster S3) — design

Status: proposed, 2026-11-25.

## Purpose

A shared S3 service for cluster apps and LAN hosts that stays readable and
writable through the loss of any one node: a drain, a kured reboot, or a
crash.

Out of scope:

- Migrating the CI cache (`woodpecker/rustfs.woodpecker.yaml`). It may move
  later; it stays single-node for now.
- Replacing rustfs on `vmubthh01.s.nickv.me` or MinIO on the NAS.
- Surviving a NAS outage. Every zvol lives on the one NAS, so the service goes
  down with it under any in-cluster layout.
- Backups of bucket contents. A consumer that needs one copies its bucket
  elsewhere.

## Decisions

| Area | Choice |
|---|---|
| Delivery | Upstream chart `rustfs` 1.0.6 from `https://charts.rustfs.com`, as ArgoCD `application.rustfs.yaml`, release name `rustfs`, namespace `rustfs` |
| Topology | Distributed mode, `replicaCount: 4`, `drivesPerNode: 1`, explicit parity `EC:2` |
| Placement | Chart default required pod anti-affinity on `kubernetes.io/hostname`; 4 of the 5 workers |
| Storage | 4 × 250Gi `zfs-generic-iscsi-csi` (1TB raw, about 500Gi usable); `obs_log_directory: ""` so logs go to stdout and the chart creates no logs PVC |
| Snapshots | `storageclass.pvcAnnotations.data` carries the `democratic-csi.org/config` block with `homelab:sanoid-skip: "true"` and `syncoid:sync: "false"`, as on the CI cache PVC |
| Disruption | `pdb.create: true`, `maxUnavailable: 1`; chart default `minReadySeconds: 45` between rolling restarts |
| Endpoint | `https://s3.k8s.somemissing.info` for every client, inside and outside the cluster |
| TLS | Native rustfs TLS with two certificates selected by SNI: a public one for clients, and one from a CA private to the `rustfs` namespace for peers |
| Credentials | Root keys from a mittwald secret-generator Secret, hex, used as `secret.existingSecret` |
| Metrics | rustfs pushes OTLP to a collector in its own namespace; Prometheus scrapes the collector. The Prometheus OTLP receiver stays off |
| Alerts | New `rustfs-ha-alerts.yaml`; existing CI cache rules get a scope so the two instances cannot mask each other |

### Failure behaviour

Four drives at `EC:2` need 2 drives to read and 3 to write.

| Pods down | GET of an existing `EC:2` object | PUT |
|---|---|---|
| 1 | yes | yes |
| 2 | yes | no |
| 3+ | no | no |

The two-down row covers object payload reads only. Other operations have
their own thresholds: a delete-marker vote needs three peers, for example, and
upstream documents no single outcome for every list, IAM, multipart or console
call. Treat two pods down as degraded, not as a read-only mode clients can
rely on. Test 7 records what ListObjectsV2 and DeleteObject do in that state.

The PDB keeps voluntary disruptions to one pod. The fifth worker changes what
happens next, and the two cases differ:

- **Drain.** The evicted pod reschedules onto the spare worker, its zvol
  reattaches there, and the pod becomes Ready again. The PDB then allows the
  next eviction. That is the intended kured behaviour: one pod down at a time,
  each for a few minutes.
- **Crash.** The pod object stays bound to the dead node. About five minutes
  after the node goes NotReady, Kubernetes marks the pod for deletion, but
  the deletion is graceful and needs kubelet on that node to confirm it. The
  pod stays Terminating and the StatefulSet does not create a replacement.
  The service runs on three pods, which still have write quorum, so recovery
  can wait. If the node returns, the pod restarts there and the drive heals.

  If the node does not return, fence it before anything else. A NotReady node
  may have lost only its network, with rustfs and every other workload on it
  still running and their zvols still mounted. Releasing a pod identity then
  lets a replacement attach the same zvol from another node, and two writers
  corrupt it. The only accepted fence is the VM powered off at the hypervisor
  and left off. A closed iSCSI session on the NAS does not count, because a
  partitioned VM can log back in later. Blocking one LUN on the NAS does not
  count either: the recovery step below detaches every volume on the node,
  not only the rustfs one.

Two recovery times apply to a crash. One takes minutes, the other can take
hours:

- **Client recovery, automatic.** The `s3` Service keeps routing about a
  quarter of new connections to the dead pod until Kubernetes marks the node
  NotReady (about 50 seconds). Acceptance threshold: request failures stop
  within 2 minutes of the node going down, and an S3 client with default
  retries (rclone, aws-cli) finishes its transfer without manual action.
- **Four-peer redundancy, manual.** Until the fourth pod runs again, a second
  failure makes the service read-only. `RustfsHAPodsNotReady` warns after 15
  minutes. No target time applies; hours are acceptable here.

Procedure for a node that will not return, in order:

1. Confirm at the hypervisor that the VM is off, and keep it off until step 6.
2. Taint the node `node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`.
   This is the Kubernetes path for a failed node: it deletes the stuck pods
   and force-detaches their volumes without waiting for kubelet. It applies
   to every pod and volume on the node, which is why step 1 allows no
   narrower fence.
3. Watch the replacement pod: its events, the old VolumeAttachment, and the
   democratic-csi controller log. Expect the old VolumeAttachment to go and a
   new one to appear for the spare worker.
4. If the replacement still waits on attachment after 10 minutes, read the
   CSI controller log before doing anything else. Delete the old
   VolumeAttachment by hand only when that log shows the detach cannot finish
   and the VM is still off.
5. Confirm the same PVC is the one attached, four peers are online, and the
   drive heals.
6. Remove the taint before powering the VM back on, or after deleting the
   Node object if the VM will not come back.

The README section records the fencing rule and this procedure.

### Endpoint and Service

The chart's Service (`rustfs-svc`) publishes the container port, 9000, and the
container runs as uid 10001 so it cannot bind 443. A second Service declared
in `extraManifests` gives clients a URL without a port:

- name `s3`, `ClusterIP`, selector = the chart's pod selector labels
- port 443 → 9000 (S3), port 9001 → 9001 (console)
- `external-dns.kubernetes.io/hostname: s3.k8s.somemissing.info`

In-cluster clients use the same name. They reach the ClusterIP through the
normal Service path, and the certificate matches.

`ingress.enabled: false`. The chart default is on and would render an nginx
Ingress for two `rustfs.com` hostnames that nothing here uses.

Path-style addressing only. `config.rustfs.domains` stays empty, so buckets
need no wildcard DNS record and no wildcard certificate.

### TLS

With `tls.enabled: true` the chart switches every listener to HTTPS, and it
also generates peer URLs as
`https://rustfs-{0...3}.rustfs-headless.rustfs.svc.cluster.local:9000/data`.
A public issuer cannot sign `cluster.local` names, so one certificate cannot
serve both clients and peers. rustfs selects a certificate by SNI from
subdirectories of `RUSTFS_TLS_PATH`, which gives each audience its own.

Only the rustfs pods ever check the peer certificate, so its CA belongs to
the `rustfs` namespace and nothing else trusts it. cert-manager owns the whole
chain, CA included; no key material comes from outside the cluster:

| Resource (namespace `rustfs`) | Kind | Purpose |
|---|---|---|
| `rustfs-selfsigned` | Issuer (`selfSigned`) | Bootstraps the CA |
| `rustfs-peer-ca` | Certificate (`isCA: true`, 10-year duration, Secret `rustfs-peer-ca`) | The private CA key pair |
| `rustfs-peer-ca` | Issuer (`ca.secretName: rustfs-peer-ca`) | Signs the peer certificate |
| `rustfs-peer` | Certificate, issued by `rustfs-peer-ca` | Peer identity |
| `s3-k8s-somemissing-info` | Certificate, issued by ClusterIssuer `cert-manager-webhook-dnsimple-production` | Client-facing identity |

| Certificate | Names | Path under `RUSTFS_TLS_PATH` |
|---|---|---|
| `rustfs-peer` | `*.rustfs-headless.rustfs.svc.cluster.local`, `rustfs-svc.rustfs.svc.cluster.local`, `localhost` | `rustfs_cert.pem`, `rustfs_key.pem` (default identity); its `ca.crt` as `public.crt` (outbound trust) |
| `s3-k8s-somemissing-info` | `s3.k8s.somemissing.info` | `s3.k8s.somemissing.info/rustfs_cert.pem`, `s3.k8s.somemissing.info/rustfs_key.pem` (SNI identity) |

Both Secrets go into one projected volume. rustfs pins a single `..data`
generation of its TLS directory before loading, and upstream requires the
whole directory to come from one projection. A second Secret mounted into a
subdirectory of the chart's own `/opt/tls` volume would sit outside that
generation, so the design does not use the chart's volume:

- `extraVolumes` declares projected volume `rustfs-tls` with both Secrets as
  sources and the item paths from the table. Projected item paths may contain
  a directory, which puts the SNI identity inside the same generation.
- `extraVolumeMounts` mounts it read-only at `/etc/rustfs-tls`.
- `extraEnv` sets `RUSTFS_TLS_PATH=/etc/rustfs-tls`. The chart renders
  `extraEnv` as container `env`, which wins over the ConfigMap value.
- `tls.enabled: true` and `tls.existingSecret: rustfs-peer` stay set, because
  that flag is what switches peer URLs and the readiness probe to HTTPS. The
  chart's own `/opt/tls` mount then exists but rustfs does not read it.
  `tls.trustSecret` stays empty.

A renewal of either certificate makes kubelet publish one new generation with
both identities, and rustfs reloads it (chart default, every 30s), so renewals
need no restart. No other workload holds the private CA. All five
cert-manager resources live in `extraManifests`.

On the first sync the pods sit in ContainerCreating until both Secrets exist.
The DNS-01 challenge for the public certificate takes a few minutes. The
first-sync checklist lists that wait as normal.

CA rotation is a manual procedure. cert-manager renews the CA certificate
before its ten years run out, but a changed CA Secret does not make it reissue
the leaves that CA signed. Until someone renews `rustfs-peer`, its Secret
still holds the old leaf and the old `ca.crt`, and a pod restart reloads
exactly that. The CA Certificate sets `privateKey.rotationPolicy: Never`, so
a routine CA renewal keeps the key and existing leaves keep verifying; only a
deliberate rotation (compromise, or a new key by choice) needs the procedure:

1. Record the SHA-256 fingerprint of the current CA from `tls.crt` in the
   `rustfs-peer-ca` Secret.
2. Delete the `rustfs-peer-ca` Secret so cert-manager issues a new CA with a
   new key. Wait until the Certificate is Ready and the Secret's fingerprint
   differs from the recorded one.
3. `cmctl renew rustfs-peer` and wait for Ready. Issuance is asynchronous, and
   an old leaf with its old `ca.crt` verifies fine against itself, so check
   against the CA read separately: `openssl verify` the leaf with `tls.crt`
   from the `rustfs-peer-ca` Secret, and confirm `ca.crt` in the `rustfs-peer`
   Secret has the new fingerprint.
4. Restart all four pods together. A rolling restart cannot work: a pod on the
   new CA and a pod on the old one reject each other.
5. Confirm four peers online and a put/get round trip.

Step 4 is a full outage of a few minutes. The plan rehearses this procedure on
the empty cluster, including quorum recovery, before any consumer stores data,
and the README section records it.

The upstream docs and chart source support the following three points, but
nobody has tried them on this cluster. The plan proves each one before any
data goes in:

1. A request with SNI `s3.k8s.somemissing.info` gets the dnsimple certificate
   and a peer request gets the private one.
2. rustfs loads the SNI identity from a subdirectory of the projected volume,
   and picks up a renewed certificate from a new generation without a restart.
3. Peers form a cluster with `public.crt` as their only trust source.

Fallback if (1) or (2) fails: rustfs serves only the private certificate and a
two-replica TLS proxy in front holds the public name. That costs an extra hop,
and the plan details it only if the proof fails.

### Credentials

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-root
  namespace: rustfs
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: RUSTFS_ACCESS_KEY,RUSTFS_SECRET_KEY
    secret-generator.v1.mittwald.de/encoding: hex
    secret-generator.v1.mittwald.de/length: "32"
```

The chart loads `secret.existingSecret` with `envFrom`, so the key names are
the environment variable names. `envFrom` alone is not enough: the Secret
exists as soon as ArgoCD applies it, but secret-generator fills in the keys a
moment later, `envFrom` accepts a Secret with missing keys, and a running
process never sees a later update. rustfs could start without its generated
root keys. To close that gap, `extraEnv` also declares `RUSTFS_ACCESS_KEY` and
`RUSTFS_SECRET_KEY` with required `secretKeyRef` entries, as the CI cache pod
does. A missing key then holds the container in CreateContainerConfigError
until the keys exist. `env` wins over `envFrom`, so both sources agree.

The chart cannot inspect an existing Secret, so the values include
`localEndpointHost.autoInject: true` to keep each pod's DNS-free endpoint
identity. The Secret is a repo-root manifest, `rustfs-root-secret.yaml`,
which the root app applies into namespace `rustfs`. It stays out of
`extraManifests` so a chart re-render never touches it.

The root keys are for administration. Each consumer gets its own rustfs user
and policy, created by hand with the console or `rc`; automating that is a
later piece of work.

### Network policy

One NetworkPolicy on the rustfs pods:

- 9000 and 9001 from anywhere (cluster pods and the LAN reach the ClusterIP;
  authentication is SigV4 and the console login)
- all ports between rustfs pods

rustfs pushes its metrics, so this policy opens no metrics port.

A second NetworkPolicy covers the metrics collector pod: 4318 from the rustfs
pods, 8889 from the `monitoring` namespace, nothing else.

### Resources and probes

The chart defaults to `resources: {}` and has no startupProbe value.

- Requests: 250m CPU and 1Gi memory per pod. Limit: 3Gi memory, no CPU limit.
  These are starting values; the plan records real usage under the upload
  tests and adjusts them once.
- Readiness: HTTPS `GET /health/ready` (the chart switches the scheme when
  TLS is on). kubelet does not verify the probe certificate.
- Liveness: with TLS on, the chart renders a TCP check on 9000, first run
  after 30 seconds, then every 5 seconds with 3 failures allowed. It only
  asks whether the listener is open. Time spent attaching the zvol does not
  count, because the clock starts with the container. A restart loop is
  possible only if rustfs opens its listener later than about 40 seconds
  after start. That default could also kill the starts the plan needs to measure, so the Application first ships with
  `livenessProbe.initialDelaySeconds: 300`. With that in place the plan
  measures container start to listener bind on first install and on a
  recovery start with a heal pending. The final setting is a startup
  allowance in seconds of at least twice the slowest measurement. The
  allowance is `initialDelaySeconds + (failureThreshold - 1) × periodSeconds`,
  because the first probe can already fail at the initial delay. The chart
  default works out to 30 + 2 × 5 = 40 seconds.

### Logging

Application logs must reach the cluster log pipeline through container
stdout. Three settings together decide that, and the plan proves the result:

- `obs_log_directory: ""` removes the logs PVC and file logging.
- `obs_environment: production` (chart default is `development`).
- `RUSTFS_OBS_LOG_STDOUT_ENABLED=true` through `extraEnv`. In rustfs 1.0.6
  this switch controls the local stdout mirror, separately from
  `obs_endpoint.use_stdout`, and production mode does not turn it on.

Proof: trigger a recognisable application event (a request with a bad access
key against a uniquely named bucket), then find that line in `kubectl logs`
and in `otel.otel_logs` in ClickHouse.

### Metrics

rustfs has no scrape endpoint; it only pushes OTLP. Prometheus could receive
that push directly, but its web port is LAN-routable
(`prometheus.k8s.somemissing.info`) and serves queries and the OTLP write path
together, so a NetworkPolicy cannot open one without the other. The receiver
stays off (`enableOTLPReceiver: false`, as today), and the CI
cache's pattern applies with the collector moved out of the pod, because the
chart has no sidecar hook:

- `rustfs-metrics`: a one-replica Deployment in namespace `rustfs`, declared
  in `extraManifests` with its ConfigMap. It copies the CI cache sidecar:
  image `otel/opentelemetry-collector-contrib:0.165.0` with the same
  `# renovate:` annotation, requests 10m CPU and 64Mi memory, a 128Mi memory
  limit, and the `batch` processor. One setting must differ: the sidecar's
  receiver binds `127.0.0.1:4318`, which only works inside a shared pod.
  Here the push arrives at the collector's pod IP, so the receiver binds
  `0.0.0.0:4318`. The `prometheus` exporter stays on `0.0.0.0:8889` with
  `resource_to_telemetry_conversion` on, so each rustfs pod's series keep
  their own instance labels. The collector's NetworkPolicy limits who can
  reach either port.
- A ClusterIP Service `rustfs-metrics` for the push target, plain HTTP inside
  the namespace.
- A PodMonitor with `release: prom`, so both Prometheus replicas scrape the
  collector and hold every series. Scraped series carry `namespace="rustfs"`.
- Chart values: `obs_endpoint.enabled: true` with
  `base_endpoint: http://rustfs-metrics.rustfs.svc.cluster.local:4318` and no
  path. The chart renders that as `RUSTFS_OBS_ENDPOINT`, and rustfs appends
  `/v1/metrics` to it, so a path here would double up. The CI cache passes
  the same bare form. `metrics.enabled: true` with `metrics.endpoint` set to
  the full `http://rustfs-metrics.rustfs.svc.cluster.local:4318/v1/metrics`,
  which rustfs uses as given (`RUSTFS_OBS_METRIC_ENDPOINT`); both settings
  resolve to one URL. Traces, logs and profiling export off (the cluster log
  pipeline reads stdout). `RUSTFS_OBS_SERVICE_NAME=rustfs-ha` and a per-pod
  instance id through `extraEnv`.
- The plan renders chart 1.0.6 with these values and checks the two
  environment variables before the Application merges, then confirms the
  collector logs no 404s once the pods push.

The collector is a single stateless pod. If it or its node goes down, rustfs
metrics stop until it reschedules, and batching does not bridge that gap.
The stock `KubeDeploymentReplicasMismatch` rule reports the missing pod after
15 minutes, ahead of `RustfsHAMetricsMissing` at one hour. Pod liveness
alerts do not depend on the collector. The plan confirms Renovate picks up
the image annotation from inside the Application's values.

The plan verifies the live label set and metric names after the first scrape
and before any rule merges, as the CI cache plan did.

### Alerts

`rustfs-ha-alerts.yaml`, namespace `monitoring`, `release: prom`. Every rustfs
series selector carries `namespace="rustfs"`.

| Alert | Source |
|---|---|
| `RustfsHAPodsNotReady` | `kube_statefulset_status_replicas_ready{namespace="rustfs"} < 4` for 15m, warning; `< 3` for 5m, critical. kube-state-metrics, so liveness does not depend on the metrics path |
| `RustfsHARestartLooping` | `increase(kube_pod_container_status_restarts_total{namespace="rustfs"}[30m]) > 2` |
| `RustfsHADriveOffline` | rustfs offline-drive gauge `> 0` for 15m |
| `RustfsHACapacity` | usable used / usable total `> 0.8` for 1h: the exported forms of `capacity_used_bytes` and `capacity_usable_total_bytes`, joined on the same reporting instance |
| `RustfsHAMetricsMissing` | `absent({__name__=~"rustfs_.*", namespace="rustfs"})` for 1h, warning |

Existing CI cache rules in `rustfs-alerts.yaml` select `rustfs_*` series with
no instance filter. Once a second rustfs exists, the HA instance's series
would keep `CICacheMetricsMissing` quiet while the cache is dead, and its
readiness and capacity series would match the other three rules. All four get
a `namespace="woodpecker"` matcher.

rustfs 1.0.6 exports raw total, usable total, usable used and usable free
capacity as separate gauges. The ratio must use the two usable ones: usable
used over raw total tops out near 50% at `EC:2`, and the alert would stay
quiet with the service full. The first scrape confirms the exported names,
and the fixture uses different raw and usable totals so a rule built on the
wrong one fails its test.

The repo runs `promtool test rules` on `.ci/test/prom-rules/*.test.yaml`, and
no rustfs fixture exists yet. One new fixture loads both rule files with
series from both namespaces and asserts:

- healthy `namespace="rustfs"` series do not stop `CICacheMetricsMissing`
  from firing when the `woodpecker` series are absent;
- CI cache usage above its threshold does not fire `RustfsHACapacity`, and HA
  usage above 80% does not fire `CICacheVolumeNearlyFull`;
- absent `namespace="rustfs"` series fire `RustfsHAMetricsMissing` while the
  CI cache series are present;
- each remaining HA rule fires on its own condition and stays quiet otherwise.

## Files

| File | Change |
|---|---|
| `namespace.rustfs.yaml` | create |
| `rustfs-root-secret.yaml` | create: generated root credentials |
| `application.rustfs.yaml` | create: chart values, plus `extraManifests` for the `s3` Service, the two Issuers, the three Certificates, the metrics collector (ConfigMap, Deployment, Service, PodMonitor), and the two NetworkPolicies |
| `rustfs-ha-alerts.yaml` | create |
| `rustfs-alerts.yaml` | scope the four CI cache rules to `namespace="woodpecker"` |
| `.ci/test/prom-rules/rustfs-alerts.test.yaml` | create: rule unit tests covering both rule files |
| `README.md` | short section: endpoint, how to add a bucket and user, failure behaviour, fencing and failed-node recovery, CA rotation |
| `renovate.json` | only if Renovate does not detect the chart's Helm repo without a rule |

## Risks

- **Shared pool growth.** The zvols are thin: `midline/k8s/pvs` has
  `zvolEnableReservation: false`, so creating four 250Gi PVCs succeeds
  whatever the pool holds, and says nothing about whether the data fits. At
  `EC:2` every logical byte costs two on disk, so about 500GiB of objects
  grows the pool by about 1,000GiB, before filesystem overhead inside each
  zvol and any raidz padding at the 16K block size. zstd compression may give
  some back; the budget does not count on it. Every other PVC and the NAS's other
  datasets share `midline`, and a full pool stops writes for each of them,
  not only for rustfs. Before the Application merges, the
  plan records `midline` free space, the current thin-provisioned total, and
  the other growing consumers, and requires that 1,000GiB of growth still
  leaves the pool under 80% full. If it does not fit, the PVC size drops
  before install, because the size cannot shrink later. `RustfsHACapacity`
  at 80% is the early warning from the rustfs side.
- **iSCSI load.** Four more sessions, spread over four nodes. The August
  stage/unstage convoy was about churn, and these volumes attach once.
- **Chart/image coupling.** Upstream says to upgrade chart and image together.
  Leaving `image.rustfs.tag` unset keeps the image on the chart's `appVersion`,
  so one Renovate PR moves both.
- **Young software.** rustfs reached 1.0 in October 2026 and its distributed
  startup logic changed within the last few releases. Renovate PRs for this
  chart get a rolling-restart check (one pod at a time, cluster healthy between
  each) before the next consumer depends on it.
- **Install-time topology.** Kubernetes rejects changes to `drivesPerNode` and
  the PVC template on a live StatefulSet. Growing means expanding all four
  zvols together, or adding a second pool.

## Verification

1. Render: `helm template` of chart 1.0.6 with the final values produces zero
   Ingress objects, the two OTLP environment variables as specified, and the
   projected TLS volume.
   First sync: pods wait in ContainerCreating until both certificate Secrets
   exist, then all four become Ready on four different nodes; four 250Gi PVCs
   bound; zvols carry the sanoid/syncoid properties. Record container start to
   listener bind for the liveness setting.
2. TLS: `openssl s_client -servername s3.k8s.somemissing.info` shows the
   dnsimple chain from a LAN host and from a pod; a peer name shows the
   `rustfs-peer-ca` chain.
3. S3: create a bucket and user, then put, list and get with rclone from a
   pod and from a LAN host using `https://s3.k8s.somemissing.info`.
   Logging: run the proof from the Logging section.
4. CA rotation rehearsal: run the five-step procedure from the TLS section on
   the empty cluster and confirm the peers re-form.

Tests 5 to 8 start by cordoning the spare worker (the one with no rustfs
pod). Without that, a displaced pod reschedules there within minutes and the
test measures timing, not the property. Each test uncordons everything and
waits for four Ready pods and a finished heal before the next one starts.

5. One pod held down. Cordon one rustfs node and delete its pod, so the pod
   stays Pending. Confirm three peers online and one offline in the rustfs
   admin view. Then, through `https://s3.k8s.somemissing.info`, start new
   transfers: put a multi-GB object and twenty small ones, get them back, and
   compare checksums. Repeat the puts enough times that connections land on
   all three surviving pods. After uncordoning, confirm the drive heals and
   the objects written during the outage read back from the returned pod.
6. Drain, PDB and reattachment. Drain one rustfs node. With its pod Pending,
   confirm `kubectl get pdb` shows `disruptionsAllowed: 0`, then attempt to
   evict a second pod and confirm the API refuses it. Next, uncordon only the
   spare worker and keep the drained node cordoned. Confirm the Pending pod
   schedules on the spare, the same PVC attaches there, all four peers come
   online, the drive heals, and the PDB shows `disruptionsAllowed: 1` again.
   This is the path every kured reboot takes.
7. Two pods held down. Cordon two rustfs nodes and delete their pods (the PDB
   governs evictions, not deletes). Confirm exactly two peers stay online for
   the whole test. Gets of existing objects succeed with matching checksums;
   puts fail. Also run ListObjectsV2 on a bucket and DeleteObject on one
   object, and record each result without a pass condition. After uncordoning, writes resume and both drives heal.
8. Crash. Run a loop of small puts and gets against the public endpoint with
   timestamps, then hard-reboot one rustfs node (`systemctl reboot --force
   --force`). Record how long requests fail and whether a concurrent rclone
   multi-GB upload completes with default retries. Pass: failures stop within
   2 minutes and the upload finishes with a matching checksum.
9. Permanent node loss. Note the UID of one rustfs pod, then power its node
   off abruptly (`systemctl poweroff --force --force`) and leave it off,
   which is also the fence. Leave the spare uncordoned.
   - Before tainting, wait for that pod UID to gain a deletion timestamp
     (about five minutes after NotReady). Confirm the pod is still
     Terminating, its VolumeAttachment still exists, and no replacement pod
     exists. This checks the crash model in the Failure behaviour section.
   - Then run the failed-node procedure from that section. Pass: a pod with a
     new UID mounts the same PVC on the spare without a manual
     VolumeAttachment delete, four peers come online, and the drive heals.
     Record the time from taint to four peers.
   - Powering the VM back on needs the hypervisor, so this test needs you or
     access to `ubthv01`.
10. Metrics visible in Thanos for all four pods; each new alert fires in a
    forced condition and clears; the rule unit tests pass in CI.
