# vmubtkube-a

ArgoCD root app for the `vmubtkube-a` cluster. Everything in this repo is
applied by the `vmubtkube-a` Application (`application.vmubtkube-a.yaml`),
which prunes and self-heals via ServerSideApply.

## Vendored upstream manifests

Upstream manifests that don't ship as a Helm chart — operators (CNPG,
cert-manager, contour), plugin bundles (barman-cloud), standalone CRDs
(external-secrets) — are vendored with
[vendir](https://github.com/carvel-dev/vendir) instead of committed as ad-hoc
YAML. vendir fetches a **whole upstream release atomically** — manifest, CRDs,
and RBAC together — so an image bump can't silently leave CRDs stale (which is
what happened before this setup). Only the `tag`/`ref` in `vendir.yml` is
edited; everything else is generated.

```
vendir.yml            # sources + pinned tags/refs (the only hand-edited file)
vendir.lock.yml       # fetched content digests (generated)
vendored/<name>/
  base/               # upstream files, written by `vendir sync` — never hand-edit
  kustomization.yaml  # present only when local patches are needed
```

- **Refresh:** bump a `tag`/`ref` in `vendir.yml`, run `vendir sync`, then commit
  `vendir.yml`, `vendir.lock.yml`, and the changed `vendored/*/base/` together.
- **Renovate** bumps `vendir.yml` via its `vendir` manager and runs
  `vendir sync` (`postUpgradeTasks`) so the refreshed base files land in the same
  PR — no manual re-download.
- **Local changes** (private-registry image mirrors, resource limits, config) go
  in a kustomize overlay next to the base. **Never edit `base/`** — the next sync
  overwrites it.
- **ArgoCD** renders each vendored component from its own Application: a plain
  directory source when there's no overlay, or a kustomize source when a
  `kustomization.yaml` is present. Base files are committed, so ArgoCD never
  runs vendir at sync time.

Manifests that *do* ship as Helm charts stay as ArgoCD Helm-source apps
(`application.<name>.yaml`); image-only deployments remain hand-written and are
tracked by Renovate's `kubernetes` manager. Full design:
`docs/superpowers/specs/2026-07-01-vendir-kustomize-design.md`.

## Manifest validation

CI runs `.ci/validate.sh` (kubeconform, strict; overlays validated as
`kustomize build` output) on every PR. To run the same check locally on each
commit:

```
pre-commit install   # needs kubeconform, pluto, and kustomize-or-kubectl on PATH
```

Schemas are cached under `.tmp/`, so repeat runs take ~2s.

CI itself caches two things across runs in a dedicated rustfs bucket
(`ci-cache`) in the cluster, restored and saved by the `cache-restore` /
`cache-save` steps:

- `charts/<chart>-<version>.tgz` — Helm chart tarballs (no more 23 `index.yaml`
  round trips per pipeline, ~90s)
- `schemas/<repo>.git.tar` — git object databases for the kubeconform schema
  mirrors. The 734 MB checkout is rebuilt locally from the cached
  sparse-checkout config, but the cached objects are **not** small: measured
  144 MB for `kubernetes-json-schema` + 16 MB for `CRDs-catalog`, i.e. ~160 MB
  moved per pipeline (the bucket's own `rustfs_bucket_usage_usage_bytes` agrees
  at 168 MB total). That buys ~12 s (13.7 s cold clone → 1.3 s warm) and removes
  a GitHub dependency from the critical path, so it is kept deliberately — it is
  cluster-local traffic, not internet traffic

The validation binaries stay plain `wget`s: caching them saved ~1.5s while
moving ~90 MB per pipeline into the bucket, so it was measured and dropped. The
secrets the cache steps use are rows in Woodpecker's own database, kept in sync
with the `rustfs-ci-cache` Secret by `woodpecker/cache-secrets.woodpecker.yaml`
— rotating the Secret needs no manual step.

Cache *contents* are fail-open: both steps run with `failure: ignore`, saves are
additive, and a miss only costs time. The cache *credential* is not: Woodpecker
resolves `from_secret` while compiling the pipeline, so if `cache_access_key` /
`cache_secret_key` are missing the whole pipeline fails before any step runs.
Those rows are maintained by `woodpecker/cache-secrets.woodpecker.yaml` (a
CronJob that upserts them from the `rustfs-ci-cache` Secret), which therefore has
to be deployed and to have run once — treat it as infrastructure, not a
convenience. `woodpecker/rustfs.woodpecker.yaml`
deploys the endpoint; design in
`docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`.

## DNS zones and TLS

Two DNS zones, split by audience:

- **`*.apps.somemissing.info`** — internet-facing services, exposed through
  the Contour edge (HTTPProxy) with public DNS.
- **`*.k8s.somemissing.info`** — internal/LAN-only services, reachable from the
  home network but not from the internet. These resolve to routable ServiceIPs
  via the `external-dns.alpha.kubernetes.io/hostname` annotation on a plain
  ClusterIP Service (external-dns writes the `k8s.somemissing.info` zone over
  RFC2136).

  **Why a bare ClusterIP is reachable from off-cluster:** Calico BGP-peers with
  the default gateway (`172.16.3.254`, AS 64512 on both sides) and advertises
  the Service CIDR `192.168.208.0/20` to it — see the `BGPConfiguration` /
  `BGPPeer` / `BGPFilter` resources in `application.calico.yaml`. The gateway
  therefore routes ClusterIPs straight to the nodes, so LAN clients connect to
  the ServiceIP directly. **No LoadBalancer, NodePort, or Ingress is needed to
  expose a service on the LAN** — reach for one only when you actually want L7
  features, and prefer the `*.apps` Contour edge for those. (A separate
  `192.168.240.0/28` pool is advertised for the few LoadBalancer Services that
  do exist, e.g. syslog ingest, which needs `externalTrafficPolicy: Local` to
  preserve the sender's source IP.)

Both zones get **publicly-trusted Let's Encrypt certificates** from the
`cert-manager-webhook-dnsimple-production` ClusterIssuer. DNS-01 validation
has no reachability requirement, so internal-only `*.k8s` hostnames are
issued the same way as public ones — no private CA to trust on clients. See
`grafana.yaml` for a minimal example, or `proxy_argocd_webhook.yaml` for a
cert consumed directly by the workload (`argocd-server-tls`).

The private `k8s` CA in `clusterissuer.yaml` is **not** for browser-facing
certs — it issues internal service-to-service certs (e.g.
`python-envoy-authz`, validated by Contour via the delegated `k8s-ca`
secret).

## HA rustfs (S3)

`application.rustfs.yaml` runs a four-pod erasure-coded rustfs in namespace
`rustfs`. Design: `docs/superpowers/specs/2026-11-25-ha-rustfs-design.md`.

- **Endpoint:** `https://s3.k8s.somemissing.info` for every client, inside
  and outside the cluster. Path-style, region `us-east-1`. Console:
  `https://s3.k8s.somemissing.info:9001/rustfs/console/`.
- **Capacity:** 4 × 250Gi zvols at `EC:2`, about 500Gi usable. Every byte
  stored costs two on the shared `midline` pool. The zvols are thin, so pool
  space is the real limit; `RustfsHACapacity` warns at 80% of usable.
- **Not backed up.** NAS snapshots and replication skip the zvols. A consumer that needs a backup copies its bucket elsewhere.
- **LAN uploads (open issue, 2026-11).** Uploads over about 64KB from LAN
  hosts to any ClusterIP stall for about 52 seconds on HTTP/1.1 and fail on
  HTTP/2. The likely cause, not yet confirmed on the router: LAN clients
  send through the router and replies return direct, so its firewall sees
  one direction only. In-cluster clients and LAN
  downloads work. Until the router handles this, LAN uploads need
  `--disable-http2` (rclone) and patience.
- **Descheduler.** The cluster descheduler evicts rustfs pods to balance
  nodes, one at a time under the PDB. Each eviction moves a zvol to another
  worker; the pod is back in well under a minute.
- **Separate from the CI cache.** `woodpecker/rustfs.woodpecker.yaml` is a
  different, single-pod instance. Alert rules tell the two apart by
  `namespace`.

### Adding a consumer

The root keys in Secret `rustfs/rustfs-root` are for administration only. For
each consumer, log in to the console with the root keys, create a bucket,
create a user with its own access key, and attach a policy limited to that
bucket. Store the consumer's keys the way `## Secret management` describes.

### Failure behaviour

| Pods down | GET of an existing object | PUT |
|---|---|---|
| 1 | yes | yes |
| 2 | yes | no |
| 3+ | no | no |

Two pods down is a degraded state, not a dependable read-only mode: list,
delete and multipart calls have their own thresholds.

A drain or kured reboot moves the pod to the spare worker and reattaches its
zvol; the PDB allows the next eviction only after that pod is Ready. A crashed
node is different: its pod stays `Terminating` on the dead node and nothing
replaces it. The service keeps reading and writing on three pods. Clients see
write errors for under a minute after a crash (43 seconds in the rehearsal;
reads did not fail), then recover without action.

### A node that will not come back

Three pods have write quorum, so do not rush this.

1. **Fence first.** The workers are physical machines with no remote power
   control. Confirm at the hardware that the machine is off (no power light,
   or pull the plug), and keep it off. A failed ping is not proof. A NotReady
   node may only have lost its network, with rustfs and
   every other pod still writing to their zvols. A closed iSCSI session on the
   NAS is not a fence, and neither is blocking one LUN.
2. `kubectl taint node <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`.
   This deletes the stuck pods on that node and force-detaches each of its
   volumes.
3. Watch the replacement: `kubectl -n rustfs get pods -w`, `kubectl get
   volumeattachment`, and the democratic-csi controller log. In the rehearsal
   this took under two minutes: the pod was Ready on the spare 48 seconds after the
   taint, and all four drives were online at 101 seconds, with no manual
   VolumeAttachment delete.
4. If the pod still waits on attachment after 10 minutes, read the CSI
   controller log. Delete the old VolumeAttachment by hand only when that log
   shows the detach cannot finish and the machine is still off.
5. Confirm four pods Ready and
   `rustfs_cluster_health_drives_online_count{namespace="rustfs"}` at 4.
6. Remove the taint before powering the machine back on, or after deleting
   the Node object if the machine will not come back.

### TLS

rustfs serves two certificates and picks one by SNI. Clients get the public
certificate for `s3.k8s.somemissing.info`. Peers use a certificate from a CA
that exists only in namespace `rustfs` (Certificate `rustfs-peer-ca`). Both
come from one projected volume, and rustfs reloads renewals without a
restart.

Rotating the private CA is manual and causes a full outage (22 seconds in
the rehearsal). cert-manager does not reissue
leaves when a CA changes.

```sh
fp() { kubectl -n rustfs get secret "$1" -o jsonpath="{.data.$2}" | base64 -d | openssl x509 -noout -fingerprint -sha256; }
OLD=$(fp rustfs-peer-ca 'tls\.crt')
kubectl -n rustfs delete secret rustfs-peer-ca
kubectl -n rustfs wait certificate/rustfs-peer-ca --for=condition=Ready --timeout=2m
NEW=$(fp rustfs-peer-ca 'tls\.crt'); [ "$OLD" != "$NEW" ] || echo "STOP: CA did not change"
cmctl renew -n rustfs rustfs-peer
kubectl -n rustfs wait certificate/rustfs-peer --for=condition=Ready --timeout=2m
# Verify against the CA Secret, not the leaf Secret's own ca.crt.
kubectl -n rustfs get secret rustfs-peer-ca -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.pem
kubectl -n rustfs get secret rustfs-peer -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl verify -CAfile /tmp/ca.pem /dev/stdin
[ "$(fp rustfs-peer 'ca\.crt')" = "$NEW" ] || echo "STOP: leaf Secret still trusts the old CA"
# All four together: a pod on the new CA and one on the old reject each other.
kubectl -n rustfs delete pod -l app.kubernetes.io/name=rustfs
kubectl -n rustfs rollout status statefulset/rustfs --timeout=10m
```

### Upgrades

Renovate bumps the chart, and the image follows the chart's `appVersion`.
After merging a bump, watch the rolling restart finish with four Ready pods
and the drive count back at 4 before relying on it. Topology (`replicaCount`,
`drivesPerNode`, PVC size in the template) cannot change in place; grow by
expanding all four PVCs together or by adding a pool.

## Secret management

Two mechanisms are available; pick by **where the secret originates**, not by
what kind of thing it is:

### 1. In-cluster generation (preferred for in-cluster-only credentials)

Credentials that exist solely to satisfy an in-cluster service — database
passwords, app admin passwords, inter-service tokens that nothing outside the
cluster ever needs — should be **auto-generated in the cluster** by the
[mittwald kubernetes-secret-generator](https://github.com/mittwald/kubernetes-secret-generator)
(installed in `operators`, see `application.secret-generator.yaml`).

Declare the Secret empty in git with the trigger annotation; the controller
fills `data.password` with a random string on first sync:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: example-password
  namespace: default
  annotations:
    secret-generator.mittwald.de/secret-type: password
    secret-generator.mittwald.de/password-length: "32"
type: Opaque
```

Why prefer this:

- Nothing to pre-create or rotate by hand — the value is generated once and
  persisted in-cluster.
- No secret material in git, and no dependency on the external store for
  bootstrapping.
- Under ServerSideApply the controller owns the `data` field, so ArgoCD
  self-heal won't clobber it. (Rotate by deleting/regenerating the Secret; the
  consuming workload restarts via Reloader.)

See `mumble.yaml` for a working example.

### 2. Bitwarden + ExternalSecrets (for off-platform-originated secrets)

[External Secrets Operator](https://external-secrets.io) (installed via
`application.external-secrets.yaml`) syncing from the Bitwarden-backed
`ClusterSecretStore` named `default` is primarily for secrets whose value is
**defined off-platform** — third-party API tokens, upstream service
credentials, pre-existing accounts whose password can't be invented here. The
source of truth is Bitwarden, and the cluster reflects it.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example-config
  namespace: default
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    name: example-config
  data:
  - secretKey: api-token
    remoteRef:
      key: example-api-token
```

See `selfoss.yaml` for a working example.

### When a literal value is committed

Occasionally a secret is intentionally checked into git because there is no
sensible off-platform source and no in-cluster generator (e.g. an opaque key
the receiver doesn't even enforce). That should be rare and always accompanied
by a note in `docs/` explaining why — see `docs/hyperdx-api-key.md`.
