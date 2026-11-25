# HA NATS JetStream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to carry out this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy a three-node NATS JetStream cluster at `nats.k8s.somemissing.info:4222` where every client authenticates with a cert-manager client certificate mapped to a named NATS user.

**Architecture:** The official `nats` Helm chart runs as an ArgoCD `Application` with inline values. A Let's Encrypt certificate serves the client listener; two private cert-manager CAs sign client certificates and route certificates separately. A `NetworkPolicy` limits the route, monitoring and exporter ports. Alerts cover the NATS cluster, cert-manager issuance, and a standard client-certificate metric contract.

**Tech Stack:** Kubernetes 1.37, ArgoCD, Helm chart `nats` 2.15.3 (NATS server 2.15.3, exporter 0.20.3, nats-box 0.20.2), cert-manager v1.21.3, Calico, kube-prometheus-stack, `promtool`, `kubeconform`.

**Spec:** `docs/superpowers/specs/2026-11-25-nats-jetstream-design.md`. Read it before starting; this plan implements it and does not repeat its reasoning.

## Global Constraints

- Chart: `nats` version `2.15.3` from `https://nats-io.github.io/k8s/helm/charts/`.
- Namespace: `nats`. Helm release name: `nats` (so objects are `nats`, `nats-headless`, `nats-box`, pods `nats-0..2`).
- Every client, including pods and nats-box, connects to `nats.k8s.somemissing.info:4222`. Never `nats.nats.svc`.
- Server certificate issuer: ClusterIssuer `cert-manager-webhook-dnsimple-production`.
- Client CA: ClusterIssuer `nats-ca`, root `commonName: nats-client-ca`. Route CA: namespaced Issuer `nats-route-ca` in `nats`, root `commonName: nats-route-ca`.
- A NATS user name is `CN=<certificate commonName>`. Client certificates carry only a `commonName`, no SANs.
- Device `Certificate` names use the prefix `nats-device-`. This work creates none.
- Append to pod and container lists with `podTemplate.patch` and `container.patch` (JSON patch). Never `podTemplate.merge` or `container.merge` on a list: it replaces the list and drops the chart's mounts.
- Workload users get no `$JS.API.>` permission.
- Service annotation key: `external-dns.kubernetes.io/hostname` (GA prefix, not `alpha`).
- PrometheusRule labels: `release: prom` for the main Prometheus, `prometheus: ext` for `prometheus-ext`.
- Stage a new file with `git add <path>` before running any `.ci/validate*.sh` script. The validators list files with `git ls-files` and skip untracked ones.
- A chart-rendered Secret needs the annotation `k8s.somemissing.info/argocd-manage-secret-data: "true"`, or ArgoCD ignores later changes to its data.
- Git: work on branch `nats-jetstream`, stage explicit paths only (no `git add -A` or `git add .`), conventional-commit subjects.
- ArgoCD deploys from `main`. Nothing reaches the cluster until the user merges a PR; do not merge or push to `main` yourself.
- Do not print private keys. Commands that read `tls.key` write it to a file or a pipe, never to the terminal.

## Review Focus

Failure modes the spec implies that are most likely to bite an operator. Each has a check in the task named.

1. A values edit that uses `merge` on a list silently drops the config, data and TLS mounts. Expected: the render check fails. Task 5, Step 3.
2. A pod or nats-box connects with an in-cluster Service name and fails hostname verification against the Let's Encrypt certificate. Expected: a clear TLS error, and the public name works from inside the cluster. Task 8, Step 5.
3. The `NetworkPolicy` blocks kubelet probes on 8222 and the pods never become ready. Expected: all three pods `Ready` with the policy applied. Task 8, Step 3.
4. A certificate renews and the servers keep the old one until restarted. Expected: a forced reissue of the route certificate reloads all three servers with no restart. Task 10, Step 7.
5. ArgoCD shows permanent drift on the chart objects (server-side apply defaults on the StatefulSet or PodMonitor), which hides real changes. Expected: the `nats` Application is `Synced` and `Healthy` ten minutes after rollout. Task 8, Step 4.

## File Structure

| File | Responsibility |
|------|----------------|
| `namespace.nats.yaml` (create) | The `nats` namespace |
| `nats-pki.yaml` (create) | Both CAs, their issuers, and the server, route and client certificates |
| `nats-networkpolicy.yaml` (create) | Ingress policy for the NATS server pods |
| `application.nats.yaml` (create) | ArgoCD Application with the chart values |
| `nats-alerts.yaml` (create) | PrometheusRules `nats-alerts` and `nats-client-cert-alerts-ext` |
| `cert-manager-monitoring.yaml` (create) | cert-manager PodMonitor and PrometheusRule `cert-manager-alerts` |
| `prometheus-ext.yaml` (edit) | One new scrape job, `cert-manager-nats` |
| `.ci/test/prom-rules/nats-alerts.test.yaml` (create) | Fixture for `nats-alerts` |
| `.ci/test/prom-rules/nats-client-cert-alerts.test.yaml` (create) | Fixture for `nats-client-cert-alerts-ext` |
| `.ci/test/prom-rules/cert-manager-alerts.test.yaml` (create) | Fixture for `cert-manager-alerts` |

The root ArgoCD app (`application.vmubtkube-a.yaml`) applies every YAML file at the repo root, so no index needs editing.

Tasks 1 to 7 change only the repository. Tasks 8 to 11 run against the live cluster after the user merges.

---

### Task 1: Branch and issuance preflight

**Files:**
- Commit: `docs/superpowers/specs/2026-11-25-nats-jetstream-design.md`, `docs/superpowers/plans/2026-11-25-nats-jetstream.md`

**Interfaces:**
- Consumes: nothing.
- Produces: branch `nats-jetstream`; a preflight result that later goes in the PR description.

The spec accepts a ClusterIssuer for client certificates on one assumption: only cluster administrators can get a certificate signed by `nats-ca`. This task checks that before any CA exists and changes nothing.

- [ ] **Step 1: Create the branch and commit the spec and plan**

```bash
git switch -c nats-jetstream
git add docs/superpowers/specs/2026-11-25-nats-jetstream-design.md docs/superpowers/plans/2026-11-25-nats-jetstream.md
git commit -m "docs: design and plan an HA NATS JetStream cluster"
```

- [ ] **Step 2: List roles that can create or mutate certificate requests**

```bash
kubectl get clusterrole,role -A -o json | jq -r '
  .items[] | . as $r | .rules[]?
  | select((.apiGroups // []) | any(. == "cert-manager.io" or . == "*"))
  | select((.resources // []) | any(. == "certificates" or . == "certificaterequests" or . == "*"))
  | select((.verbs // []) | any(. == "create" or . == "update" or . == "patch" or . == "*"))
  | "\($r.kind)/\($r.metadata.namespace // "-")/\($r.metadata.name)"' | sort -u > /tmp/nats-issuance-roles.txt
cat /tmp/nats-issuance-roles.txt
```

This matches wildcard groups, resources and verbs. It covers both issuance paths: `certificaterequests` (the requester needs no Secret access) and `certificates` (create, or update/patch of an existing one, which triggers reissuance).

- [ ] **Step 3: List the subjects bound to those roles**

```bash
kubectl get clusterrolebinding,rolebinding -A -o json | jq -r --rawfile roles /tmp/nats-issuance-roles.txt '
  ($roles | split("\n") | map(select(length > 0) | split("/") | {kind: .[0], name: .[2]})) as $R
  | .items[] | . as $b
  | select($R | any(.kind == $b.roleRef.kind and .name == $b.roleRef.name))
  | (.subjects // [])[]
  | "\(.kind):\(.namespace // "-")/\(.name)  via \($b.kind)/\($b.metadata.namespace // "-")/\($b.metadata.name)"' | sort -u
```

Reference result from 2026-11-25, the date of this plan:

```
Group:-/kubeadm:cluster-admins  via ClusterRoleBinding/-/kubeadm:cluster-admins
Group:-/system:masters  via ClusterRoleBinding/-/cluster-admin
ServiceAccount:argocd/argocd-application-controller  via ClusterRoleBinding/-/argocd-application-controller
ServiceAccount:argocd/argocd-server  via ClusterRoleBinding/-/argocd-server
ServiceAccount:calico-system/calico-kube-controllers  via ClusterRoleBinding/-/tmp-calicoctl
ServiceAccount:cert-manager/cert-manager  via ClusterRoleBinding/-/cert-manager-controller-certificates
ServiceAccount:cert-manager/cert-manager  via ClusterRoleBinding/-/cert-manager-controller-ingress-shim
ServiceAccount:kube-system/generic-garbage-collector  via ClusterRoleBinding/-/system:controller:generic-garbage-collector
ServiceAccount:kube-system/storage-version-migrator-controller  via ClusterRoleBinding/-/system:controller:storage-version-migrator-controller
ServiceAccount:operators/metacontroller-metacontroller-helm  via ClusterRoleBinding/-/metacontroller-metacontroller-helm
ServiceAccount:sonobuoy/sonobuoy-serviceaccount  via ClusterRoleBinding/-/sonobuoy-serviceaccount-sonobuoy
```

- [ ] **Step 4: Judge the result**

Pass condition: every subject is a cluster administrator group or a cluster-wide controller service account. The reference result passes: it holds the two admin groups and controller service accounts only, with no human user, no namespace-scoped `RoleBinding`, and no CI identity.

Fail condition: any `User`, any `Group` other than the two above, or any `ServiceAccount` that belongs to an application workload. In particular a `RoleBinding` to the built-in `admin` or `edit` ClusterRole fails, because those roles also grant Secret reads and Pod creation in that namespace.

If it fails, stop and report the subject to the user. Do not continue to Task 3.

Report two leftovers to the user either way. Neither blocks the rollout; both are broad grants with no current use: `ClusterRoleBinding/tmp-calicoctl` and the `sonobuoy` service account binding.

- [ ] **Step 5: Save the output**

Keep the Step 3 output. Task 8 Step 1 puts it in the PR description. No commit in this step.

---

### Task 2: cert-manager scrape and issuance alerts

**Files:**
- Create: `cert-manager-monitoring.yaml`
- Test: `.ci/test/prom-rules/cert-manager-alerts.test.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: series `certmanager_certificate_*` in the main Prometheus with `job="cert-manager/cert-manager"` and the certificate's own namespace in the `namespace` label; PrometheusRule `monitoring/cert-manager-alerts`.

Prometheus does not scrape cert-manager today. These rules cover every `Certificate` in the cluster. On 2026-11-25 no certificate was not-ready or overdue, so the rules load quiet; Step 1 re-checks.

- [ ] **Step 1: Check what the new rules would fire on**

```bash
kubectl get certificate -A -o json | jq -r '.items[]
  | select(((.status.conditions // []) | map(select(.type == "Ready" and .status == "True")) | length) == 0)
  | "NOT READY \(.metadata.namespace)/\(.metadata.name)"'
kubectl get certificate -A -o json | jq -r --argjson now "$(date +%s)" '.items[]
  | select(.status.renewalTime != null)
  | select((.status.renewalTime | fromdateiso8601) < ($now - 86400))
  | "OVERDUE \(.metadata.namespace)/\(.metadata.name) notAfter=\(.status.notAfter)"'
```

Expected: no output. If a certificate appears, tell the user. The alert for that certificate is correct, and they should know before it pages.

- [ ] **Step 2: Write the failing fixture**

Create `.ci/test/prom-rules/cert-manager-alerts.test.yaml`:

```yaml
# Unit tests for cert-manager-monitoring.yaml's PrometheusRule
# "cert-manager-alerts". Run: sh .ci/validate-prom-rules.sh
# The test clock starts at t=0; timestamps are (eval time + offset).
rule_files: [monitoring/cert-manager-alerts.yaml]
evaluation_interval: 1m
tests:
  - name: healthy certificate is quiet
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager/cert-manager"}'
        values: '1+0x200'
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-server",condition="True"}'
        values: '1+0x200'
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-server",condition="False"}'
        values: '0+0x200'
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-server",condition="Unknown"}'
        values: '0+0x200'
      - series: 'certmanager_certificate_renewal_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-server"}'
        values: '871200+0x200' # 2h eval + 10d
      - series: 'certmanager_certificate_expiration_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-server"}'
        values: '3463200+0x200' # 2h eval + 40d
    alert_rule_test:
      - {eval_time: 2h, alertname: CertManagerCertificateNotReady, exp_alerts: []}
      - {eval_time: 2h, alertname: CertManagerRenewalOverdue, exp_alerts: []}
      - {eval_time: 2h, alertname: CertManagerCertificateExpiryCritical, exp_alerts: []}
      - {eval_time: 2h, alertname: CertManagerScrapeDown, exp_alerts: []}
      - {eval_time: 2h, alertname: CertManagerCertificateMetricsMissing, exp_alerts: []}

  - name: Ready=False fires not ready
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-route",condition="False"}'
        values: '1+0x200'
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-route",condition="True"}'
        values: '0+0x200'
    alert_rule_test:
      - eval_time: 2h
        alertname: CertManagerCertificateNotReady
        exp_alerts:
          - exp_labels: {severity: warning, job: cert-manager/cert-manager, namespace: nats, name: nats-route, condition: "False"}
            exp_annotations:
              summary: "Certificate nats/nats-route is not ready (Ready=False)."
              description: "cert-manager has not issued or cannot renew this certificate. Run `kubectl -n nats describe certificate nats-route` and read the newest CertificateRequest and Order events."

  # A Certificate waiting for its first issuance: no Ready condition yet
  # (Unknown=1) and cert-manager exports 0 for both timestamps. Only the
  # readiness rule may fire; 0 must not read as "expired in 1970".
  - name: pending first issuance fires not ready only
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_ready_status{job="cert-manager/cert-manager",namespace="nats",name="nats-new",condition="Unknown"}'
        values: '1+0x2000'
      - series: 'certmanager_certificate_renewal_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-new"}'
        values: '0+0x2000'
      - series: 'certmanager_certificate_expiration_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-new"}'
        values: '0+0x2000'
    alert_rule_test:
      - eval_time: 30h
        alertname: CertManagerCertificateNotReady
        exp_alerts:
          - exp_labels: {severity: warning, job: cert-manager/cert-manager, namespace: nats, name: nats-new, condition: Unknown}
            exp_annotations:
              summary: "Certificate nats/nats-new is not ready (Ready=Unknown)."
              description: "cert-manager has not issued or cannot renew this certificate. Run `kubectl -n nats describe certificate nats-new` and read the newest CertificateRequest and Order events."
      - {eval_time: 30h, alertname: CertManagerRenewalOverdue, exp_alerts: []}
      - {eval_time: 30h, alertname: CertManagerCertificateExpiryCritical, exp_alerts: []}

  - name: renewal overdue by more than a day
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_renewal_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-server"}'
        values: '3600+0x2000' # renewal was due at t=1h
      - series: 'certmanager_certificate_expiration_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-server"}'
        values: '540000+0x2000' # 30h eval + 5d
    alert_rule_test:
      - eval_time: 30h
        alertname: CertManagerRenewalOverdue
        exp_alerts:
          - exp_labels: {severity: warning, job: cert-manager/cert-manager, namespace: nats, name: nats-server}
            exp_annotations:
              summary: "Certificate nats/nats-server renewal is 1d 5h 0m 0s overdue."
              description: "The renewal time passed more than a day ago and cert-manager still serves the old certificate. The deadline is the certificate's notAfter: read it with `kubectl -n nats get certificate nats-server -o jsonpath='{.status.notAfter}'`."
      - {eval_time: 30h, alertname: CertManagerCertificateExpiryCritical, exp_alerts: []}

  - name: under three days to expiry is critical
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_expiration_timestamp_seconds{job="cert-manager/cert-manager",namespace="nats",name="nats-server"}'
        values: '180000+0x200' # 2h eval + 2d
    alert_rule_test:
      - eval_time: 2h
        alertname: CertManagerCertificateExpiryCritical
        exp_alerts:
          - exp_labels: {severity: critical, job: cert-manager/cert-manager, namespace: nats, name: nats-server}
            exp_annotations:
              summary: "Certificate nats/nats-server expires in 2d 0h 0m 0s."
              description: "Less than 3 days of validity remain and renewal has not succeeded. Whatever serves this certificate breaks when it lapses."

  - name: scrape down
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager/cert-manager"}'
        values: '0+0x200'
    alert_rule_test:
      - eval_time: 1h
        alertname: CertManagerScrapeDown
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "Prometheus cannot scrape the cert-manager controller."
              description: "No healthy target for job cert-manager/cert-manager. Certificate alerts cannot fire while this lasts. Check the controller pod and the cert-manager PodMonitor."
      - {eval_time: 1h, alertname: CertManagerCertificateMetricsMissing, exp_alerts: []}

  - name: scrape up with no certificate series
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager/cert-manager"}'
        values: '1+0x200'
    alert_rule_test:
      - {eval_time: 1h, alertname: CertManagerScrapeDown, exp_alerts: []}
      - eval_time: 1h
        alertname: CertManagerCertificateMetricsMissing
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "cert-manager is scraped but exports no certificate series."
              description: "The cert-manager target is up, yet no certmanager_certificate_* series exist. Certificate alerts cannot fire while this lasts. Check for a renamed metric or a relabel rule that drops them."
```

- [ ] **Step 3: Run the fixture to verify it fails**

Run: `sh .ci/validate-prom-rules.sh`
Expected: FAIL. `promtool` cannot open `monitoring/cert-manager-alerts.yaml` because no PrometheusRule with that name exists yet.

- [ ] **Step 4: Write the PodMonitor and the rule**

Create `cert-manager-monitoring.yaml`:

```yaml
# Scrape and alerts for cert-manager. Nothing scraped the controller before
# NATS: its certificates (a Let's Encrypt server certificate and private-CA
# route and client certificates) depend on renewals working, so a failed
# renewal has to alert. The rules cover every Certificate in the cluster.
#
# honorLabels keeps cert-manager's own `namespace` label (the Certificate's
# namespace). Without it Prometheus renames that label to exported_namespace
# and `namespace` becomes "cert-manager" for every series.
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cert-manager
  namespace: cert-manager
  labels:
    release: prom
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cert-manager
      app.kubernetes.io/component: controller
  podMetricsEndpoints:
    - port: http-metrics
      honorLabels: true
---
# cert-manager exports 0 for the renewal and expiry timestamps until a
# certificate has its first issuance; the "> 0" filters keep a pending
# certificate from reading as overdue since 1970. Pending issuance is the
# readiness rule's job (Unknown = no Ready condition yet).
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cert-manager-alerts
  namespace: monitoring
  labels:
    release: prom
spec:
  groups:
    - name: cert-manager
      rules:
        - alert: CertManagerCertificateNotReady
          expr: certmanager_certificate_ready_status{condition=~"False|Unknown"} == 1
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Certificate {{ $labels.namespace }}/{{ $labels.name }} is not ready (Ready={{ $labels.condition }})."
            description: >-
              cert-manager has not issued or cannot renew this certificate.
              Run `kubectl -n {{ $labels.namespace }} describe certificate
              {{ $labels.name }}` and read the newest CertificateRequest and
              Order events.
        - alert: CertManagerRenewalOverdue
          expr: time() - (certmanager_certificate_renewal_timestamp_seconds > 0) > 86400
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "Certificate {{ $labels.namespace }}/{{ $labels.name }} renewal is {{ $value | humanizeDuration }} overdue."
            description: >-
              The renewal time passed more than a day ago and cert-manager
              still serves the old certificate. The deadline is the
              certificate's notAfter: read it with `kubectl -n
              {{ $labels.namespace }} get certificate {{ $labels.name }} -o
              jsonpath='{.status.notAfter}'`.
        - alert: CertManagerCertificateExpiryCritical
          expr: (certmanager_certificate_expiration_timestamp_seconds > 0) - time() < 3 * 86400
          for: 1h
          labels:
            severity: critical
          annotations:
            summary: "Certificate {{ $labels.namespace }}/{{ $labels.name }} expires in {{ $value | humanizeDuration }}."
            description: >-
              Less than 3 days of validity remain and renewal has not
              succeeded. Whatever serves this certificate breaks when it
              lapses.
        - alert: CertManagerScrapeDown
          expr: absent(up{job="cert-manager/cert-manager"} == 1)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "Prometheus cannot scrape the cert-manager controller."
            description: >-
              No healthy target for job cert-manager/cert-manager. Certificate
              alerts cannot fire while this lasts. Check the controller pod and
              the cert-manager PodMonitor.
        - alert: CertManagerCertificateMetricsMissing
          # Name-agnostic on purpose (see rustfs-alerts.yaml): a renamed metric
          # must not hide a scrape that returns nothing useful.
          expr: >-
            (count(up{job="cert-manager/cert-manager"} == 1) > 0)
            unless on() (count({__name__=~"certmanager_certificate_.*"}) > 0)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "cert-manager is scraped but exports no certificate series."
            description: >-
              The cert-manager target is up, yet no certmanager_certificate_*
              series exist. Certificate alerts cannot fire while this lasts.
              Check for a renamed metric or a relabel rule that drops them.
```

- [ ] **Step 5: Run the fixture to verify it passes**

Run: `sh .ci/validate-prom-rules.sh`
Expected: PASS, including the lines `Processing test file: .../cert-manager-alerts.test.yaml` and `SUCCESS`.

- [ ] **Step 6: Check the manifests and selectors**

Run: `sh .ci/validate.sh && sh .ci/validate-prom-selectors.sh`
Expected: both exit 0. The selector check confirms a Prometheus selects the new PodMonitor and PrometheusRule.

- [ ] **Step 7: Commit**

```bash
git add cert-manager-monitoring.yaml .ci/test/prom-rules/cert-manager-alerts.test.yaml
git commit -m "feat(monitoring): scrape cert-manager and alert on failed issuance"
```

---

### Task 3: Namespace and PKI

**Files:**
- Create: `namespace.nats.yaml`, `nats-pki.yaml`

**Interfaces:**
- Consumes: ClusterIssuer `cert-manager-webhook-dnsimple-production` (exists).
- Produces, all in namespace `nats`:
  - Secret `nats-server-tls` (`tls.crt`, `tls.key`): Let's Encrypt certificate for `nats.k8s.somemissing.info`.
  - Secret `nats-route-tls` (`tls.crt`, `tls.key`, `ca.crt` = route CA).
  - Secret `nats-admin-tls` (`tls.crt`, `tls.key`, `ca.crt` = client CA), subject `CN=nats-admin`.
  - Secret `nats-operator-tls`, subject `CN=nats-operator`.
  - Secret `nats-lan-test-tls`, subject `CN=nats-lan-test` (temporary; Task 11 removes it).
  - ClusterIssuer `nats-ca`; Issuer `nats/nats-route-ca`.

- [ ] **Step 1: Confirm Task 1 passed**

Do not write the `nats-ca` ClusterIssuer unless Task 1 Step 4 passed.

- [ ] **Step 2: Write the namespace**

Create `namespace.nats.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: nats
  name: nats
```

- [ ] **Step 3: Write the PKI**

Create `nats-pki.yaml`:

```yaml
# PKI for the NATS cluster (application.nats.yaml).
# Design: docs/superpowers/specs/2026-11-25-nats-jetstream-design.md
#
# Three trust chains, on purpose:
#   server cert  <- Let's Encrypt. Clients verify it with system roots, so
#                   every client must dial nats.k8s.somemissing.info.
#   client certs <- nats-ca (ClusterIssuer). The ONLY CA the client listener
#                   trusts. A NATS user is "CN=<commonName>".
#   route certs  <- nats-route-ca (Issuer, this namespace only). Separate so
#                   a client certificate can never open a server route.
#
# Trust assumption: anyone who can create or patch a Certificate or
# CertificateRequest on nats-ca can become any NATS user, including
# nats-admin. Only cluster admins may hold that permission (checked before
# rollout; re-check before delegating issuance to anyone).
#
# Both roots set an explicit commonName: a self-signed certificate with no
# subject also has an empty issuer DN.
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: nats-ca-selfsigned
  namespace: cert-manager
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: nats-client-ca
  secretName: nats-ca-tls
  duration: 87660h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: nats-ca-selfsigned
    kind: Issuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: nats-ca
spec:
  ca:
    secretName: nats-ca-tls
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: nats-route-ca-selfsigned
  namespace: nats
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-route-ca
  namespace: nats
spec:
  isCA: true
  commonName: nats-route-ca
  secretName: nats-route-ca-tls
  duration: 87660h
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: nats-route-ca-selfsigned
    kind: Issuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: nats-route-ca
  namespace: nats
spec:
  ca:
    secretName: nats-route-ca-tls
---
# Client listener (4222). Let's Encrypt cannot sign in-cluster names, so this
# is the only name any client may use.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-server
  namespace: nats
spec:
  secretName: nats-server-tls
  commonName: &cn nats.k8s.somemissing.info
  dnsNames:
    - *cn
  issuerRef:
    kind: ClusterIssuer
    name: cert-manager-webhook-dnsimple-production
---
# Route listener (6222), server-to-server mTLS. The wildcards cover
# nats-N.nats-headless in every DNS form; the chart dials the FQDN.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-route
  namespace: nats
spec:
  secretName: nats-route-tls
  dnsNames:
    - "*.nats-headless"
    - "*.nats-headless.nats"
    - "*.nats-headless.nats.svc"
    - "*.nats-headless.nats.svc.cluster.local"
  usages:
    - server auth
    - client auth
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: Issuer
    name: nats-route-ca
    group: cert-manager.io
---
# System account user. nats-box context "default". The NATS server pods also
# mount ONLY the ca.crt key of this secret as the client-verification CA.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-admin
  namespace: nats
spec:
  secretName: nats-admin-tls
  commonName: nats-admin
  usages:
    - client auth
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: ClusterIssuer
    name: nats-ca
    group: cert-manager.io
---
# Full access inside the APP account: stream administration and tests.
# nats-box context "app".
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-operator
  namespace: nats
spec:
  secretName: nats-operator-tls
  commonName: nats-operator
  usages:
    - client auth
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: ClusterIssuer
    name: nats-ca
    group: cert-manager.io
---
# TEMPORARY acceptance-test identity, restricted like a device. Removed by
# the decommissioning procedure once the rollout checks pass. Deliberately
# not named nats-device-*: it must stay out of the device alert inventory.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-lan-test
  namespace: nats
spec:
  secretName: nats-lan-test-tls
  commonName: nats-lan-test
  usages:
    - client auth
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    kind: ClusterIssuer
    name: nats-ca
    group: cert-manager.io
```

- [ ] **Step 4: Run the validators**

Run: `sh .ci/validate.sh`
Expected: exit 0.

Run: `kubectl apply --dry-run=server -f namespace.nats.yaml`
Expected: `namespace/nats created (server dry run)`. (The certificates cannot be dry-run before the namespace exists; `kubeconform` covers their schema.)

- [ ] **Step 5: Check the client certificates carry no SANs**

Run: `yq 'select(.kind == "Certificate" and .spec.issuerRef.name == "nats-ca") | [.metadata.name, (.spec | has("dnsNames")), (.spec | has("emailAddresses"))] | join(" ")' nats-pki.yaml`
Expected:

```
nats-admin false false
nats-operator false false
nats-lan-test false false
```

`verify_and_map` matches an email SAN first, then DNS SANs, then the subject. A SAN on a client certificate would change the NATS user name.

- [ ] **Step 6: Commit**

```bash
git add namespace.nats.yaml nats-pki.yaml
git commit -m "feat(nats): add namespace and PKI with separate client and route CAs"
```

---

### Task 4: Network policy

**Files:**
- Create: `nats-networkpolicy.yaml`

**Interfaces:**
- Consumes: pod labels the chart sets on server pods: `app.kubernetes.io/name: nats`, `app.kubernetes.io/component: nats`. nats-box pods have `app.kubernetes.io/component: nats-box` and are not selected.
- Produces: NetworkPolicy `nats/nats`.

- [ ] **Step 1: Write the policy**

Create `nats-networkpolicy.yaml`:

```yaml
# Ingress policy for the NATS server pods (not nats-box).
#
#   4222 clients     anywhere; every client authenticates with a certificate
#   6222 routes      NATS server pods only
#   7777 exporter    Prometheus in monitoring
#   8222 monitoring  nobody. NATS monitoring has no authentication, the pod
#                    listens on its pod IP, and the chart also publishes 8222
#                    on nats-headless. The in-pod exporter uses localhost.
#
# Kubelet probes on 8222 still work: Calico always allows traffic from a node
# to its own pods (same reliance as otel-agent-trace-connector.yaml).
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: nats
  namespace: nats
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: nats
      app.kubernetes.io/component: nats
  policyTypes:
    - Ingress
  ingress:
    - ports:
        - protocol: TCP
          port: 4222
    - from:
        - podSelector:
            matchLabels:
              app.kubernetes.io/name: nats
              app.kubernetes.io/component: nats
      ports:
        - protocol: TCP
          port: 6222
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app.kubernetes.io/name: prometheus
      ports:
        - protocol: TCP
          port: 7777
```

- [ ] **Step 2: Run the validators**

Run: `sh .ci/validate.sh`
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add nats-networkpolicy.yaml
git commit -m "feat(nats): restrict route, exporter and monitoring ports"
```

---

### Task 5: ArgoCD Application

**Files:**
- Create: `application.nats.yaml`

**Interfaces:**
- Consumes: Secrets `nats-server-tls`, `nats-route-tls`, `nats-admin-tls`, `nats-operator-tls` from Task 3.
- Produces: StatefulSet `nats/nats` (3 replicas), Services `nats` (4222) and `nats-headless`, Deployment `nats/nats-box` with contexts `default` (system account) and `app` (APP account), PodMonitor `nats/nats` (scrape job `nats/nats`), PodDisruptionBudget `nats/nats`.

- [ ] **Step 1: Write the Application**

Create `application.nats.yaml`:

```yaml
# HA NATS JetStream. Design:
# docs/superpowers/specs/2026-11-25-nats-jetstream-design.md
# PKI: nats-pki.yaml. Network: nats-networkpolicy.yaml. Alerts: nats-alerts.yaml.
#
# Rules for editing these values:
#  - Clients (pods and nats-box included) dial nats.k8s.somemissing.info. The
#    server certificate is Let's Encrypt and covers no in-cluster name.
#  - Add to pod/container lists with `patch` (JSON patch), never `merge`:
#    merge REPLACES the list and drops the chart's config, data and TLS mounts.
#  - A NATS user is "CN=<certificate commonName>". Adding a client = one
#    Certificate on ClusterIssuer nats-ca + one user entry below.
#  - Workload users get no "$JS.API.>" permission: it allows stream delete
#    and purge across the whole account.
#  - Create streams with --replicas 3; the server does not enforce it.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nats
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  destination:
    server: "https://kubernetes.default.svc"
    namespace: nats
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - PruneLast=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
    retry:
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m0s
      limit: 2
  source:
    chart: nats
    repoURL: https://nats-io.github.io/k8s/helm/charts/
    targetRevision: 2.15.3
    helm:
      releaseName: nats
      valuesObject:
        config:
          cluster:
            enabled: true
            replicas: 3
            routeURLs:
              useFQDN: true
            tls:
              enabled: true
              secretName: nats-route-tls
              merge:
                verify: true
                ca_file: /etc/nats-certs/cluster/ca.crt
          jetstream:
            enabled: true
            fileStore:
              maxSize: 8Gi
              pvc:
                size: 10Gi
                storageClassName: zfs-generic-iscsi-csi
          nats:
            tls:
              enabled: true
              secretName: nats-server-tls
              merge:
                verify_and_map: true
                ca_file: /etc/nats-client-ca/ca.crt
          merge:
            system_account: SYS
            accounts:
              SYS:
                users:
                  - user: CN=nats-admin
              APP:
                jetstream: enabled
                users:
                  - user: CN=nats-operator
                  - user: CN=nats-lan-test
                    permissions:
                      publish: ["lantest.>"]
                      subscribe: ["lantest.>", "_INBOX.>"]
        container:
          env:
            GOMEMLIMIT: 900MiB
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 1Gi
          patch:
            - op: add
              path: /volumeMounts/-
              value:
                name: client-ca
                mountPath: /etc/nats-client-ca
        podTemplate:
          topologySpreadConstraints:
            kubernetes.io/hostname:
              maxSkew: 1
              whenUnsatisfiable: DoNotSchedule
          patch:
            - op: add
              path: /spec/volumes/-
              value:
                name: client-ca
                secret:
                  secretName: nats-admin-tls
                  items:
                    - key: ca.crt
                      path: ca.crt
        promExporter:
          enabled: true
          podMonitor:
            enabled: true
            merge:
              metadata:
                labels:
                  release: prom
        service:
          merge:
            metadata:
              annotations:
                external-dns.kubernetes.io/hostname: nats.k8s.somemissing.info
        natsBox:
          # argocd-cm ignores .data/.stringData on every Secret that lacks
          # this annotation (application.argocd.yaml). Without it the first
          # sync creates the contexts Secret and later edits never apply,
          # while the app still reports Synced.
          contextsSecret:
            merge:
              metadata:
                annotations:
                  k8s.somemissing.info/argocd-manage-secret-data: "true"
          contexts:
            default:
              tls:
                secretName: nats-admin-tls
              merge:
                url: nats://nats.k8s.somemissing.info:4222
            app:
              tls:
                secretName: nats-operator-tls
              merge:
                url: nats://nats.k8s.somemissing.info:4222
```

Notes on the values, for the reviewer:

- `config.nats.tls.merge.ca_file` points at the client CA only. The chart-level `tlsCA` option stays off: it would put one CA in every TLS block and in the nats-box contexts, but the server certificate and the client CA are different chains.
- The `client-ca` volume projects only `ca.crt` from `nats-admin-tls`, so neither the admin key nor a CA signing key enters the server pods.
- `fileStore.maxSize: 8Gi` on a 10Gi volume leaves room for filesystem overhead.
- `GOMEMLIMIT: 900MiB` is about 90% of the 1Gi memory limit.
- `nats-lan-test` is the temporary acceptance identity; Task 11 removes it.

- [ ] **Step 2: Render the chart from the Application**

```bash
yq '.spec.source.helm.valuesObject' application.nats.yaml > /tmp/nats-values.yaml
helm template nats nats --repo https://nats-io.github.io/k8s/helm/charts/ \
  --version 2.15.3 -n nats -f /tmp/nats-values.yaml > /tmp/nats-rendered.yaml
```

Expected: exit 0, no output.

- [ ] **Step 3: Check the mounts survived the patches**

```bash
yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[]
  | [.name, (.volumeMounts // [] | map(.mountPath) | join(","))] | join(" ")' /tmp/nats-rendered.yaml
```

Expected, exactly:

```
nats /etc/nats-config,/var/run/nats,/data,/etc/nats-certs/nats,/etc/nats-certs/cluster,/etc/nats-client-ca
reloader /var/run/nats,/etc/nats-config,/etc/nats-certs/nats,/etc/nats-certs/cluster,/etc/nats-client-ca
prom-exporter
```

If the `nats` line shows only `/etc/nats-client-ca`, a `merge` replaced the list. This is Review Focus item 1.

- [ ] **Step 4: Check the reloader watches the client CA**

```bash
yq 'select(.kind == "StatefulSet") | .spec.template.spec.containers[]
  | select(.name == "reloader") | .args | join(" ")' /tmp/nats-rendered.yaml
```

Expected: the output contains `-config /etc/nats-client-ca/ca.crt` and `-config /etc/nats-certs/cluster/ca.crt`.

- [ ] **Step 5: Check the rendered NATS config**

```bash
yq 'select(.kind == "ConfigMap") | .data."nats.conf"' /tmp/nats-rendered.yaml
```

Expected to contain every line below:

```
"system_account": "SYS"
"verify_and_map": true
"ca_file": "/etc/nats-client-ca/ca.crt"
"ca_file": "/etc/nats-certs/cluster/ca.crt"
"verify": true
"no_advertise": true
"max_file_store": 8Gi
"tls://nats-0.nats-headless.nats.svc.cluster.local:6222"
"user": "CN=nats-admin"
"user": "CN=nats-operator"
"user": "CN=nats-lan-test"
```

and must not contain `$JS.API`.

- [ ] **Step 6: Check Services, contexts, spread and PodMonitor**

```bash
yq 'select(.kind == "Service") | [.metadata.name, (.spec.ports | map(.port) | join(","))] | join(" ")' /tmp/nats-rendered.yaml
yq 'select(.kind == "Service" and .metadata.name == "nats") | .metadata.annotations' /tmp/nats-rendered.yaml
yq 'select(.kind == "Secret" and .metadata.name == "nats-box-contexts") | .stringData | keys | join(",")' /tmp/nats-rendered.yaml
yq 'select(.kind == "StatefulSet") | .spec.template.spec.topologySpreadConstraints[0] | [.topologyKey, .maxSkew, .whenUnsatisfiable] | join(" ")' /tmp/nats-rendered.yaml
yq 'select(.kind == "PodMonitor") | .metadata.labels.release' /tmp/nats-rendered.yaml
yq 'select(.kind == "PodDisruptionBudget") | .spec.maxUnavailable' /tmp/nats-rendered.yaml
```

Expected:

```
nats-headless 4222,6222,8222
nats 4222
external-dns.kubernetes.io/hostname: nats.k8s.somemissing.info
app.json,default.json
kubernetes.io/hostname 1 DoNotSchedule
prom
1
```

- [ ] **Step 7: Run the repository validators**

Run: `sh .ci/validate.sh && sh .ci/validate-helm.sh && sh .ci/validate-prom-selectors.sh`
Expected: all exit 0. `validate-helm.sh` renders the Application the way ArgoCD does and checks the output with `kubeconform`.

- [ ] **Step 8: Commit**

```bash
git add application.nats.yaml
git commit -m "feat(nats): deploy three-node JetStream cluster with client-cert auth"
```

---

### Task 6: NATS alerts

**Files:**
- Create: `nats-alerts.yaml`
- Test: `.ci/test/prom-rules/nats-alerts.test.yaml`

**Interfaces:**
- Consumes: scrape job `nats/nats` from Task 5; exporter 0.20.3 metrics `nats_server_jetstream_disabled`, `nats_server_total_message_bytes`, `nats_server_max_storage` with labels `server_id`, `server_name`, `meta_leader`, `is_meta_leader`.
- Produces: PrometheusRule `monitoring/nats-alerts`. Task 7 appends a second document to the same file.

- [ ] **Step 1: Write the failing fixture**

Create `.ci/test/prom-rules/nats-alerts.test.yaml`:

```yaml
# Unit tests for nats-alerts.yaml's PrometheusRule "nats-alerts".
# Run: sh .ci/validate-prom-rules.sh
rule_files: [monitoring/nats-alerts.yaml]
evaluation_interval: 1m
tests:
  - name: three healthy servers with one leader are quiet
    interval: 1m
    input_series:
      - series: 'up{job="nats/nats",pod="nats-0"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-1"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-2"}'
        values: '1+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="nats-0",is_meta_leader="true"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="nats-0",is_meta_leader="false"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-2",server_id="S2",server_name="nats-2",meta_leader="nats-0",is_meta_leader="false"}'
        values: '0+0x60'
      - series: 'nats_server_total_message_bytes{job="nats/nats",pod="nats-0",server_name="nats-0"}'
        values: '1000000000+0x60'
      - series: 'nats_server_max_storage{job="nats/nats",pod="nats-0",server_name="nats-0"}'
        values: '8589934592+0x60'
    alert_rule_test:
      - {eval_time: 45m, alertname: NatsTelemetryMissing, exp_alerts: []}
      - {eval_time: 45m, alertname: NatsServerNotReporting, exp_alerts: []}
      - {eval_time: 45m, alertname: NatsJetStreamDisabled, exp_alerts: []}
      - {eval_time: 45m, alertname: NatsJetStreamMetaLeader, exp_alerts: []}
      - {eval_time: 45m, alertname: NatsJetStreamStorageHigh, exp_alerts: []}

  # No target discovered at all: count() of nothing is empty, so the rule
  # relies on "or vector(0)" to alert.
  - name: zero discovered targets raises telemetry missing only
    interval: 1m
    input_series:
      - series: 'up{job="other"}'
        values: '1+0x60'
    alert_rule_test:
      - eval_time: 15m
        alertname: NatsTelemetryMissing
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "0 of 3 NATS exporter targets are up."
              description: "Prometheus scrapes fewer than three healthy NATS exporter targets for job nats/nats. A pod is down, the exporter sidecar is failing, or the PodMonitor found no targets. Check the pods in namespace nats."
      - {eval_time: 15m, alertname: NatsServerNotReporting, exp_alerts: []}
      - {eval_time: 15m, alertname: NatsJetStreamMetaLeader, exp_alerts: []}

  - name: one target down raises telemetry missing
    interval: 1m
    input_series:
      - series: 'up{job="nats/nats",pod="nats-0"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-1"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-2"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="nats-0",is_meta_leader="true"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="nats-0",is_meta_leader="false"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 15m
        alertname: NatsTelemetryMissing
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "2 of 3 NATS exporter targets are up."
              description: "Prometheus scrapes fewer than three healthy NATS exporter targets for job nats/nats. A pod is down, the exporter sidecar is failing, or the PodMonitor found no targets. Check the pods in namespace nats."
      - {eval_time: 15m, alertname: NatsServerNotReporting, exp_alerts: []}
      - {eval_time: 15m, alertname: NatsJetStreamMetaLeader, exp_alerts: []}

  - name: exporter up without server series raises server not reporting
    interval: 1m
    input_series:
      - series: 'up{job="nats/nats",pod="nats-0"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-1"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-2"}'
        values: '1+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="nats-0",is_meta_leader="true"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="nats-0",is_meta_leader="false"}'
        values: '0+0x60'
    alert_rule_test:
      - {eval_time: 15m, alertname: NatsTelemetryMissing, exp_alerts: []}
      - eval_time: 15m
        alertname: NatsServerNotReporting
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "Only 2 NATS servers report JetStream data."
              description: "An exporter target is up but its NATS server returns no JetStream data on the monitoring port. Check the nats container in each pod."

  - name: no leader with healthy scrapes raises the leader alert only
    interval: 1m
    input_series:
      - series: 'up{job="nats/nats",pod="nats-0"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-1"}'
        values: '1+0x60'
      - series: 'up{job="nats/nats",pod="nats-2"}'
        values: '1+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="",is_meta_leader="false"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="",is_meta_leader="false"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-2",server_id="S2",server_name="nats-2",meta_leader="",is_meta_leader="false"}'
        values: '0+0x60'
    alert_rule_test:
      - {eval_time: 15m, alertname: NatsTelemetryMissing, exp_alerts: []}
      - {eval_time: 15m, alertname: NatsServerNotReporting, exp_alerts: []}
      - eval_time: 15m
        alertname: NatsJetStreamMetaLeader
        exp_alerts:
          - exp_labels: {severity: critical}
            exp_annotations:
              summary: "0 NATS servers claim the JetStream meta leader role; expected 1."
              description: "JetStream telemetry is present, but the number of servers that report themselves as meta leader is not one. Zero means the cluster has no quorum; stream and consumer changes fail."

  - name: two leaders raise the leader alert
    interval: 1m
    input_series:
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="nats-0",is_meta_leader="true"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="nats-1",is_meta_leader="true"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 15m
        alertname: NatsJetStreamMetaLeader
        exp_alerts:
          - exp_labels: {severity: critical}
            exp_annotations:
              summary: "2 NATS servers claim the JetStream meta leader role; expected 1."
              description: "JetStream telemetry is present, but the number of servers that report themselves as meta leader is not one. Zero means the cluster has no quorum; stream and consumer changes fail."

  # The exporter sets is_meta_leader="true" with an empty meta_leader when a
  # server reports no meta group. That server must not count as a leader.
  - name: server with no meta group beside a real leader is quiet
    interval: 1m
    input_series:
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="nats-0",is_meta_leader="true"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-2",server_id="S2",server_name="nats-2",meta_leader="",is_meta_leader="true"}'
        values: '0+0x60'
    alert_rule_test:
      - {eval_time: 15m, alertname: NatsJetStreamMetaLeader, exp_alerts: []}

  - name: server with no meta group does not mask a leader outage
    interval: 1m
    input_series:
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-0",server_id="S0",server_name="nats-0",meta_leader="",is_meta_leader="false"}'
        values: '0+0x60'
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-2",server_id="S2",server_name="nats-2",meta_leader="",is_meta_leader="true"}'
        values: '0+0x60'
    alert_rule_test:
      - eval_time: 15m
        alertname: NatsJetStreamMetaLeader
        exp_alerts:
          - exp_labels: {severity: critical}
            exp_annotations:
              summary: "0 NATS servers claim the JetStream meta leader role; expected 1."
              description: "JetStream telemetry is present, but the number of servers that report themselves as meta leader is not one. Zero means the cluster has no quorum; stream and consumer changes fail."

  - name: jetstream disabled on one server
    interval: 1m
    input_series:
      - series: 'nats_server_jetstream_disabled{job="nats/nats",pod="nats-1",server_id="S1",server_name="nats-1",meta_leader="",is_meta_leader="true"}'
        values: '1+0x60'
    alert_rule_test:
      - eval_time: 15m
        alertname: NatsJetStreamDisabled
        exp_alerts:
          - exp_labels: {severity: critical, job: nats/nats, pod: nats-1, server_id: S1, server_name: nats-1, is_meta_leader: "true"}
            exp_annotations:
              summary: "JetStream is disabled on NATS server nats-1."
              description: "The server runs without JetStream, usually because the store directory is unusable. Check the pod log and its data volume."

  - name: storage above 80 percent of the store limit
    interval: 1m
    input_series:
      - series: 'nats_server_total_message_bytes{job="nats/nats",pod="nats-0",server_name="nats-0"}'
        values: '7301444403+0x60' # 85% of 8Gi
      - series: 'nats_server_max_storage{job="nats/nats",pod="nats-0",server_name="nats-0"}'
        values: '8589934592+0x60'
    alert_rule_test:
      - eval_time: 45m
        alertname: NatsJetStreamStorageHigh
        exp_alerts:
          - exp_labels: {severity: warning, job: nats/nats, pod: nats-0, server_name: nats-0}
            exp_annotations:
              summary: "JetStream message bytes exceed 80% of the configured store limit on nats-0."
              description: "Message bytes are at 85% of the JetStream file store limit (max_file_store). This is the JetStream limit, not the filesystem; KubePersistentVolumeFillingUp covers the volume."
```

- [ ] **Step 2: Run the fixture to verify it fails**

Run: `sh .ci/validate-prom-rules.sh`
Expected: FAIL. `promtool` cannot open `monitoring/nats-alerts.yaml`.

- [ ] **Step 3: Write the rule**

Create `nats-alerts.yaml`:

```yaml
# Alerts for the NATS JetStream cluster (application.nats.yaml).
#
# Every expression is scoped to job="nats/nats" (the chart's PodMonitor).
# "or vector(0)" turns "no series" into 0 so zero discovered targets alerts
# instead of evaluating to nothing.
#
# Telemetry vs servers vs leader are separate alerts:
#   NatsTelemetryMissing     scrapes are failing or no target was discovered
#   NatsServerNotReporting   exporter answers, its NATS server does not
#   NatsJetStreamMetaLeader  telemetry is fine, leader count is not 1
#
# A server counts as meta leader only with is_meta_leader="true", a non-empty
# meta_leader and JetStream enabled: exporter 0.20.3 also sets
# is_meta_leader="true" (with meta_leader empty) on a server that reports no
# meta group at all.
#
# NatsJetStreamStorageHigh is about the JetStream store limit
# (max_file_store), not the filesystem; KubePersistentVolumeFillingUp covers
# the volume.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: nats-alerts
  namespace: monitoring
  labels:
    release: prom
spec:
  groups:
    - name: nats
      rules:
        - alert: NatsTelemetryMissing
          expr: (count(up{job="nats/nats"} == 1) or vector(0)) < 3
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "{{ $value }} of 3 NATS exporter targets are up."
            description: >-
              Prometheus scrapes fewer than three healthy NATS exporter targets
              for job nats/nats. A pod is down, the exporter sidecar is failing,
              or the PodMonitor found no targets. Check the pods in namespace nats.
        - alert: NatsServerNotReporting
          expr: >-
            (count(count by (server_id) (nats_server_jetstream_disabled{job="nats/nats"})) or vector(0))
            < (count(up{job="nats/nats"} == 1) or vector(0))
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Only {{ $value }} NATS servers report JetStream data."
            description: >-
              An exporter target is up but its NATS server returns no JetStream
              data on the monitoring port. Check the nats container in each pod.
        - alert: NatsJetStreamDisabled
          expr: nats_server_jetstream_disabled{job="nats/nats"} == 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "JetStream is disabled on NATS server {{ $labels.server_name }}."
            description: >-
              The server runs without JetStream, usually because the store
              directory is unusable. Check the pod log and its data volume.
        - alert: NatsJetStreamMetaLeader
          expr: >-
            ((count(nats_server_jetstream_disabled{job="nats/nats",is_meta_leader="true",meta_leader!=""} == 0) or vector(0)) != 1)
            and on() (count(nats_server_jetstream_disabled{job="nats/nats"}) >= 1)
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "{{ $value }} NATS servers claim the JetStream meta leader role; expected 1."
            description: >-
              JetStream telemetry is present, but the number of servers that
              report themselves as meta leader is not one. Zero means the
              cluster has no quorum; stream and consumer changes fail.
        - alert: NatsJetStreamStorageHigh
          expr: >-
            nats_server_total_message_bytes{job="nats/nats"}
            / (nats_server_max_storage{job="nats/nats"} > 0) > 0.8
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "JetStream message bytes exceed 80% of the configured store limit on {{ $labels.server_name }}."
            description: >-
              Message bytes are at {{ $value | humanizePercentage }} of the
              JetStream file store limit (max_file_store). This is the JetStream
              limit, not the filesystem; KubePersistentVolumeFillingUp covers
              the volume.
```

- [ ] **Step 4: Run the fixture to verify it passes**

Run: `sh .ci/validate-prom-rules.sh`
Expected: PASS for `nats-alerts.test.yaml` (ten test groups).

- [ ] **Step 5: Check the selectors**

Run: `sh .ci/validate.sh && sh .ci/validate-prom-selectors.sh`
Expected: both exit 0.

- [ ] **Step 6: Commit**

```bash
git add nats-alerts.yaml .ci/test/prom-rules/nats-alerts.test.yaml
git commit -m "feat(nats): alert on missing telemetry, leader loss and store usage"
```

---

### Task 7: Client certificate alerts and device inventory scrape

**Files:**
- Edit: `nats-alerts.yaml` (append a second document)
- Edit: `prometheus-ext.yaml` (one scrape job in the `prometheus-ext-scrape-configs` Secret)
- Test: `.ci/test/prom-rules/nats-client-cert-alerts.test.yaml`

**Interfaces:**
- Consumes: the client certificate metric contract from the spec (`nats_client_cert_not_after_seconds{cn,file}`, `nats_client_cert_not_before_seconds{cn,file}`, `nats_client_cert_exporter_last_run_timestamp_seconds`, `nats_client_cert_exporter_errors`), exported by LAN hosts to `prometheus-ext`. No host exports them yet.
- Produces: PrometheusRule `monitoring/nats-client-cert-alerts-ext`; scrape job `cert-manager-nats` in `prometheus-ext` carrying `certmanager_certificate_*` series for namespace `nats` only.

The rules name no host and no client. The inventory of expected device clients is every `Certificate` named `nats-device-<cn>` in namespace `nats`, read from cert-manager's metrics, which is why `prometheus-ext` needs this one scrape job.

- [ ] **Step 1: Write the failing fixture**

Create `.ci/test/prom-rules/nats-client-cert-alerts.test.yaml`:

```yaml
# Unit tests for nats-alerts.yaml's PrometheusRule
# "nats-client-cert-alerts-ext". Run: sh .ci/validate-prom-rules.sh
# Two synthetic clients (dev-a, dev-b) show that no rule names a client.
# The test clock starts at t=0; not_after values are (eval time + time left).
rule_files: [monitoring/nats-client-cert-alerts-ext.yaml]
evaluation_interval: 1m
tests:
  - name: two healthy clients are quiet
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager-nats"}'
        values: '1+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-a",condition="True"}'
        values: '1+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-b",condition="True"}'
        values: '1+0x300'
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h1:9100",cn="dev-a",file="/etc/nats/client.crt"}'
        values: '3466800+0x300' # 3h eval + 40d
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h2:9100",cn="dev-b",file="/opt/app/nats.crt"}'
        values: '3466800+0x300'
      - series: 'nats_client_cert_exporter_last_run_timestamp_seconds{job="node-exporter",instance="h1:9100"}'
        values: '0+60x300' # runs every minute
      - series: 'nats_client_cert_exporter_errors{job="node-exporter",instance="h1:9100"}'
        values: '0+0x300'
    alert_rule_test:
      - {eval_time: 3h, alertname: NatsClientCertExpiry, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientCertExpiryCritical, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientCertExporterStale, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientCertExporterParseErrors, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientCertMetricsMissing, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientInventoryScrapeDown, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientInventoryMetricsMissing, exp_alerts: []}

  - name: expiry thresholds apply to every client
    interval: 1m
    input_series:
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h1:9100",cn="dev-a",file="/etc/nats/client.crt"}'
        values: '1735200+0x300' # 2h eval + 20d
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h2:9100",cn="dev-b",file="/opt/app/nats.crt"}'
        values: '439200+0x300' # 2h eval + 5d
    alert_rule_test:
      - eval_time: 2h
        alertname: NatsClientCertExpiry
        exp_alerts:
          - exp_labels: {severity: warning, job: node-exporter, instance: h1:9100, cn: dev-a, file: /etc/nats/client.crt}
            exp_annotations:
              summary: "NATS client certificate dev-a on h1:9100 expires in 20d 0h 0m 0s."
              description: "The certificate installed at /etc/nats/client.crt for NATS user CN=dev-a has less than 21 days left. cert-manager renewed the Secret in namespace nats 30 days before expiry; copy tls.crt and tls.key from it to the host before the time above runs out."
          - exp_labels: {severity: warning, job: node-exporter, instance: h2:9100, cn: dev-b, file: /opt/app/nats.crt}
            exp_annotations:
              summary: "NATS client certificate dev-b on h2:9100 expires in 5d 0h 0m 0s."
              description: "The certificate installed at /opt/app/nats.crt for NATS user CN=dev-b has less than 21 days left. cert-manager renewed the Secret in namespace nats 30 days before expiry; copy tls.crt and tls.key from it to the host before the time above runs out."
      - eval_time: 2h
        alertname: NatsClientCertExpiryCritical
        exp_alerts:
          - exp_labels: {severity: critical, job: node-exporter, instance: h2:9100, cn: dev-b, file: /opt/app/nats.crt}
            exp_annotations:
              summary: "NATS client certificate dev-b on h2:9100 expires in 5d 0h 0m 0s."
              description: "The certificate installed at /opt/app/nats.crt for NATS user CN=dev-b has less than 7 days left; the client loses its NATS connection when it lapses. Copy tls.crt and tls.key from the Secret in namespace nats to the host now."

  # dev-a reports. dev-c never reported. dev-d is not issued yet
  # (condition="True" has value 0) and is still expected.
  - name: client that never reported and client not yet issued are both missing
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-a",condition="True"}'
        values: '1+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-c",condition="True"}'
        values: '1+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-d",condition="True"}'
        values: '0+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-d",condition="Unknown"}'
        values: '1+0x300'
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h1:9100",cn="dev-a",file="/etc/nats/client.crt"}'
        values: '3466800+0x300'
    alert_rule_test:
      - eval_time: 3h
        alertname: NatsClientCertMetricsMissing
        exp_alerts:
          - exp_labels: {severity: warning, name: nats-device-dev-c, cn: dev-c}
            exp_annotations:
              summary: "NATS device client dev-c exports no certificate metrics."
              description: "Certificate nats-device-dev-c exists in namespace nats, but no host exports nats_client_cert_not_after_seconds with cn=\"dev-c\". Install or repair the exporter on the device, or decommission the client (revoke the NATS user first, then delete the Certificate)."
          - exp_labels: {severity: warning, name: nats-device-dev-d, cn: dev-d}
            exp_annotations:
              summary: "NATS device client dev-d exports no certificate metrics."
              description: "Certificate nats-device-dev-d exists in namespace nats, but no host exports nats_client_cert_not_after_seconds with cn=\"dev-d\". Install or repair the exporter on the device, or decommission the client (revoke the NATS user first, then delete the Certificate)."

  # The device reports for an hour, then stops. The alert must still be
  # active a day later (an "offset 1d" comparison would have cleared).
  - name: client that stopped reporting stays missing
    interval: 1m
    input_series:
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-device-dev-a",condition="True"}'
        values: '1+0x3000'
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h1:9100",cn="dev-a",file="/etc/nats/client.crt"}'
        values: '9999999+0x60 stale'
    alert_rule_test:
      - {eval_time: 30m, alertname: NatsClientCertMetricsMissing, exp_alerts: []}
      - eval_time: 4h
        alertname: NatsClientCertMetricsMissing
        exp_alerts: &dev_a_missing
          - exp_labels: {severity: warning, name: nats-device-dev-a, cn: dev-a}
            exp_annotations:
              summary: "NATS device client dev-a exports no certificate metrics."
              description: "Certificate nats-device-dev-a exists in namespace nats, but no host exports nats_client_cert_not_after_seconds with cn=\"dev-a\". Install or repair the exporter on the device, or decommission the client (revoke the NATS user first, then delete the Certificate)."
      - eval_time: 40h
        alertname: NatsClientCertMetricsMissing
        exp_alerts: *dev_a_missing

  # No Certificate in the inventory: a host that still exports metrics for a
  # decommissioned client raises nothing.
  - name: decommissioned client is quiet
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager-nats"}'
        values: '1+0x300'
      - series: 'certmanager_certificate_ready_status{job="cert-manager-nats",namespace="nats",name="nats-server",condition="True"}'
        values: '1+0x300'
      - series: 'nats_client_cert_not_after_seconds{job="node-exporter",instance="h1:9100",cn="dev-a",file="/etc/nats/client.crt"}'
        values: '3466800+0x300'
    alert_rule_test:
      - {eval_time: 3h, alertname: NatsClientCertMetricsMissing, exp_alerts: []}
      - {eval_time: 3h, alertname: NatsClientInventoryMetricsMissing, exp_alerts: []}

  - name: inventory scrape down
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager-nats"}'
        values: '0+0x300'
    alert_rule_test:
      - eval_time: 1h
        alertname: NatsClientInventoryScrapeDown
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "prometheus-ext cannot scrape cert-manager for the NATS device inventory."
              description: "No healthy target for job cert-manager-nats. The device inventory is empty, so NatsClientCertMetricsMissing cannot fire for any device while this lasts."
      - {eval_time: 1h, alertname: NatsClientInventoryMetricsMissing, exp_alerts: []}

  - name: inventory scrape up with no certificate series
    interval: 1m
    input_series:
      - series: 'up{job="cert-manager-nats"}'
        values: '1+0x300'
    alert_rule_test:
      - {eval_time: 1h, alertname: NatsClientInventoryScrapeDown, exp_alerts: []}
      - eval_time: 1h
        alertname: NatsClientInventoryMetricsMissing
        exp_alerts:
          - exp_labels: {severity: warning}
            exp_annotations:
              summary: "The NATS device inventory scrape returns no certificate series."
              description: "Job cert-manager-nats is up, but no certmanager_certificate_ready_status series for namespace nats arrive. That namespace always holds certificates, so the relabel rule or the metric name is wrong. NatsClientCertMetricsMissing cannot fire while this lasts."

  - name: stale exporter and parse errors
    interval: 1m
    input_series:
      - series: 'nats_client_cert_exporter_last_run_timestamp_seconds{job="node-exporter",instance="h1:9100"}'
        values: '0+0x400' # ran once at t=0, never again
      - series: 'nats_client_cert_exporter_errors{job="node-exporter",instance="h1:9100"}'
        values: '2+0x400'
    alert_rule_test:
      - eval_time: 5h
        alertname: NatsClientCertExporterStale
        exp_alerts:
          - exp_labels: {severity: warning, job: node-exporter, instance: h1:9100}
            exp_annotations:
              summary: "NATS client certificate exporter on h1:9100 last ran 5h 0m 0s ago."
              description: "The exporter must run at least hourly. Its metrics are frozen, so the expiry alerts for this host are not trustworthy. Check the cron job on the host."
      - eval_time: 5h
        alertname: NatsClientCertExporterParseErrors
        exp_alerts:
          - exp_labels: {severity: warning, job: node-exporter, instance: h1:9100}
            exp_annotations:
              summary: "NATS client certificate exporter on h1:9100 failed to parse 2 file(s)."
              description: "A certificate file is unreadable or not valid PEM, so it exports no expiry series. Run the exporter by hand on the host to see which file."
```

- [ ] **Step 2: Run the fixture to verify it fails**

Run: `sh .ci/validate-prom-rules.sh`
Expected: FAIL. `promtool` cannot open `monitoring/nats-client-cert-alerts-ext.yaml`.

- [ ] **Step 3: Append the rule**

Append to the end of `nats-alerts.yaml`:

```yaml
---
# Client certificate alerts, evaluated by prometheus-ext (hosts outside
# Kubernetes). Built only on the client certificate metric contract in the
# design doc, so one rule set covers every client; no rule names a host.
#
# Identity is the `cn` label alone (= certificate commonName = NATS user
# without "CN="). `file` is informational.
#
# The two expiry alerts carry seconds remaining as their value. The other
# alerts have no expiry value and state no deadline.
#
# Inventory for NatsClientCertMetricsMissing: every Certificate named
# nats-device-<cn> in namespace nats, from the cert-manager-nats scrape job
# in prometheus-ext.yaml. If that scrape breaks, the inventory is empty and
# the missing-metrics alert goes quiet; the two NatsClientInventory* alerts
# guard that.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: nats-client-cert-alerts-ext
  namespace: monitoring
  labels:
    prometheus: ext
spec:
  groups:
    - name: nats-client-certs
      rules:
        - alert: NatsClientCertExpiry
          expr: nats_client_cert_not_after_seconds - time() < 21 * 86400
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "NATS client certificate {{ $labels.cn }} on {{ $labels.instance }} expires in {{ $value | humanizeDuration }}."
            description: >-
              The certificate installed at {{ $labels.file }} for NATS user
              CN={{ $labels.cn }} has less than 21 days left. cert-manager
              renewed the Secret in namespace nats 30 days before expiry; copy
              tls.crt and tls.key from it to the host before the time above
              runs out.
        - alert: NatsClientCertExpiryCritical
          expr: nats_client_cert_not_after_seconds - time() < 7 * 86400
          for: 1h
          labels:
            severity: critical
          annotations:
            summary: "NATS client certificate {{ $labels.cn }} on {{ $labels.instance }} expires in {{ $value | humanizeDuration }}."
            description: >-
              The certificate installed at {{ $labels.file }} for NATS user
              CN={{ $labels.cn }} has less than 7 days left; the client loses
              its NATS connection when it lapses. Copy tls.crt and tls.key from
              the Secret in namespace nats to the host now.
        - alert: NatsClientCertExporterStale
          expr: time() - nats_client_cert_exporter_last_run_timestamp_seconds > 3 * 3600
          for: 1h
          labels:
            severity: warning
          annotations:
            summary: "NATS client certificate exporter on {{ $labels.instance }} last ran {{ $value | humanizeDuration }} ago."
            description: >-
              The exporter must run at least hourly. Its metrics are frozen, so
              the expiry alerts for this host are not trustworthy. Check the
              cron job on the host.
        - alert: NatsClientCertExporterParseErrors
          expr: nats_client_cert_exporter_errors > 0
          for: 2h
          labels:
            severity: warning
          annotations:
            summary: "NATS client certificate exporter on {{ $labels.instance }} failed to parse {{ $value }} file(s)."
            description: >-
              A certificate file is unreadable or not valid PEM, so it exports
              no expiry series. Run the exporter by hand on the host to see
              which file.
        - alert: NatsClientCertMetricsMissing
          # Inventory = every Certificate named nats-device-<cn> in namespace
          # nats, ready or not ("group by (name)" ignores value and condition).
          expr: >-
            label_replace(
              group by (name) (certmanager_certificate_ready_status{namespace="nats",name=~"nats-device-.+"}),
              "cn", "$1", "name", "nats-device-(.+)"
            )
            unless on (cn) nats_client_cert_not_after_seconds
          for: 2h
          labels:
            severity: warning
          annotations:
            summary: "NATS device client {{ $labels.cn }} exports no certificate metrics."
            description: >-
              Certificate {{ $labels.name }} exists in namespace nats, but no
              host exports nats_client_cert_not_after_seconds with
              cn="{{ $labels.cn }}". Install or repair the exporter on the
              device, or decommission the client (revoke the NATS user first,
              then delete the Certificate).
        - alert: NatsClientInventoryScrapeDown
          expr: absent(up{job="cert-manager-nats"} == 1)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "prometheus-ext cannot scrape cert-manager for the NATS device inventory."
            description: >-
              No healthy target for job cert-manager-nats. The device inventory
              is empty, so NatsClientCertMetricsMissing cannot fire for any
              device while this lasts.
        - alert: NatsClientInventoryMetricsMissing
          expr: >-
            (count(up{job="cert-manager-nats"} == 1) > 0)
            unless on() (count(certmanager_certificate_ready_status{namespace="nats"}) > 0)
          for: 30m
          labels:
            severity: warning
          annotations:
            summary: "The NATS device inventory scrape returns no certificate series."
            description: >-
              Job cert-manager-nats is up, but no
              certmanager_certificate_ready_status series for namespace nats
              arrive. That namespace always holds certificates, so the relabel
              rule or the metric name is wrong. NatsClientCertMetricsMissing
              cannot fire while this lasts.
```

- [ ] **Step 4: Run the fixture to verify it passes**

Run: `sh .ci/validate-prom-rules.sh`
Expected: PASS for all three new fixtures.

- [ ] **Step 5: Add the inventory scrape job**

In `prometheus-ext.yaml`, find the Secret `prometheus-ext-scrape-configs`. Inside `stringData."scrape-configs.yaml"`, insert this block immediately before the line `    - job_name: node-exporter`, keeping the four-space indent of the neighbouring jobs:

```yaml
    # Device inventory for nats-alerts.yaml (NatsClientCertMetricsMissing):
    # prometheus-ext evaluates the client certificate rules but otherwise
    # scrapes only hosts, so it needs cert-manager's view of the nats
    # namespace to know which device clients should be reporting. The
    # relabel rule keeps only certificate series for namespace nats; the
    # cluster-wide cert-manager alerts stay with the main Prometheus
    # (cert-manager-monitoring.yaml). A static target has no `namespace`
    # target label, so cert-manager's own `namespace` label survives.
    - job_name: cert-manager-nats
      scrape_interval: 60s
      static_configs:
      - targets:
        - cert-manager.cert-manager.svc.cluster.local.:9402
      metric_relabel_configs:
      - source_labels: [__name__, namespace]
        regex: certmanager_certificate_.*;nats
        action: keep
```

- [ ] **Step 6: Check the scrape config still parses**

```bash
yq 'select(.kind == "Secret" and .metadata.name == "prometheus-ext-scrape-configs") | .stringData."scrape-configs.yaml"' prometheus-ext.yaml \
  | yq '.[] | select(.job_name == "cert-manager-nats") | .metric_relabel_configs[0].regex'
```

Expected: `certmanager_certificate_.*;nats`

Confirm the Service and port exist:

Run: `kubectl -n cert-manager get svc cert-manager -o jsonpath='{.spec.ports[*].port}{"\n"}'`
Expected: `9402`

- [ ] **Step 7: Run the validators**

Run: `sh .ci/validate.sh && sh .ci/validate-prom-selectors.sh && sh .ci/validate-prom-rules.sh`
Expected: all exit 0.

- [ ] **Step 8: Commit**

```bash
git add nats-alerts.yaml prometheus-ext.yaml .ci/test/prom-rules/nats-client-cert-alerts.test.yaml
git commit -m "feat(nats): add generic client certificate alerts and device inventory"
```

---

### Task 8: Rollout and cluster health

**Files:** none.

**Interfaces:**
- Consumes: the branch from Tasks 1 to 7.
- Produces: a running cluster; shell helpers used by Tasks 9 to 11.

Verification steps 2 to 4 of the spec.

- [ ] **Step 1: Open the PR and wait for the user to merge**

Push the branch and open a PR with `gh pr create`. Put the Task 1 Step 3 output in the description under a heading "Issuance preflight". Then stop: ask the user to review and merge. Do not merge it yourself.

All files can land in one PR. ArgoCD retries, and the StatefulSet pods wait in `ContainerCreating` until the TLS secrets exist.

- [ ] **Step 2: Wait for the certificates**

```bash
kubectl -n cert-manager wait certificate/nats-ca --for=condition=Ready --timeout=5m
kubectl -n nats wait certificate --all --for=condition=Ready --timeout=15m
kubectl -n nats get certificate
```

Expected: `nats-admin`, `nats-lan-test`, `nats-operator`, `nats-route`, `nats-route-ca` and `nats-server` all `READY True`. `nats-server` uses DNS-01 and can take up to ten minutes.

Check the CA subjects:

```bash
kubectl -n cert-manager get secret nats-ca-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
kubectl -n nats get secret nats-route-ca-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
```

Expected: `subject=CN=nats-client-ca` with a matching issuer, then `subject=CN=nats-route-ca` with a matching issuer.

- [ ] **Step 3: Wait for the pods (Review Focus 3)**

```bash
kubectl -n nats rollout status statefulset/nats --timeout=10m
kubectl -n nats get pods -o wide
```

Expected: `nats-0`, `nats-1`, `nats-2` are `3/3 Running` on three different worker nodes, and `nats-box-*` is `1/1 Running`. Three ready pods with the NetworkPolicy in place shows the kubelet probes reach port 8222.

If a pod stays not-ready with probe timeouts in `kubectl -n nats describe pod nats-0`, the assumption about Calico and node-to-pod traffic is wrong. Stop and report; do not open 8222 in the policy without the user's decision.

- [ ] **Step 4: Check ArgoCD (Review Focus 5)**

Wait ten minutes after the pods are ready, then:

Run: `kubectl -n argocd get application nats -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'`
Expected: `Synced Healthy`

If it reports `OutOfSync`, run `kubectl -n argocd get application nats -o json | jq '.status.resources[] | select(.status != "Synced")'`, and report the drifting object to the user. The fix is an `ignoreDifferences` entry for the defaulted field, which is the user's call.

- [ ] **Step 5: Cluster health and the connection name (Review Focus 2)**

Define the helpers used by every later task:

```bash
nb()  { kubectl -n nats exec deploy/nats-box -- "$@"; }
sys() { nb nats --context default "$@"; }
app() { nb nats --context app "$@"; }
```

```bash
sys server list
sys server report jetstream
```

Expected: three servers; the JetStream report names a meta leader and shows three peers, all current.

Now the negative check. From inside the cluster, the in-cluster name must fail and the public name must work:

```bash
nb nats --context app --server nats://nats.nats.svc.cluster.local:4222 account info
```

Expected: an x509 error saying the certificate is valid for `nats.k8s.somemissing.info`, not `nats.nats.svc.cluster.local`.

Run: `app account info`
Expected: account details for `APP` with JetStream enabled.

- [ ] **Step 6: DNS**

Run: `dig +short nats.k8s.somemissing.info; kubectl -n nats get svc nats -o jsonpath='{.spec.clusterIP}{"\n"}'`
Expected: the two addresses match. external-dns can take a minute or two.

- [ ] **Step 7: Prometheus targets and rules**

```bash
pq() { kubectl get --raw "/api/v1/namespaces/monitoring/pods/$1:9090/proxy/api/v1/query?query=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$2")" | jq -c '.data.result'; }
pq prometheus-prom-kp-prometheus-0 'count(up{job="nats/nats"} == 1)'
pq prometheus-prom-kp-prometheus-0 'count(up{job="cert-manager/cert-manager"} == 1)'
pq prometheus-prom-kp-prometheus-0 'count by (namespace) (certmanager_certificate_ready_status{namespace=~"nats|cert-manager",condition="True"})'
pq prometheus-prom-kp-prometheus-0 'count(nats_server_jetstream_disabled{job="nats/nats",is_meta_leader="true",meta_leader!=""} == 0)'
pq prometheus-prom-kp-prometheus-0 'ALERTS{alertname=~"Nats.*|CertManager.*"}'
```

Expected, in order: value `3`; value `1`; one entry for `namespace="nats"` (value 6) and one for `cert-manager`; value `1`; an empty list `[]`.

If the first query is empty, the PodMonitor's job label is not `nats/nats`. Run `pq prometheus-prom-kp-prometheus-0 'up{namespace="nats"}'`, read the real `job` value, and replace `nats/nats` in `nats-alerts.yaml` and its fixture in a follow-up commit. Apply the same check to `cert-manager/cert-manager`.

Check the rules loaded:

Run: `kubectl -n monitoring get prometheusrule nats-alerts nats-client-cert-alerts-ext cert-manager-alerts`
Expected: three objects.

---

### Task 9: Failover tests

**Files:** none in the repo. Create the test script outside it, at `/tmp/nats-leader-outage.sh`.

**Interfaces:**
- Consumes: helpers `nb`, `sys`, `app` from Task 8 Step 5.
- Produces: stream `ACCEPT_TEST` and consumer `checker`, kept for Task 10.

Verification steps 5 to 9 of the spec.

- [ ] **Step 1: Create the test stream and consumer**

```bash
app stream add ACCEPT_TEST --subjects 'acceptance.>' --replicas 3 --storage file --defaults
app consumer add ACCEPT_TEST checker --pull --ack explicit --deliver all --defaults
app stream info ACCEPT_TEST
```

Expected: the stream info shows `Replicas: 3`, a `Leader:` line and two replicas marked `current`. If the CLI rejects a flag, run `app stream add --help` and use the matching flag; the properties that matter are three replicas, file storage and the subject `acceptance.>`.

- [ ] **Step 2: Start the publisher and the consumer**

Check which node runs nats-box; the loops live in that pod:

Run: `kubectl -n nats get pod -l app.kubernetes.io/component=nats-box -o wide`

The publisher sends an increasing number as each message body and uses a request, so the reply is the JetStream publish acknowledgment (`{"stream":"ACCEPT_TEST","seq":N}`). It logs acknowledged and failed numbers separately.

```bash
kubectl -n nats exec deploy/nats-box -- sh -c '
  rm -f /tmp/acked.log /tmp/failed.log /tmp/consumed.log; i=0
  while true; do i=$((i+1))
    if nats --context app req acceptance.data "$i" --timeout 5s --raw 2>/dev/null | grep -q "\"seq\""
    then echo "$i" >> /tmp/acked.log; else echo "$i" >> /tmp/failed.log; fi
    sleep 0.2
  done' &
PUB_PID=$!
kubectl -n nats exec deploy/nats-box -- sh -c '
  while true; do
    nats --context app consumer next ACCEPT_TEST checker --raw --timeout 5s 2>/dev/null >> /tmp/consumed.log
    echo >> /tmp/consumed.log; sleep 0.1
  done' &
SUB_PID=$!
```

Define the progress check:

```bash
progress() { nb sh -c 'echo acked=$(wc -l < /tmp/acked.log) failed=$(cat /tmp/failed.log 2>/dev/null | wc -l) consumed=$(grep -c . /tmp/consumed.log)'; }
progress; sleep 30; progress
```

Expected: `acked` and `consumed` both grow between the two samples and `failed=0`.

- [ ] **Step 3: Write the leader-outage script**

Create `/tmp/nats-leader-outage.sh`:

```bash
#!/usr/bin/env bash
# Holds one NATS pod offline for HOLD seconds by cordoning every schedulable
# worker, then deleting the pod so its replacement stays Pending.
# Restores scheduling on EVERY exit path: it uncordons exactly the nodes it
# cordoned, and never a node that was already cordoned before it started.
# Usage: nats-leader-outage.sh <pod-name> [hold-seconds]
set -euo pipefail
POD=${1:?pod name, e.g. nats-1}
HOLD=${2:-300}
NS=nats

CORDONED=()
restore() {
  rc=$?
  for n in "${CORDONED[@]:-}"; do
    [ -n "$n" ] || continue
    kubectl uncordon "$n" || echo "FAILED TO UNCORDON $n - run: kubectl uncordon $n" >&2
  done
  exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT TERM

mapfile -t WORKERS < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o json \
  | jq -r '.items[] | select(.spec.unschedulable != true) | .metadata.name')
echo "already cordoned (left alone): $(kubectl get nodes -o json \
  | jq -r '[.items[] | select(.spec.unschedulable == true) | .metadata.name] | join(" ")')"
echo "cordoning: ${WORKERS[*]}"

OLD_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}')
for n in "${WORKERS[@]}"; do
  kubectl cordon "$n"
  CORDONED+=("$n")
done

kubectl -n "$NS" delete pod "$POD" --wait=false

# Wait for the replacement pod object (the old one takes up to 60s to stop).
for _ in $(seq 1 60); do
  NEW_UID=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  [ -n "$NEW_UID" ] && [ "$NEW_UID" != "$OLD_UID" ] && break
  sleep 3
done
[ -n "${NEW_UID:-}" ] && [ "$NEW_UID" != "$OLD_UID" ] || { echo "FAIL: no replacement pod appeared" >&2; exit 1; }

echo "replacement $POD created; holding the outage for ${HOLD}s"
END=$((SECONDS + HOLD))
while [ "$SECONDS" -lt "$END" ]; do
  NODE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.nodeName}')
  PHASE=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
  if [ -n "$NODE" ] || [ "$PHASE" != "Pending" ]; then
    echo "FAIL: replacement scheduled (node='$NODE' phase='$PHASE'); the outage was not sustained" >&2
    exit 1
  fi
  sleep 10
done
echo "PASS: $POD stayed Pending for ${HOLD}s"
```

Run: `chmod +x /tmp/nats-leader-outage.sh && bash -n /tmp/nats-leader-outage.sh`
Expected: exit 0.

- [ ] **Step 4: Run the leader outage**

Record the cordon state and find the stream leader:

```bash
kubectl get nodes > /tmp/nodes-before.txt
app stream info ACCEPT_TEST | grep -E 'Leader|current|outdated'
```

Start the outage on the leader in the background with a five-minute hold:

```bash
LEADER=$(app stream info ACCEPT_TEST --json | jq -r '.cluster.leader')
echo "stream leader: $LEADER"
/tmp/nats-leader-outage.sh "$LEADER" 300 > /tmp/outage.log 2>&1 &
OUTAGE_PID=$!
```

While it runs, new pods anywhere in the cluster cannot schedule. Keep the whole window under about ten minutes.

- [ ] **Step 5: Assert service during the outage**

About 90 seconds after the delete, and again two minutes later:

```bash
app stream info ACCEPT_TEST | grep -E 'Leader|current|outdated|offline'
progress; sleep 60; progress
```

Expected: a `Leader:` that is not `$LEADER`; `acked` and `consumed` both higher in the second sample than in the first. A few entries in `failed.log` from the moment of the leader change are acceptable; a `failed` count that keeps growing is a failure.

- [ ] **Step 6: Confirm the script result and the uncordon**

```bash
wait "$OUTAGE_PID"; echo "exit=$?"; tail -3 /tmp/outage.log
kubectl get nodes > /tmp/nodes-after.txt
diff <(awk '{print $1, $2}' /tmp/nodes-before.txt) <(awk '{print $1, $2}' /tmp/nodes-after.txt) && echo "node scheduling unchanged"
```

Expected: `exit=0`, a `PASS:` line, and `node scheduling unchanged`. If the diff shows a node still `SchedulingDisabled` that was not before, uncordon it by hand at once and report it.

- [ ] **Step 7: Confirm catch-up**

```bash
kubectl -n nats rollout status statefulset/nats --timeout=5m
app stream info ACCEPT_TEST | grep -E 'Leader|current|outdated|offline'
```

Expected: three servers listed between the leader and two replicas, all `current`.

- [ ] **Step 8: Drain a node**

Pick a node that hosts a NATS pod and does not host nats-box (Step 2 showed where nats-box runs; draining its node kills the test loops):

```bash
BOX_NODE=$(kubectl -n nats get pod -l app.kubernetes.io/component=nats-box -o jsonpath='{.items[0].spec.nodeName}')
NODE=$(kubectl -n nats get pod -l app.kubernetes.io/component=nats -o json \
  | jq -r --arg b "$BOX_NODE" '[.items[].spec.nodeName | select(. != $b)][0]')
echo "nats-box on $BOX_NODE; draining $NODE"
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=10m
progress
kubectl uncordon "$NODE"
kubectl -n nats rollout status statefulset/nats --timeout=5m
progress
```

Expected: the drain completes, `acked` and `consumed` keep growing, and the pod returns to `3/3`.

- [ ] **Step 9: Rolling restart**

```bash
kubectl -n nats rollout restart statefulset/nats
kubectl -n nats rollout status statefulset/nats --timeout=15m
progress
```

Expected: the rollout finishes one pod at a time and both counters keep growing.

- [ ] **Step 10: Stop the traffic and check for lost messages**

```bash
kill "$PUB_PID" "$SUB_PID" 2>/dev/null
nb sh -c 'pkill -f "acceptance.data" ; pkill -f "consumer next" ; true'
# Drain what is left in the consumer.
nb sh -c 'for n in $(seq 1 200); do
  out=$(nats --context app consumer next ACCEPT_TEST checker --raw --timeout 2s 2>/dev/null) || break
  [ -n "$out" ] || break; echo "$out" >> /tmp/consumed.log; done'
nb sh -c 'sort -u /tmp/acked.log > /tmp/a; grep . /tmp/consumed.log | sort -u > /tmp/c;
  echo "acked=$(wc -l < /tmp/a) consumed=$(wc -l < /tmp/c) failed=$(cat /tmp/failed.log 2>/dev/null | wc -l)";
  echo "acked but never consumed: $(comm -23 /tmp/a /tmp/c | wc -l)"'
```

Expected: `acked but never consumed: 0`. Every message the server acknowledged reached the consumer, across the leader outage, the drain and the rolling restart. If the count is above zero, raise the drain loop's `200` and re-run before calling it a failure; then list the numbers with `nb comm -23 /tmp/a /tmp/c` and report them.

Keep the stream and consumer. Task 10 needs them.

---

### Task 10: Access control, route mTLS, network policy, certificate reload

**Files:** none in the repo. Working files go in `/tmp/nats-lan`, deleted in Task 11.

**Interfaces:**
- Consumes: helpers from Task 8; stream `ACCEPT_TEST` from Task 9; Secret `nats-lan-test-tls`.
- Produces: nothing later tasks depend on.

Verification steps 10 to 17 of the spec. The workstation is the LAN host. It has no `nats` CLI, so run the nats-box image with podman.

- [ ] **Step 1: Stage the test identity on the LAN host**

```bash
mkdir -m 700 -p /tmp/nats-lan
kubectl -n nats get secret nats-lan-test-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/nats-lan/tls.crt
kubectl -n nats get secret nats-lan-test-tls -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/nats-lan/tls.key
chmod 600 /tmp/nats-lan/tls.key
lan() { podman run --rm --network host -v /tmp/nats-lan:/c:ro,Z docker.io/natsio/nats-box:0.20.2 \
  nats --server tls://nats.k8s.somemissing.info:4222 --tlscert /c/tls.crt --tlskey /c/tls.key "$@"; }
openssl x509 -in /tmp/nats-lan/tls.crt -noout -subject -issuer
```

Expected: `subject=CN=nats-lan-test`, `issuer=CN=nats-client-ca`.

- [ ] **Step 2: Allowed and denied subjects**

```bash
lan pub lantest.check hello
lan pub acceptance.data nope
lan sub 'acceptance.>' --count 1 --timeout 5s
```

Expected: the first publish succeeds. The second reports `Permissions Violation for Publish to "acceptance.data"`. The subscribe reports a permissions violation for the subscription.

- [ ] **Step 3: Denied stream administration**

Task 9 Step 10 stopped the test traffic. Record a baseline, attempt the destructive operations with the restricted identity, then compare:

```bash
app stream info ACCEPT_TEST --json | jq '{messages: .state.messages, last_seq: .state.last_seq}' > /tmp/nats-lan/before.json
lan stream rm ACCEPT_TEST --force ; echo "rm exit=$?"
lan stream purge ACCEPT_TEST --force ; echo "purge exit=$?"
app stream info ACCEPT_TEST --json | jq '{messages: .state.messages, last_seq: .state.last_seq}' > /tmp/nats-lan/after.json
diff /tmp/nats-lan/before.json /tmp/nats-lan/after.json && echo "stream intact"
```

Expected: both commands exit non-zero with a permissions violation on a `$JS.API.` subject, returned within a second or two. A five-second timeout instead of a permissions error is a failure of this check: it means the request went somewhere. Then `stream intact`.

- [ ] **Step 4: Port 4222 without a valid client certificate**

Use the `nats` CLI, not raw `openssl s_client`: the client listener sends a plaintext INFO line before TLS starts.

No certificate:

```bash
podman run --rm --network host docker.io/natsio/nats-box:0.20.2 \
  nats --server tls://nats.k8s.somemissing.info:4222 pub lantest.check x
```

Expected: a TLS error (the server requires a certificate). Not a successful publish.

A certificate from the wrong CA. Issue a throwaway one from the `k8s` ClusterIssuer with the same common name, to prove the CA is what counts:

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: nats-wrong-ca-probe
  namespace: nats
spec:
  secretName: nats-wrong-ca-probe-tls
  commonName: nats-lan-test
  usages: [client auth]
  issuerRef: {kind: ClusterIssuer, name: k8s}
EOF
kubectl -n nats wait certificate/nats-wrong-ca-probe --for=condition=Ready --timeout=2m
mkdir -m 700 -p /tmp/nats-lan/wrong
kubectl -n nats get secret nats-wrong-ca-probe-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/nats-lan/wrong/tls.crt
kubectl -n nats get secret nats-wrong-ca-probe-tls -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/nats-lan/wrong/tls.key
podman run --rm --network host -v /tmp/nats-lan/wrong:/c:ro,Z docker.io/natsio/nats-box:0.20.2 \
  nats --server tls://nats.k8s.somemissing.info:4222 --tlscert /c/tls.crt --tlskey /c/tls.key pub lantest.check x
kubectl -n nats delete certificate nats-wrong-ca-probe
kubectl -n nats delete secret nats-wrong-ca-probe-tls
```

Expected: the publish fails with a TLS error (unknown certificate authority), even though the common name matches a real user. The last two commands remove the probe; the root ArgoCD app does not manage it, so nothing recreates it.

- [ ] **Step 5: Route mTLS from an allowed source**

Positive control first. Each server must list both other servers as route peers. Count distinct peers, not connections: NATS 2.15 opens a pool of connections to each peer.

```bash
sys server request routes --json 2>/dev/null \
  | jq -r '[.server.name, ([.data.routes[].remote_name] | unique | join(","))] | join(" -> ")'
```

Expected: three lines, each naming the two other servers, for example `nats-0 -> nats-1,nats-2`. If the JSON shape differs in this CLI version, run `sys server request routes` without the `jq` filter and read the remote names by eye.

Now the probes. They must come from a NATS pod, or the NetworkPolicy answers instead of TLS. Start a debug container in `nats-0`; it shares the pod's network identity:

```bash
kubectl -n nats debug nats-0 --image=alpine:3.22 --container=tlsprobe -- sleep 1800
sleep 10
kubectl -n nats exec nats-0 -c tlsprobe -- apk add --no-cache openssl >/dev/null
for f in tls.crt tls.key; do
  kubectl -n nats exec -i nats-0 -c tlsprobe -- sh -c "cat > /tmp/client-$f" < /tmp/nats-lan/$f
  kubectl -n nats get secret nats-route-tls -o jsonpath="{.data.${f/./\\.}}" | base64 -d \
    | kubectl -n nats exec -i nats-0 -c tlsprobe -- sh -c "cat > /tmp/route-$f"
done
probe() { kubectl -n nats exec nats-0 -c tlsprobe -- sh -c \
  "sleep 3 | timeout 8 openssl s_client -connect nats-1.nats-headless.nats.svc.cluster.local:6222 $1 2>&1 | grep -cE '^INFO \{' || true"; }
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "route cert:  $(probe '-cert /tmp/route-tls.crt -key /tmp/route-tls.key')"
echo "no cert:     $(probe '')"
echo "client cert: $(probe '-cert /tmp/client-tls.crt -key /tmp/client-tls.key')"
kubectl -n nats logs nats-1 -c nats --since-time="$SINCE" | grep -iE 'tls|route' | tail -20
```

Expected:

```
route cert:  1
no cert:     0
client cert: 0
```

`sleep 3 |` holds the connection open long enough to read the server's first line. The route certificate gets a NATS `INFO {` line after the handshake; that proves the probe can tell success from failure. The other two get none. The `nats-1` log must show a TLS handshake error for the route listener for each of the two rejected attempts (wording such as `TLS route handshake error` or `tls: client didn't provide a certificate` and `tls: unknown certificate authority`). If the client-certificate probe prints `1`, a client can open a route: stop and report it as a security failure.

The debug container exits by itself after 30 minutes; Step 7's forced reissue does not need it.

- [ ] **Step 6: Network policy**

From a pod that is not a NATS server (nats-box), and from the LAN host:

```bash
IP=$(kubectl -n nats get pod nats-1 -o jsonpath='{.status.podIP}')
for target in "$IP:8222" "$IP:6222" "nats-headless.nats.svc.cluster.local:8222" "nats-headless.nats.svc.cluster.local:6222"; do
  printf '%s from nats-box: ' "$target"
  nb sh -c "nc -z -w 5 ${target%:*} ${target#*:} && echo OPEN || echo blocked"
done
for port in 8222 6222; do
  printf '%s:%s from LAN: ' "$IP" "$port"
  timeout 5 bash -c "</dev/tcp/$IP/$port" 2>/dev/null && echo OPEN || echo blocked
done
kubectl -n nats get pods
```

Expected: six `blocked` lines, and the three NATS pods still `3/3 Running` with no new restarts. Any `OPEN` is a failure.

- [ ] **Step 7: Certificate reload without restart (Review Focus 4)**

Force cert-manager to reissue the route certificate and confirm every server reloads it in place:

```bash
kubectl -n nats get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount > /tmp/nats-lan/restarts-before.txt
OLD=$(kubectl -n nats get secret nats-route-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl -n nats patch certificate nats-route --subresource=status --type=merge -p \
  "{\"status\":{\"conditions\":[{\"type\":\"Issuing\",\"status\":\"True\",\"reason\":\"ManuallyTriggered\",\"message\":\"acceptance test\",\"lastTransitionTime\":\"$SINCE\"}]}}"
kubectl -n nats wait certificate/nats-route --for=condition=Ready --timeout=2m
NEW=$(kubectl -n nats get secret nats-route-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -serial)
echo "old $OLD new $NEW"
sleep 120
for p in nats-0 nats-1 nats-2; do
  printf '%s: ' "$p"; kubectl -n nats logs "$p" -c nats --since-time="$SINCE" | grep -ci 'reloaded' || true
done
kubectl -n nats get pods -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount | diff /tmp/nats-lan/restarts-before.txt - && echo "no restarts"
sys server list
```

Expected: the serial changes; each pod logs at least one reload line; `no restarts`; three servers still listed with their routes. The 120-second wait covers the kubelet's secret sync period. This patch is what `cmctl renew` does.

- [ ] **Step 8: Client certificate metrics path**

```bash
pq prometheus-ext-0 'count(up{job="cert-manager-nats"} == 1)'
pq prometheus-ext-0 'count by (name) (certmanager_certificate_ready_status{namespace="nats",condition="True"})'
pq prometheus-ext-0 'count({job="cert-manager-nats",__name__!~"certmanager_certificate_.*|up|scrape_.*"})'
pq prometheus-ext-0 'count({job="cert-manager-nats",namespace!="nats",__name__=~"certmanager_.*"})'
pq prometheus-ext-0 'ALERTS{alertname=~"NatsClient.*"}'
```

Expected, in order: value `1`; one entry per NATS certificate; `[]`; `[]`; `[]`. The two empty counts show the relabel rule kept only certificate series for namespace `nats`.

No host exports the client metrics yet, so the fixtures from Task 7 are the only test of the expiry rules in this work.

---

### Task 11: Cleanup and first decommissioning

**Files:**
- Edit: `application.nats.yaml` (first change)
- Edit: `nats-pki.yaml` (second change)

**Interfaces:**
- Consumes: everything above.
- Produces: the steady state: users `nats-admin` and `nats-operator` only.

Verification steps 18 and 19 of the spec. This is the first live run of the decommissioning procedure: revoke, confirm, then remove, in two separate changes. They must not share a commit, because the root ArgoCD app prunes a deleted `Certificate` at once while the NATS config change travels through the child app and a reload on three servers.

- [ ] **Step 1: Delete the test stream**

```bash
app consumer rm ACCEPT_TEST checker --force
app stream rm ACCEPT_TEST --force
app stream ls
```

Expected: no streams.

- [ ] **Step 2: First change, revoke the user**

On a new branch from the updated `main`:

```bash
git switch main && git pull && git switch -c nats-revoke-lan-test
```

In `application.nats.yaml`, delete exactly these lines from `config.merge.accounts.APP.users`:

```yaml
                  - user: CN=nats-lan-test
                    permissions:
                      publish: ["lantest.>"]
                      subscribe: ["lantest.>", "_INBOX.>"]
```

Check the render:

```bash
yq '.spec.source.helm.valuesObject' application.nats.yaml > /tmp/nats-values.yaml
helm template nats nats --repo https://nats-io.github.io/k8s/helm/charts/ --version 2.15.3 -n nats -f /tmp/nats-values.yaml \
  | yq 'select(.kind == "ConfigMap") | .data."nats.conf"' | grep -c 'nats-lan-test'
```

Expected: `0`.

```bash
sh .ci/validate.sh && sh .ci/validate-helm.sh
git add application.nats.yaml
git commit -m "feat(nats): revoke the temporary acceptance-test user"
```

Open a PR and ask the user to merge it. Leave the `Certificate` in place. Record the time just before the merge, for the log check in Step 3:

```bash
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "$SINCE"
```

- [ ] **Step 3: Confirm the revocation on all three servers**

After the merge and the ArgoCD sync:

```bash
for p in nats-0 nats-1 nats-2; do
  printf '%s: ' "$p"; kubectl -n nats logs "$p" -c nats --since-time="$SINCE" | grep -ci 'reloaded' || true
done
for i in $(seq 1 10); do lan pub lantest.check x >/dev/null 2>&1 && echo "attempt $i: ACCEPTED" || echo "attempt $i: rejected"; done
```

Expected: each of the three pods shows at least one reload, and all ten attempts print `rejected`. The certificate still verifies at the TLS layer; the rejection is an authorization failure because no user maps to its subject. One `ACCEPTED` means a server has not reloaded: wait a minute and repeat. Do not start Step 4 until the server rejects all ten.

- [ ] **Step 4: Second change, remove the certificate**

```bash
git switch main && git pull && git switch -c nats-remove-lan-test
```

In `nats-pki.yaml`, delete the whole `nats-lan-test` document: its three comment lines beginning `# TEMPORARY acceptance-test identity`, the `Certificate`, and the `---` separator above it.

```bash
grep -c 'nats-lan-test' nats-pki.yaml application.nats.yaml
sh .ci/validate.sh
git add nats-pki.yaml
git commit -m "feat(nats): remove the temporary acceptance-test certificate"
```

Expected from `grep`: `nats-pki.yaml:0` and `application.nats.yaml:0`. Open a PR and ask the user to merge.

- [ ] **Step 5: Delete the leftover Secret and the local copies**

cert-manager here runs without `--enable-certificate-owner-ref`, so it leaves the Secret and its private key behind. After the merge:

```bash
kubectl -n nats get certificate nats-lan-test 2>&1 | tail -1
kubectl -n nats delete secret nats-lan-test-tls
rm -rf /tmp/nats-lan /tmp/nats-leader-outage.sh /tmp/outage.log /tmp/nodes-before.txt /tmp/nodes-after.txt /tmp/nats-values.yaml /tmp/nats-rendered.yaml /tmp/nats-issuance-roles.txt
```

Expected: `NotFound` for the certificate, then `secret "nats-lan-test-tls" deleted`.

- [ ] **Step 6: Final state**

```bash
sys server list
kubectl -n nats get certificate
kubectl -n argocd get application nats -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
pq prometheus-prom-kp-prometheus-0 'ALERTS{alertname=~"Nats.*|CertManager.*"}'
```

Expected: three servers; certificates `nats-admin`, `nats-operator`, `nats-route`, `nats-route-ca`, `nats-server`; `Synced Healthy`; no firing alerts.

Report to the user what remains outside this plan: the host-side exporter in the Ansible repo, and onboarding the first real device (its `nats-device-<cn>` certificate, user entry and exporter in one change).
