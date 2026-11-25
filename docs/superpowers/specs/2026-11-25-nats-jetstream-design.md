# HA NATS JetStream with cert-manager mTLS

**Date**: 2026-11-25
**Status**: Design — not yet implemented

---

## Problem

The cluster has no message bus. Pods on vmubtkube-a and hosts on the LAN
(Home Assistant, VMs, other devices) need a shared, durable messaging service.

## Goal

A three-node NATS cluster with JetStream, reachable at
`nats.k8s.somemissing.info:4222`, where every client authenticates with a
client certificate issued by cert-manager, and NATS maps that certificate to
a named user.

Success means:

- The cluster keeps serving reads and writes on R3 streams while any one
  node is down (node failure, kured reboot, rolling upgrade).
- A client with no certificate, or a certificate from any other CA, cannot
  connect.
- Adding a client is a `Certificate` plus one user entry in git.

## Decisions

| Topic | Decision |
|-------|----------|
| Deployment | Official `nats` Helm chart 2.15.3 (NATS server 2.15.3) as an ArgoCD `Application` with inline `valuesObject` |
| Exposure | Chart ClusterIP Service with `external-dns.kubernetes.io/hostname: nats.k8s.somemissing.info`; Service IPs are routable from the LAN |
| Server cert | ClusterIssuer `cert-manager-webhook-dnsimple-production` (Let's Encrypt, DNS-01), same as `otel-agent-gateway.yaml` |
| Client CA | New dedicated CA, ClusterIssuer `nats-ca` |
| Route CA | Second dedicated CA, namespaced Issuer `nats-route-ca` in `nats` |
| Network | `NetworkPolicy` limits 6222, 8222 and 7777 to their intended peers |
| Authentication | Client certificate only, `verify_and_map: true` |
| Authorization | One application account, one user per client, optional subject permissions; separate system account |
| Replicas | 3, spread across worker nodes |
| Storage | 10Gi file store per replica on `zfs-generic-iscsi-csi` |

## Out of scope

- Stream and consumer definitions. They arrive with the first workload.
- MQTT, websocket, leafnode and gateway listeners.
- Separate isolated accounts per group of clients.
- Automatic delivery of certificates onto LAN devices.
- The host-side certificate exporter (cron job and script). It lives in the
  Ansible repo; this repo defines the metric contract and the alerts.
- Onboarding Home Assistant or any other real device. That later change
  adds the device's `nats-device-` `Certificate`, its user entry and its
  exporter together.
- Survival of a NAS outage (all volumes are on one NAS).

---

## Files

| File | Contents |
|------|----------|
| `namespace.nats.yaml` | `nats` namespace |
| `nats-pki.yaml` | Client CA and `nats-ca` ClusterIssuer, route CA and `nats-route-ca` Issuer, server, route and client `Certificate`s |
| `nats-networkpolicy.yaml` | `NetworkPolicy` for the NATS pods |
| `application.nats.yaml` | ArgoCD `Application` for the chart, destination namespace `nats` |
| `prometheus-ext.yaml` (edit) | Scrape job for cert-manager's `nats` certificate series |
| `nats-alerts.yaml` | Two `PrometheusRule`s in `monitoring`: NATS (`release: prom`) and client certificates (`prometheus: ext`) |
| `cert-manager-monitoring.yaml` | `PodMonitor` for the cert-manager controller and a `PrometheusRule` for issuance failures |
| `.ci/test/prom-rules/nats-alerts.test.yaml`, `cert-manager-alerts.test.yaml` | `promtool` fixtures for the rules above |

The root app (`application.vmubtkube-a.yaml`) picks up the manifests from the repo
root. Renovate tracks the chart version.

## PKI

### Client CA

Copy the shape of the `k8s` CA in `clusterissuer.yaml`:

- `Issuer` `nats-ca-selfsigned` in `cert-manager` (`selfSigned: {}`).
- `Certificate` `nats-ca` in `cert-manager`: `commonName: nats-client-ca`,
  `isCA: true`, ECDSA P-256,
  `duration: 87660h`, `secretName: nats-ca-tls`.
- `ClusterIssuer` `nats-ca` with `ca.secretName: nats-ca-tls`.

A ClusterIssuer, not a namespaced Issuer, so that an app in another namespace
can hold an auto-renewing client certificate next to its pods.

**Who can mint NATS credentials.** NATS maps a certificate subject to a user;
it knows nothing about Kubernetes namespaces. Any principal that can create
a `Certificate` referencing `nats-ca` and read the resulting `Secret`, in any
namespace, can request `CN=nats-admin` or `CN=nats-operator` and act as that
user. The design accepts this on one assumption, which the implementer must
confirm and which must stay true:

- No identity other than a cluster administrator can get a certificate
  signed by `nats-ca`. Two paths exist, and the assumption must hold for
  both:
  - **`CertificateRequest`.** The requester generates the key and reads the
    signed certificate from the object's status. Create permission on
    `certificaterequests` is enough; Secret access plays no part.
  - **`Certificate`.** cert-manager writes the key and certificate to a
    `Secret`. The requester needs create on `certificates`, or update or
    patch on an existing one (a changed subject or issuer triggers
    reissuance), plus a way to
    read that Secret: a direct `get` on Secrets, or the right to create a
    Pod or other workload in the namespace, which can mount it.

The rollout checks this before `nats-ca` exists (Verification, step 1).

If certificate issuance is ever delegated, this design no longer holds as
written. Before delegating, restrict the subjects each principal may
request, with cert-manager's approver-policy or by giving each delegated
namespace its own intermediate issuer and a separate NATS trust mapping.

### Server certificate

`Certificate` `nats-server` in `nats`, issuer
`cert-manager-webhook-dnsimple-production`, `commonName` and single DNS name
`nats.k8s.somemissing.info`, `secretName: nats-server-tls`.

Consequences:

- Clients verify the server with their system trust store. No CA file to
  distribute for server verification.
- Let's Encrypt cannot sign in-cluster service names. **Every client,
  including pods and nats-box, connects to `nats.k8s.somemissing.info`**, not
  `nats.nats.svc`.
- Renewal is frequent. The chart's config reloader sidecar watches the
  mounted secret and signals the server, so the pods do not restart.

### Route CA

Routes get their own CA so that a client certificate can never open a route.
The route listener checks only that a peer certificate chains to its CA; the
user mapping on port 4222 does not apply on port 6222, and client
certificates carry the `client auth` usage that inbound route TLS accepts.
With one shared CA, any NATS client could join the cluster as a server.

- `Issuer` `nats-route-ca-selfsigned` in `nats` (`selfSigned: {}`).
- `Certificate` `nats-route-ca` in `nats`: `commonName: nats-route-ca`,
  `isCA: true`, ECDSA P-256,
  `duration: 87660h`, `secretName: nats-route-ca-tls`.
- `Issuer` `nats-route-ca` in `nats` with `ca.secretName: nats-route-ca-tls`.

A namespaced Issuer, so only a `Certificate` in the `nats` namespace can
get a route certificate.

Both roots set an explicit, distinct `commonName`. A self-signed certificate
with no subject also has an empty issuer DN, which cert-manager warns
against and some TLS libraries reject.

### Route certificate

`Certificate` `nats-route` in `nats`, issuer `nats-route-ca` (kind `Issuer`), DNS names
`*.nats-headless`, `*.nats-headless.nats`, `*.nats-headless.nats.svc`,
`*.nats-headless.nats.svc.cluster.local`, usages `server auth` and
`client auth`, `secretName: nats-route-tls`.

cert-manager writes the issuing CA to `ca.crt` in the same secret, so the
cluster TLS block uses `ca_file: /etc/nats-certs/cluster/ca.crt` with
`verify: true`.

### Client certificates

One `Certificate` per client, issuer `nats-ca`, usage `client auth`, only a
`commonName` (no SANs). With no SANs present, `verify_and_map` matches the
RFC 2253 subject, so the NATS user name is `CN=<commonName>`.

| Client | Namespace | Duration | Notes |
|--------|-----------|----------|-------|
| `nats-admin` | `nats` | cert-manager default | nats-box context `default`; system account (server and cluster reports) |
| `nats-operator` | `nats` | cert-manager default | nats-box context `app`; full access in `APP` for stream administration and tests |
| `nats-lan-test` | `nats` | cert-manager default | Temporary identity for the acceptance tests; restricted like a device, removed in the last verification steps |

In-cluster application clients add their own `Certificate` in their own
namespace when they adopt NATS.

**LAN devices.** This work provisions no real device; the rules below apply
from the first device onboarding. A device `Certificate` uses
`duration: 8760h` and `renewBefore: 720h`, lives in `nats` and has the name
`nats-device-<commonName>`. That name prefix is the inventory of expected
device clients: the missing-metrics alert reads it from cert-manager's
metrics. The secret stays in `nats`. The operator extracts
`tls.crt` and `tls.key` with `kubectl` and installs them on the device.
cert-manager renews the secret 30 days before expiry but cannot push it to
the device, so monitoring reads the certificate file on the device itself.

**Client certificate metric contract.** Every NATS client outside
Kubernetes must export the validity of its installed client certificate in
the form below. The alerts match on these names and labels only, so one rule
set covers every client and a new client needs no alert change.

| Metric | Type | Labels | Value |
|--------|------|--------|-------|
| `nats_client_cert_not_after_seconds` | gauge | `cn`, `file` | Expiry of the installed certificate, unix seconds |
| `nats_client_cert_not_before_seconds` | gauge | `cn`, `file` | Start of validity, unix seconds |
| `nats_client_cert_exporter_last_run_timestamp_seconds` | gauge | none | Time the last run completed, unix seconds |
| `nats_client_cert_exporter_errors` | gauge | none | Certificate files that failed to parse in the last run |

Rules for an exporter:

- `cn` is the certificate's common name, unchanged. It equals the
  `commonName` of the `Certificate` and the NATS user name without the `CN=`
  prefix, so an alert names the NATS user directly.
- `file` is the absolute path of the certificate file on the host, for
  information only. `cn` alone identifies a client; alerts never match on
  `file`, so moving the file does not change the client's identity.
- Export one `not_after` and one `not_before` series per installed
  certificate file. A host with two client certificates exports two pairs.
- Add no other labels. `instance` and `job` come from the scrape.
- Export the two exporter gauges once per host, with no labels.
- Read the file the client process loads, not a copy.
- Run at least once an hour and replace the output file atomically (write a
  temporary file, then rename).
- On a parse failure, count it in `nats_client_cert_exporter_errors` and
  still write the last-run timestamp.
- Never read or export anything from the private key.

Reference delivery: a cron job writes `nats_client_cert.prom` to
node-exporter's textfile collector directory, the pattern of
`kubeadm-cert-exporter.yaml` moved from a DaemonSet to cron on the host.
`prometheus-ext` scrapes node-exporter on these hosts, so a host that joins
NATS must have a target in `prometheus-ext.yaml`. The cron job and script
belong to the host's playbook in `~/Documents/workspace/misc/ansible` and are
a cross-repo dependency of this design. Any other delivery is acceptable if
`prometheus-ext` ends up with the same series.

Clients inside Kubernetes are outside the contract: they mount the
cert-manager secret and pick up renewals without a copy step.

The resulting flow: cert-manager renews at 30 days left, the device alert
fires at 21 days left with the new certificate already waiting in the
secret, the operator copies it over, and the alert clears only when the file
on the device changes.

**Decommissioning a device** takes two changes, merged and applied one
after the other. They cannot share a commit: the root ArgoCD application
prunes a deleted `Certificate` at once, while the NATS config travels
through the child application and a reload on each of three servers. In one
commit the alert inventory entry could vanish while the credential still
works.

1. **Revoke.** Remove the client's user entry from the NATS config and merge.
2. **Confirm.** Wait until all three servers log the config reload. Then
   connect with the old credential at least ten times through the Service;
   every attempt must fail authorization. The missing-metrics alert may
   fire during this stage, which is correct.
3. **Remove.** In a second change, delete the `Certificate`. This ends the
   inventory entry and its alert.
4. **Clean up.** Delete the TLS `Secret` by hand. cert-manager here runs
   without `--enable-certificate-owner-ref`, so it leaves the Secret, and
   the private key in it, behind. Delete the copies on the device as well.

**Revocation.** cert-manager issues no CRL. Remove the user entry from the
NATS config (the revoke step of decommissioning); the reloader applies it and the certificate no longer maps to a
user.

## NATS configuration

Set through chart values.

**Client listener (`config.nats.tls`)**

- `enabled: true`, `secretName: nats-server-tls`.
- `merge: { verify_and_map: true, ca_file: /etc/nats-client-ca/ca.crt }`.
- JSON patches put the client CA public certificate at
  `/etc/nats-client-ca`: `podTemplate.patch` appends a volume
  (`op: add`, `path: /spec/volumes/-`) and `container.patch` appends a mount
  (`op: add`, `path: /volumeMounts/-`).
- The volume projects only the `ca.crt` key of `nats-admin-tls`. cert-manager
  fills that key with the `nats-ca` certificate, and projecting one key keeps
  the admin private key and the CA signing key out of the server pods.
  `nats-route-tls` is not a source for this: its `ca.crt` is the route CA.
- Reload on change needs two conditions, and a render confirmed both. The
  mount path starts with `/etc/`, so the chart mirrors the mount into the
  reloader container. The rendered config references the file as `ca_file`,
  so the chart adds `-config /etc/nats-client-ca/ca.crt` to the reloader's
  watch arguments.
- Do not use `podTemplate.merge` or `container.merge` for this. A render of
  chart 2.15.3 showed that a merge replaces the whole list: the NATS
  container lost its config, PID, data and TLS mounts. The patch form keeps
  all five and adds the sixth.
- The chart-level `tlsCA` option stays disabled. It would put one CA in
  every TLS block and in the nats-box context, but the server certificate
  and the client-verification CA are different chains here.

**Cluster (`config.cluster`)**

- `enabled: true`, `replicas: 3`, `routeURLs.useFQDN: true`.
- `tls.enabled: true`, `tls.secretName: nats-route-tls`,
  `tls.merge: { verify: true, ca_file: /etc/nats-certs/cluster/ca.crt }`.
- `noAdvertise: true` (chart default), so LAN clients are never handed pod
  addresses.

**JetStream (`config.jetstream`)**

- `enabled: true`, file store PVC `size: 10Gi`,
  `storageClassName: zfs-generic-iscsi-csi`.
- `fileStore.maxSize: 8Gi`. The chart default equals the PVC size, which
  leaves no room for filesystem overhead before the volume fills.

**Accounts (`config.merge`)**

```yaml
system_account: SYS
accounts:
  SYS:
    users:
      - user: CN=nats-admin
  APP:
    jetstream: enabled
    users:
      - user: CN=nats-operator
      - user: CN=nats-lan-test   # temporary, removed after acceptance
        permissions:
          publish: ["lantest.>"]
          subscribe: ["lantest.>", "_INBOX.>"]
```

A user with no `permissions` block has full access inside `APP`, which is
what `nats-operator` needs and what a workload must not have.

Workload users get no `$JS.API.>` access. That prefix covers stream delete
and purge for every stream in the account, whatever the data-subject limits
say. The example above is enough to publish into a stream that captures
`lantest.>` and receive the publish acknowledgment. `nats-operator`
creates streams and durable consumers. A workload that consumes from
JetStream gets only the subjects for its own consumer, for example
`$JS.API.CONSUMER.MSG.NEXT.<stream>.<consumer>` and
`$JS.ACK.<stream>.<consumer>.>`; the exact list belongs to the spec for that
workload.

**Monitoring port.** `config.monitor` stays on plain HTTP 8222 for kubelet
probes and the in-pod exporter. NATS monitoring has no authentication, the
pod listens on its pod IP, and the chart also publishes 4222, 6222 and 8222
on `nats-headless`. The NetworkPolicy below is the control.

## Network policy

`nats-networkpolicy.yaml` holds one ingress `NetworkPolicy` selecting the
NATS server pods:

| Port | Allowed from |
|------|--------------|
| 4222 | Anywhere (clients authenticate with certificates) |
| 6222 | NATS server pods only |
| 7777 | Prometheus pods in `monitoring` |
| 8222 | Nobody |

Kubelet probes still reach 8222: Calico always allows traffic from a node to
its own pods. The exporter reaches it over localhost. Follow the shape of the
existing policy in `otel-agent-trace-connector.yaml`.

## Scheduling and availability

- `podTemplate.topologySpreadConstraints` on `kubernetes.io/hostname`,
  `maxSkew: 1`, `whenUnsatisfiable: DoNotSchedule`. With no control-plane
  toleration the pods land on three of the five workers.
- `podDisruptionBudget.enabled: true` (chart default, one pod unavailable at
  a time). kured drains respect it.
- Container resources: requests `100m` CPU / `256Mi`, memory limit `1Gi`,
  `GOMEMLIMIT` set to about 90% of the limit.
- Create streams with `--replicas 3` to get the HA property; the server does
  not enforce it.

**Known limit.** The three volumes are iSCSI LUNs on one NAS. The design
covers node loss and rolling maintenance. A NAS outage stops JetStream.

## Exposure

- `service.merge.metadata.annotations` carries
  `external-dns.kubernetes.io/hostname: nats.k8s.somemissing.info` (GA
  prefix, per the 2026-08 external-dns incident).
- Only port 4222 is on the Service. The headless Service carries 6222 for
  routes.

## Operations tooling

`natsBox.enabled: true` with two contexts. `default` mounts the `nats-admin`
secret (`natsBox.contexts.default.tls.secretName`) for system-account
commands such as `nats server list`. `app` mounts the `nats-operator` secret
for stream work in `APP`; the system account cannot hold JetStream data. A
context `merge` sets each URL to `nats://nats.k8s.somemissing.info:4222` so
server verification matches the Let's Encrypt name. nats-box trusts public
roots from its image.

## Monitoring and alerts

### NATS

`promExporter.enabled: true`, `promExporter.podMonitor.enabled: true`, with
`release: prom` added through `podMonitor.merge`; the main Prometheus
selects PodMonitors on that label in every namespace. The chart starts
exporter 0.20.3 with `-jsz=all -use_internal_server_id -prefix=nats`. Metric
and label names below come from that version's `collector/jsz.go`.

Every expression carries the selector `job="nats/nats"`, written `{S}` here,
so the rules apply to this deployment only. `or vector(0)` makes a count
return zero when there are no series, so zero discovered targets alerts
instead of evaluating to nothing.

| Alert | Expression | For | Severity |
|-------|------------|-----|----------|
| `NatsTelemetryMissing` | `(count(up{S} == 1) or vector(0)) < 3` | 10m | warning |
| `NatsServerNotReporting` | `(count(count by (server_id) (nats_server_jetstream_disabled{S})) or vector(0)) < (count(up{S} == 1) or vector(0))` | 10m | warning |
| `NatsJetStreamDisabled` | `nats_server_jetstream_disabled{S} == 1` | 5m | critical |
| `NatsJetStreamMetaLeader` | `(count(nats_server_jetstream_disabled{S, is_meta_leader="true", meta_leader!=""} == 0) or vector(0)) != 1 and on() count(nats_server_jetstream_disabled{S}) >= 1` | 5m | critical |
| `NatsJetStreamStorageHigh` | `nats_server_total_message_bytes{S} / (nats_server_max_storage{S} > 0) > 0.8` | 30m | warning |

- `NatsTelemetryMissing` is about scrapes: an exporter is down or was never
  discovered. `NatsServerNotReporting` is about servers: the exporter
  answers but its NATS server returns no JetStream data.
- `NatsJetStreamMetaLeader` fires when no server, or more than one, claims
  the meta leader role. A server counts as leader only with
  `is_meta_leader="true"`, a non-empty `meta_leader` and JetStream enabled.
  The exporter also sets `is_meta_leader="true"` when a server reports no
  meta group at all, with `meta_leader` empty; counting that server would
  hide a real outage or show a healthy cluster as having two leaders. The `and on()` clause requires JetStream telemetry
  to be present, so leader loss with healthy scrapes and missing telemetry
  raise different alerts.
- `NatsJetStreamStorageHigh` compares message bytes with the JetStream file
  store limit (`max_storage`, 8Gi). Its annotation reads "JetStream message
  bytes exceed 80% of the configured store limit". It says nothing about
  the filesystem; the existing `KubePersistentVolumeFillingUp` rule is the
  signal for the volume.

`.ci/test/prom-rules/nats-alerts.test.yaml` covers: three healthy servers
with one leader (nothing fires), zero targets, one target down, exporter up
with no server series, no leader with healthy scrapes, two leaders, a
server with no meta group beside a real leader, the same server with no real
leader, and storage over the threshold. `.ci/validate-prom-rules.sh` runs it in CI.

### cert-manager

Prometheus does not scrape cert-manager today: the controller serves
`/metrics` on port 9402 (`http-metrics`), but no `PodMonitor` or `ServiceMonitor` selects it and the
main Prometheus holds no `certmanager_*` series. NATS depends on renewals
of the Let's Encrypt server certificate and the route certificate, so this
design adds the scrape and the failure alerts.

`cert-manager-monitoring.yaml`:

- `PodMonitor` `cert-manager` in `cert-manager`, label `release: prom`,
  selecting the controller pod (`app.kubernetes.io/name: cert-manager`,
  `app.kubernetes.io/component: controller`), port `http-metrics`.
- `PrometheusRule` `cert-manager-alerts` in `monitoring`, label
  `release: prom`. The rules cover every `Certificate` in the cluster, not
  only the NATS ones:

| Alert | Expression | For | Severity |
|-------|------------|-----|----------|
| `CertManagerCertificateNotReady` | `certmanager_certificate_ready_status{condition=~"False\|Unknown"} == 1` | 1h | warning |
| `CertManagerRenewalOverdue` | `time() - (certmanager_certificate_renewal_timestamp_seconds > 0) > 86400` | 1h | warning |
| `CertManagerCertificateExpiryCritical` | `(certmanager_certificate_expiration_timestamp_seconds > 0) - time() < 3 * 86400` | 1h | critical |
| `CertManagerScrapeDown` | `absent(up{job="cert-manager/cert-manager"} == 1)` | 30m | warning |
| `CertManagerCertificateMetricsMissing` | `count(up{job="cert-manager/cert-manager"} == 1) > 0 unless on() count({__name__=~"certmanager_certificate_.*"}) > 0` | 30m | warning |

- `CertManagerCertificateNotReady` matches `Unknown` as well as `False`:
  cert-manager reports `Unknown` for a certificate with no Ready condition.
- `CertManagerRenewalOverdue` is the failed-renewal signal: the renewal time
  passed a day ago and the certificate is still the old one. The alert
  value is seconds overdue, and the annotation says so. The deadline is the
  certificate's `notAfter`; the annotation tells the operator to read it
  from the `Certificate` status and names no fixed number of days.
- `CertManagerCertificateExpiryCritical` has seconds remaining as its
  value, rendered with `humanizeDuration`.
- Two alerts replace a single "metrics missing" rule so the cause is
  visible: `CertManagerScrapeDown` means Prometheus cannot reach the
  controller; `CertManagerCertificateMetricsMissing` means the scrape works
  but returns no certificate series.
- cert-manager v1.21.3 exports zero for the renewal and expiry timestamps
  until a certificate has its first issuance. The `> 0` filters keep a
  pending certificate from reading as overdue since 1970;
  `CertManagerCertificateNotReady` covers pending issuance.
- `CertManagerCertificateMetricsMissing` matches on the metric name prefix,
  following
  the reasoning in `rustfs-alerts.yaml`: a renamed metric must not hide a
  broken scrape.
- These rules are new for the whole cluster, so they can fire for existing
  certificates. The plan checks the current series before enabling them.

`.ci/test/prom-rules/cert-manager-alerts.test.yaml` covers a healthy
certificate, a not-ready one, one with `Unknown` readiness, an overdue renewal, near
expiry, scrape down, scrape up with no certificate series, and
a certificate awaiting first issuance (only the readiness rule fires).

### Client certificates

- `nats-alerts.yaml` also holds a second `PrometheusRule` labelled
  `prometheus: ext`, like `podman-quadlet-alerts.yaml`, built only on the
  contract metrics. No rule names a host or a client; annotations use the
  `cn` and `instance` labels. Thresholds mirror the kubeadm certificate
  alerts:
  - `NatsClientCertExpiry`: `nats_client_cert_not_after_seconds - time()`
    under 21 days (warning).
  - `NatsClientCertExpiryCritical`: under 7 days (critical).
  - `NatsClientCertExporterStale`: last run more than 3 hours ago (warning).
  - `NatsClientCertExporterParseErrors`: errors above zero for 2 hours
    (warning).
  - `NatsClientCertMetricsMissing`: an expected device client has no
    series, for 2 hours (warning):
    `label_replace(group by (name) (certmanager_certificate_ready_status{namespace="nats", name=~"nats-device-.+"}), "cn", "$1", "name", "nats-device-(.+)") unless on (cn) nats_client_cert_not_after_seconds`.
    It fires for a client that never reported and for one that stopped, and
    it stays active until the series returns or someone deletes the
    `Certificate`.
  - The inventory is every `nats-device-` `Certificate` that exists, ready
    or not. `group by (name)` ignores the sample value and the `condition`
    label, so a certificate still waiting for issuance is already expected
    to report. Monitoring starts when the `Certificate` exists in git.
- The inventory join needs cert-manager's series in `prometheus-ext`, which
  scrapes only hosts today. `prometheus-ext.yaml` gets one more scrape job,
  `cert-manager-nats`, for the cert-manager Service on port 9402, with a
  metric relabel rule that keeps only `certmanager_certificate_.*` series
  for namespace `nats`. The main Prometheus remains the home of the
  cluster-wide cert-manager alerts.
- If that scrape breaks, the inventory is empty and every missing-metrics
  alert clears without a word. Two more rules in the `prometheus: ext`
  group guard it:
  - `NatsClientInventoryScrapeDown`:
    `absent(up{job="cert-manager-nats"} == 1)`, 30 minutes (warning).
  - `NatsClientInventoryMetricsMissing`:
    `count(up{job="cert-manager-nats"} == 1) > 0 unless on() count(certmanager_certificate_ready_status{namespace="nats"}) > 0`,
    30 minutes (warning). The `nats` namespace always holds the server,
    route and admin certificates, so an empty result means a broken relabel
    rule or a renamed metric, not an empty inventory.
- One gap remains: no alert compares the installed certificate with the
  issued one. The expiry alert covers the outcome that matters, and the
  same join could add that comparison later.
- Annotations state what each value is. The two expiry alerts have seconds
  remaining as their value and render it with `humanizeDuration` as the time
  left to replace the certificate. The stale, parse-error, missing-metrics
  and inventory alerts have no expiry value and do not mention a deadline.
- The fixture covers two clients present, a client that never reported, a
  client that reported and then stopped (the alert stays active), a client
  whose certificate is not ready yet (still expected), a decommissioned
  client (no alert), the inventory scrape down, and the scrape up with no
  certificate series.

## Rollout order

1. Namespace and PKI. Wait for all `Certificate`s to be `Ready`; the
   Let's Encrypt DNS-01 issuance takes a few minutes.
2. The Application. Pods will not start before the TLS secrets exist.
3. Alerts.

Landing them in one PR is fine: ArgoCD retries, and the StatefulSet pods
wait in `ContainerCreating` until the secrets appear.

## Verification

Run stream commands from the nats-box `app` context. Clients connect through
`nats.k8s.somemissing.info` in every step.

**Issuance access, before `nats-ca` exists**

1. List every subject bound to a role that grants any of these in
   `cert-manager.io`, in any namespace, from the `ClusterRoleBinding`s and
   `RoleBinding`s, counting wildcard verbs and resources:
   - create on `certificaterequests`;
   - create, update or patch on `certificates`. Update and patch matter
     because changing the subject or issuer of an existing `Certificate`
     makes cert-manager reissue it.

   Spot-check with `kubectl auth can-i --as`. For each non-admin subject
   with the `certificaterequests` permission: stop, the assumption fails.
   For each with a `certificates` permission: also check `get` on Secrets
   and create on Pods, Deployments, StatefulSets, DaemonSets, Jobs and
   CronJobs in that namespace; any of those fails the assumption too.
   cert-manager's own service accounts and ArgoCD's controller count as
   administrators. Record the result in the PR. Do not merge the `nats-ca`
   ClusterIssuer until this passes.

**Cluster health**

2. `nats server list` shows three servers; `nats server report jetstream`
   shows a meta leader.
3. `dig nats.k8s.somemissing.info` returns the Service ClusterIP.
4. The NATS and cert-manager PodMonitor targets are up in Prometheus,
   `certmanager_certificate_ready_status` has series for the NATS
   certificates, and the alert rules load.

**Leader loss**

5. Create a three-replica test stream and a durable consumer. Start a
   publisher that checks each JetStream acknowledgment and a consumer that
   checks sequence numbers for gaps.
6. Find the stream leader with `nats stream info`. Record which workers are
   already cordoned. Cordon the rest from a script that installs an exit
   trap first; the trap uncordons exactly the workers the script cordoned,
   on success, on a failed assertion and on interrupt. Then delete the
   leader pod. With every worker cordoned the replacement cannot schedule,
   whatever the topology spread calculation does. Running pods are not
   affected; new pods anywhere in the cluster wait until the uncordon, so
   keep the window to about ten minutes.
7. Hold the outage for at least five minutes. Throughout that window:
   - the replacement pod stays `Pending`; the test fails if it schedules;
   - a new stream leader exists;
   - publishes keep getting JetStream acknowledgments;
   - the consumer keeps receiving with no sequence gap.
8. The script exits and its trap uncordons the workers it cordoned; check
   with `kubectl get nodes` that no worker gained a cordon from the test.
   Confirm the replica catches up (`nats stream info` shows three
   current replicas).

**Planned disruption**

9. With the publisher and consumer still running, `kubectl drain` a node
   that hosts a NATS pod, then uncordon it. Then run
   `kubectl rollout restart statefulset/nats`. In both cases no acknowledged
   message goes missing and the consumer sees no gap; client reconnects are
   expected. Keep the test stream.

**Client access control**

10. From a LAN host with the `nats-lan-test` certificate: publish and
   subscribe on `lantest.check` (succeeds); publish on another subject
   (permissions violation).
11. Stop the test publisher and consumer. From the `app` context, record
    the stream's message count and last sequence. From the LAN host, run
    `nats stream rm` and `nats stream purge` against the test stream. Each
    must return an authorization error, not a timeout. From the `app`
    context, confirm the stream exists and both recorded values match.
12. Port 4222 from the LAN host with no client certificate, and with a
    certificate from the `k8s` ClusterIssuer: both fail the handshake. Use
    the `nats` CLI here, not raw `openssl s_client`: the client listener
    sends a plaintext INFO line before TLS starts.

**Route mTLS**

The route listener starts TLS before it sends anything, so raw
`openssl s_client` is the right probe on 6222. The probe must come from a
source the network policy allows, or a timeout proves only the policy.

13. Positive control: from the nats-box `default` context,
    `nats server request routes` lists, for each of the three servers, the
    server IDs of both other servers as route peers. Count distinct peers,
    not connections: NATS 2.15 opens a pool of connections to each peer.
14. Start an ephemeral debug container with `openssl` in pod `nats-0`
    (`kubectl debug`), which shares the pod's network identity. From it,
    connect to `nats-1.nats-headless:6222` twice: with no certificate, and
    with the valid `nats-lan-test` client certificate and key. Both
    handshakes must fail, and the `nats-1` log must show a TLS route
    handshake error for each attempt.

**Network policy**

15. Port 6222 and port 8222 on a NATS pod IP and through `nats-headless`,
    from a pod outside the NATS StatefulSet and from the LAN: connection
    timed out. The NATS pods' own probes stay healthy.

**Client certificate metrics**

16. `certmanager_certificate_ready_status{namespace="nats"}` has series in
    `prometheus-ext`, and no other cert-manager series arrived with them. No
    host exports the client metrics yet, so the fixtures are the only test
    of the client rules in this work.
17. The fixtures in `.ci/test/prom-rules/` pass under
    `.ci/validate-prom-rules.sh`. The client certificate fixture uses
    synthetic series for two clients, to show the rules need no per-client
    edits.

**Cleanup and revocation**

18. Delete the test stream and consumer.
19. Remove `nats-lan-test` with the full decommissioning procedure, as its
    first live run: revoke, confirm rejection after all three servers
    reload, then delete the `Certificate` in a second change, then delete
    the `nats-lan-test` Secret and the copied files on the LAN host.

## Risks

| Risk | Mitigation |
|------|------------|
| In-cluster clients use `nats.nats.svc` and fail hostname verification | Documented above; nats-box context uses the public name as the working example |
| Device certificate expires unnoticed | Standard client metrics and generic alerts; the device `Certificate` names are the inventory for the missing-metrics alert |
| Let's Encrypt renewal fails (DNS provider outage) | cert-manager keeps retrying after the renewal time; `CertManagerRenewalOverdue` and `CertManagerCertificateNotReady` report it |
| A values change uses `merge` on a pod or container list and drops mounts | Spec and values comments say to use `patch`; `helm template` check in the plan compares the mount list |
| Config typo in `accounts` blocks a reload | The reloader leaves the running config in place on a failed reload; verify after each user change with `nats server report accounts` |
| iSCSI attach contention with three new volumes | Small, long-lived volumes; attaches happen only on pod reschedule |
