# Homelab mTLS Client-Cert PKI (declarative, in-Job, CRL-capable)

**Date**: 2026-07-22
**Status**: Design — not yet implemented

---

## Problem

Home Assistant client-certificate mTLS (`ha.apps.somemissing.info`) is currently
provisioned by a hand-run bash script,
`~/Documents/workspace/misc/make-ca/ca.sh`. It creates a name-constrained
RSA-4096 CA and signs per-device client certs (`nick-desktop`, `nick-ipad`,
`nick-xps`, `pixel7`, `kara-iphone`), emitting `.crt` / `.key` / `.p12` for each.
Consumption is at the Contour `HTTPProxy` for `ha.apps.somemissing.info`
(`clientValidation.caSecret`, `optionalClientCertificate: true`).

Two gaps:

1. **No revocation.** The script never produces a CRL, so a lost/sold device
   cannot be invalidated — the only recourse is re-keying the whole CA.
2. **Not declarative / not in-cluster.** Issuance is a local imperative script,
   out of GitOps, with no auditable record of which certs exist.

We want the desired PKI state expressed declaratively, reconciled **on demand
inside Kubernetes** (no long-running CA service), with **custom-OID extensions**
and **CRL generation**, results published as Secrets, and the CRL wired into the
existing Contour client validation.

## Solution

A one-shot **Kubernetes Job** runs a container bundling **OpenTofu** + **CFSSL**
(`cfssl`/`cfssljson`) + **OpenSSL**. OpenTofu parses declarative HCL describing
the desired certs, a **reconciler pre-step** computes the concrete per-serial
plan against current state, CFSSL signs leaves and generates the CRL, OpenSSL
packages PKCS#12, and the `kubernetes` provider publishes CA / leaf / CRL
Secrets. OpenTofu state lives in the **`kubernetes` backend** (a Secret). It runs
only when triggered — an immediate `Job` on config change plus a required
periodic CRL-refresh `CronJob` (see Trigger) — never as a long-running service,
satisfying the "must not run continually" constraint.

Rationale for the composition: no native Terraform/OpenTofu provider and no
in-cluster controller (cert-manager, step-ca, Vault) satisfies *both* arbitrary
custom-OID extensions *and* CRL generation *without a long-running service*.
CFSSL is the offline engine that does both (`cfssl sign` with
`copy_extensions`/raw extensions, `cfssl gencrl`); OpenSSL covers PKCS#12, which
CFSSL cannot emit. OpenTofu supplies the declarative-config interface and the
Secret writes.

---

## Scope

**In scope**

- Import and **preserve** the existing CA (cert + key) — never regenerate it.
- **Re-issue all device client certs fresh** with configurable features,
  including custom-OID extensions and `clientAuth` EKU.
- Generate a single **CRL** from a declarative revoked-serials list.
- Publish CA cert, per-device `.crt`/`.key`/`.p12`, and the CRL as Secrets.
- Distribute the CRL via the **secret backend** (matching the CA-cert pattern)
  and enforce it at **both** CRL enforcement points — the HA `HTTPProxy`
  (`clientValidation.crlSecret`) and the `python-envoy-authz` ext_authz service.
- In this repo: the manifest-side wiring for python-envoy-authz (its
  `ExternalSecret` + CRL env/volume + `reloader` annotation).
- **OpenTelemetry tracing** of each reconciler run (OpenTofu native traces +
  wrapper spans for the cfssl/openssl/reconcile phases) exported to HyperDX /
  ClickHouse via the repo's collector pattern.

**Out of scope**

- Regenerating or re-keying the CA.
- OCSP (CRL only).
- Automatic cert distribution onto devices (the `.p12` is retrieved manually).
- The **python-envoy-authz source change** to consume the CRL — that lives in the
  authz service repo (`registry.apps.nickv.me/nijave/python-envoy-authz`) and is
  tracked here as a cross-repo dependency (see CRL consumption).

---

## Architecture

| Concern | Decision |
|---|---|
| Delivery vehicle | **Immediate one-shot `Job` on config change** (Argo-driven) **and** a **required periodic CRL-refresh `CronJob`** — same image/logic, `concurrencyPolicy: Forbid`. See Trigger + CRL freshness. |
| Declarative engine | **OpenTofu** running inside the Job container |
| X.509 engine | **CFSSL** (sign + `gencrl`), **OpenSSL** (PKCS#12 packaging) |
| Tofu state | **`kubernetes` backend** — state stored in a Secret in-cluster |
| Provider cache | Optional PV mounted at `TF_PLUGIN_CACHE_DIR`; pruned when pinned provider versions change |
| CA cert source | Existing `default` `ClusterSecretStore`, key `ca-ha.apps.somemissing.info` |
| CA key source | Loaded once into the same secret backend, surfaced to the Job via ExternalSecret → mounted Secret. Never in git. |
| CRL distribution | Job **publishes the CRL back into the `default` `ClusterSecretStore`** (key `crl-ha.apps.somemissing.info`); each consuming namespace pulls it via its own `ExternalSecret` at **`refreshInterval: 15s`** (fast poll is trivial — all in-cluster) — mirroring CA-cert distribution. |
| Namespaces | Job + state + per-device Secrets in `homelab-pki`; CRL pulled via `ExternalSecret` in both `default` (for the HA `HTTPProxy`) and `projectcontour` (for `python-envoy-authz`) |
| Observability | OpenTofu native OTel traces (**≥1.11**) + wrapper spans; OTLP **direct to `otel-collector.k8s.somemissing.info:4317`** (central, TLS) → HyperDX/ClickHouse. No namespaced collector. See Observability. |

### Provider cache cleanup

An init/pre step keys the plugin cache on a hash of the pinned provider
versions. When the hash changes, the stale cache directory is pruned before
`tofu init` so an old provider binary cannot linger. Works with or without the
PV mounted (no PV → cold download each run).

---

## Declarative configuration

`devices` is a **list of name strings** (duplicates allowed). Cert features are
set **once per user** and inherited by all that user's device certs.

```hcl
# Serials in the CRL. Independent of what is stored. May reference serials that
# are no longer stored (e.g. legacy ca.sh certs, or previously-deleted certs).
revoked_serials = ["0x1000", "0x1001", "0x1002", "0x1003",
                   "0x1004", "0x1005", "0x1006", "0x1007"]

users = {
  nick = {
    key              = { algorithm = "RSA", size = 2048 }
    ekus             = ["clientAuth"]
    extra_extensions = [
      { oid = "1.3.6.1.4.1.<arc>.1", value_b64 = "...", critical = false },
    ]
    devices = [
      "nick-desktop",   # serial auto-assigned, e.g. 0x2001
      "nick-desktop",   # duplicate name -> a second cert, e.g. 0x2002
      "pixel7",         # e.g. 0x2010
    ]
  }
}
```

- **User-level (set once):** `key` (algorithm + size), `ekus`, `extra_extensions`
  (custom OIDs: dotted-decimal `oid`, base64-DER `value_b64`, `critical`).
- **`devices`:** plain name strings; duplicates create multiple independent certs
  for the same device name (CN `<name>.ha.apps.somemissing.info`, SAN DNS
  `<name>.ha.apps.somemissing.info`).
- **`revoked_serials`:** the exact set of serials in the CRL.

Serials are **auto-assigned**, sticky in state until their cert is deleted, and
surfaced in outputs as a `name -> [serials]` mapping for auditing and for
recovering a serial into `revoked_serials` when needed.

---

## Reconciliation semantics

`devices` (list) and `revoked_serials` are **fully orthogonal controls**:

- **`devices` → storage only.** `#stored` certs for a name = `#entries` for that
  name. Add an entry → mint a new cert (new auto serial) + write its Secret.
  Remove an entry → delete one stored cert for that name. Revocation never adds,
  deletes, or replaces a stored cert.
- **`revoked_serials` → CRL only.** The CRL is exactly these serials. No effect on
  storage. A serial may be revoked whether or not it is still stored.
- **Which duplicate is deleted on shrink:** if a name has duplicates and one of
  its stored serials is in `revoked_serials`, delete *that* one; otherwise delete
  an arbitrary one. This makes "remove an entry **and** revoke its serial in the
  same apply" delete exactly the revoked cert.

Reconciliation is **count-based per name**, hence idempotent:

| Condition | Action |
|---|---|
| `entries(name) == stored(name)` | no change |
| `entries(name) > stored(name)` | create the difference (new serials), write Secrets |
| `entries(name) < stored(name)` | delete the difference (revoked-serial-preferred, else arbitrary) |
| serial ∈ `revoked_serials` | present in CRL (no storage effect) |

### Worked examples (authoritative)

Starting from stored `nick-desktop=0x2001`, `nick-desktop=0x2002`,
`pixel7=0x2010`:

1. `devices=[nick-desktop, nick-desktop, pixel7]`, `revoked_serials=[]`
   → **3 stored, 0 in CRL.**
2. same `devices`, `revoked_serials=["0x2002"]`
   → **3 stored** (0x2002 still stored), **1 in CRL.**
3. `devices=[nick-desktop, pixel7]`, `revoked_serials=[]`
   → **2 stored** (dropped `nick-desktop` 0x2002 deleted), **0 in CRL.** Deleted
     cert is *not* revoked — still cryptographically valid in the wild.
4. `devices=[nick-desktop, pixel7]`, `revoked_serials=["0x2002"]`
   → **2 stored, 1 in CRL** (0x2002 revoked and no longer stored).

### Why a reconciler pre-step

"Keep an arbitrary N of the existing certs" depends on prior state, which pure
declarative HCL cannot express. The Job therefore runs a reconciler that reads
current state (serial-keyed Secrets / the state Secret), computes the concrete
target serial set from `{per-name counts, revoked_serials}`, and only then does
OpenTofu materialize serial-keyed `kubernetes_secret` resources plus the CRL.
The HCL declares *intent* (counts per name, dead serials); the reconciler
resolves it to concrete serials.

---

## Certificate profile

Reproduces the existing `client.*.ini`, plus configurable extras:

- `basicConstraints = critical, CA:FALSE`
- `keyUsage = critical, digitalSignature, keyEncipherment`
- `extendedKeyUsage = clientAuth` (+ any user `ekus`)
- `subjectKeyIdentifier = hash`, `authorityKeyIdentifier = keyid,issuer`
- `subjectAltName = DNS:<name>.ha.apps.somemissing.info`
- user `extra_extensions` (arbitrary OIDs) appended

The CA's `nameConstraints` (already baked into the imported CA cert) continue to
confine issuance to `*.ha.apps.somemissing.info`; the tool does not recreate the
CA, so those constraints are inherited unchanged.

---

## Outputs and Secret layout

| Secret | Namespace | Contents | Consumer |
|---|---|---|---|
| `<name>-<serial>` (per stored cert) | `homelab-pki` | `tls.crt`, `tls.key`, `<name>.p12` | manual retrieval → device install |
| CA cert Secret | `default`, `projectcontour` | `ca.crt` | already distributed via `ExternalSecret` from backend key `ca-ha.apps.somemissing.info` |
| CRL (backend) | `default` `ClusterSecretStore` | key `crl-ha.apps.somemissing.info` | published by the Job |
| CRL Secret (pulled) | `default`, `projectcontour` | `crl.pem` | `ExternalSecret` → HTTPProxy `clientValidation.crlSecret` and `python-envoy-authz` |
| Tofu state Secret | `homelab-pki` | opaque tofu state | OpenTofu backend |

PKCS#12 passphrase handling (currently the literal `password`) is carried into a
Secret/config value rather than hard-coded; default preserved for compatibility.

---

## CRL consumption

There are **two enforcement points**, because the HA `HTTPProxy` runs
`optionalClientCertificate: true` — Envoy does not *require* a client cert at the
TLS layer, so the real allow/deny decision is made by the `python-envoy-authz`
ext_authz service. That service is already injected with the HA CA cert
(`HA_CA_CERTIFICATE`) and validates the presented client cert against it, so it
must also honor the CRL. A revoked cert must be rejected in **both** places.

### Distribution (backend → ExternalSecret, matching the CA cert)

The Job publishes the CRL into the `default` `ClusterSecretStore` under
`crl-ha.apps.somemissing.info`. Each consuming namespace pulls it with its own
`ExternalSecret` at **`refreshInterval: 15s`** (as is already done for
`ca-ha.apps.somemissing.info` in both `default` and `projectcontour`, but faster
— the CA cert uses 300s; a 15s poll is trivial since it is all in-cluster). The
tool does not write namespace Secrets directly for the CRL. The tight poll keeps
end-to-end revocation latency low (see Reload, latency, and freshness).

### 1. Envoy TLS layer — HA `HTTPProxy` (`proxy_homeassistant.yaml`)

```yaml
tls:
  secretName: ha-apps-somemissing-info-tls
  clientValidation:
    caSecret: ca-ha-homelab-somemissing-info-tls
    crlSecret: crl-ha-homelab-somemissing-info   # new; from ExternalSecret in default
    optionalClientCertificate: true              # revisit: flip to required post-migration
```

Rejects a revoked cert *if one is presented* at the edge.

### 2. Authorization layer — `python-envoy-authz` (`python-envoy-authz.yaml`)

Manifest-side wiring **in this repo**, mirroring the existing
`HA_CA_CERTIFICATE` pattern:

- add an `ExternalSecret` in `projectcontour` pulling
  `crl-ha.apps.somemissing.info` → `crl.pem`;
- surface it to the Deployment (env `HA_CRL` from the Secret, or a mounted
  volume);
- the Deployment already has `reloader.stakater.com/auto: "true"`, so a CRL
  update triggers a rollout.

**Cross-repo dependency (out of this repo):** the `python-envoy-authz` source
(`registry.apps.nickv.me/nijave/python-envoy-authz`) must be changed to load the
CRL and deny when the presented client cert's serial is listed. Until that ships,
enforcement point #2 is inert and only the Envoy TLS layer honors the CRL — which
is insufficient under `optionalClientCertificate: true`. This dependency gates
the "revocation actually blocks a device" guarantee.

`optionalClientCertificate` stays `true` during migration; flipping to required
is a follow-up decision once every device is on a new cert.

### Reload, latency, and CRL freshness

- **Envoy hot-reloads the CRL — no restart.** Contour delivers the client
  validation context (`caSecret` + `crlSecret`) to Envoy over **SDS/xDS** and
  watches the referenced Secrets; on change it re-renders and pushes the updated
  validation context, which Envoy applies dynamically. (The Envoy "CRL file
  hot-reload" caveats — `cp` vs `mv`/inotify races — are about **file-based**
  `DataSource.filename`; they do **not** apply to Contour's server-pushed SDS.)
- **Revocation latency chain:** CRL published → `ExternalSecret` poll
  (**15s**) → k8s Secret updated → Contour watch (near-instant) → Envoy SDS push
  (near-instant). So a revocation takes effect within ~15s at the TLS layer.
  `python-envoy-authz` picks up the new CRL when `reloader` restarts it on the
  same Secret change (also ~15s + rollout), once its source reads the CRL.
- **Only new handshakes are affected; HA holds a long-lived WebSocket.** CRL is
  checked at the TLS handshake, so an **already-open** connection is not
  re-validated. The HA route uses `enableWebsockets: true` and
  `timeoutPolicy.response: 24h`, so a revoked device with a live session can stay
  connected until it drops/reconnects. Immediate cutoff would require draining
  existing connections (e.g. restarting Envoy) — out of scope; noted as a
  known limitation.
- **CRL freshness is load-bearing (why the CronJob is required).** Envoy fails
  verification once the CRL's `nextUpdate` lapses (`CRL has expired`), and that
  fails **all** client certs from the chain — not just revoked ones. So the
  periodic CronJob must regenerate the CRL well before `nextUpdate`. Concretely:
  pick a CRL validity window and a CronJob cadence with comfortable margin (e.g.
  validity 7d, regenerate daily), so a missed run or two cannot expire the CRL.
- **Single-level CA → one CRL covers the chain.** Envoy requires a CRL for
  *every* CA in the trust chain, else all certs from that chain fail. The HA CA
  is a single self-signed, name-constrained CA that signs leaves directly (one
  level), so the single CRL suffices. **Assumption to preserve:** do not
  introduce an intermediate without also CRL-covering it (or setting
  `crlOnlyVerifyLeafCert: true` on the `HTTPProxy`).

---

## Operational flows

- **Issue a new device cert:** add its name to the user's `devices` list → apply.
- **Blue/green rotate a device:** (1) add a duplicate entry → new cert minted;
  (2) install the new `.p12` on the device and verify; (3) in one apply, remove
  one entry **and** add the old serial to `revoked_serials` → the old cert is
  deleted and revoked, the new one remains.
- **Revoke without rotating:** add the serial to `revoked_serials` (cert stays
  stored but is in the CRL) — case 2.
- **Retire legacy `ca.sh` certs:** after every device is migrated, add the legacy
  serials (`0x1000`–`0x100x`) to `revoked_serials`. They are CRL-only (never
  stored here).

---

## Trigger

Two triggers, same container image and reconciler logic:

1. **Immediate, on config change (`Job`).** When the HCL config changes in git,
   Argo CD syncs and runs the reconciler **immediately** — so issuance and
   revocation take effect as soon as the change lands, not on the next cron tick.
   Implemented as an Argo **Sync hook** Job, or a Job whose name/annotations carry
   a **hash of the rendered config** (Jobs are immutable, so a new hash → a new
   Job created + old pruned; an unchanged hash → no re-run). Manual `kubectl` /
   Argo re-sync remains available for ad-hoc runs.
2. **Periodic (`CronJob`), required.** Re-runs the reconciler on a schedule purely
   to keep the CRL fresh (regenerate before `nextUpdate`; see CRL freshness),
   independent of whether the config changed.

`concurrencyPolicy: Forbid` on the CronJob and single-active-run enforcement
(the config-hash Job is naturally singular) are the locking story for the
`kubernetes` state backend in a single-cluster homelab — the two triggers must
never run concurrently.

---

## Observability — OpenTelemetry tracing

Every reconciler run (config-change Job and CRL-refresh CronJob) emits a trace so
that issuance, revocation, and CRL regeneration are visible in HyperDX/ClickHouse.

> **Phasing — separate post-MVP commit.** Tracing is **not** part of the MVP. The
> MVP (CA import, issuance, CRL, Secrets, consumption/wiring, dual triggers) ships
> first and is verified working. Tracing lands afterward in its **own commit**,
> which contains: the OTel env vars on the Job/CronJob, the wrapper-span
> entrypoint, the central-collector `tail_sampling` policy change
> (`application.otel-collector.yaml`), and the clarifying comment on
> `application.otel-collector-contour.yaml`. None of those collector edits are
> made until the MVP is done.

### What is instrumented

- **OpenTofu native tracing** (experimental, **OpenTofu ≥ 1.11** — 1.10 covered
  only `init`; 1.11 adds provider gRPC-call spans across plan/apply). Enabled by
  environment variables on the Job/CronJob:

  ```
  OTEL_TRACES_EXPORTER=otlp
  OTEL_EXPORTER_OTLP_ENDPOINT=https://otel-collector.k8s.somemissing.info:4317
  # Set service.name explicitly to OpenTofu's canonical value "opentofu"
  # (OpenTofu hardcodes no default — unset would fall to the SDK's
  # "unknown_service:tofu"; OpenTofu's own docs use OTEL_SERVICE_NAME=opentofu).
  # Every tofu run should use this same value, so one collector policy matches
  # them all. Identify THIS run via resource attributes:
  OTEL_SERVICE_NAME=opentofu
  OTEL_RESOURCE_ATTRIBUTES=service.namespace=homelab-pki,tofu.project=homelab-pki
  ```

  OpenTofu samples 100% at source when enabled (no source-side sampling knob).

- **Wrapper spans** for the non-OpenTofu phases (reconciler state read, `cfssl
  sign`, `cfssl gencrl`, `openssl` PKCS#12, Secret publish). The container
  entrypoint opens a root `pki-run` span and exports `TRACEPARENT`; OpenTofu and
  the shell-out steps nest under it (via `otel-cli` or a small SDK helper). Result:
  one trace per run, root `pki-run` → child spans per phase.

### Collector routing (connect directly to the central collector)

The Job/CronJob exports OTLP **directly to the central collector**,
`otel-collector.k8s.somemissing.info:4317` (TLS; the collector serves a
cert-manager cert for that hostname). This is the repo's standard pattern — Argo
CD, Grafana/kube-prometheus, Thanos, and prometheus-ext all point straight at
`otel-collector.k8s.somemissing.info:4317`. The central collector tail-samples
and exports to `hyperdx-otel-collector.hyperdx:4317`.

```
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel-collector.k8s.somemissing.info:4317
# TLS verifies against the cluster/public trust for that hostname — not insecure.
```

**No namespaced collector.** The `otel-collector-contour` collector in
`projectcontour` is **not** the general pattern — it exists solely because
Contour wires Envoy tracing through a Contour **`ExtensionService`**
(`contour-tracing.yaml`), which can only target a local in-cluster Service over
h2c and cannot point at the TLS central endpoint directly. It bounces traces to
`otel-collector.k8s.somemissing.info:4317`. That limitation does not apply here:
a plain workload setting `OTEL_EXPORTER_OTLP_ENDPOINT` connects directly, so this
project adds **no** always-on collector Deployment.

### Central tail-sampling — keep all OpenTofu traces (`service.name == "opentofu"`)

The central collector's `tail_sampling` keeps errors and
`service.name == "claude-code"`, else **1% probabilistic**. Tofu runs are
infrequent but important, so at 1% they would usually be dropped.

**Keep the policy scoped to *any* OpenTofu run anywhere, by matching the shared
`service.name == "opentofu"`** (mirroring the existing `claude-code` OTTL policy):

```yaml
# application.otel-collector.yaml — new tail_sampling policy (post-MVP commit)
- name: opentofu
  type: ottl_condition
  ottl_condition:
    error_mode: ignore
    span:
      - 'resource.attributes["service.name"] == "opentofu"'
```

`tail_sampling` decides per-trace, so any span with `service.name=opentofu` keeps
the whole trace (including the `pki-run` wrapper spans that share the trace id).
The PKI run is then found in HyperDX by filtering on the
`service.namespace=homelab-pki` / `tofu.project=homelab-pki` resource attributes.

**Notes:**
- This is OTel-idiomatic: `service.name` is set explicitly (not left at the SDK's
  `unknown_service:tofu`), to OpenTofu's own documented value `opentofu`.
- It depends on the convention that **every** tofu run sets
  `OTEL_SERVICE_NAME=opentofu`. This project does; any future tofu workload
  should too, so the single policy keeps catching them.
- The wrapper `pki-run` spans (from `otel-cli`/SDK) may carry their own
  `service.name`; that is fine — the per-trace keep decision only needs the tofu
  spans to match.

---

## Testing / verification

- Reconciler unit cases: the four worked examples above, plus idempotency
  (re-apply with no config change → no diff).
- Cert validation: `openssl verify -CAfile ca.crt <leaf>` and inspect that
  `extra_extensions` OIDs, EKU, SAN, and name constraints are present.
- CRL validation: `openssl crl -in crl.pem -noout -text` shows exactly
  `revoked_serials`; a revoked leaf is rejected by a client configured with the
  CRL.
- End-to-end revocation: revoke a test device's serial, confirm the CRL Secret
  propagates via `ExternalSecret` (~15s) to both `default` and `projectcontour`,
  and confirm a request with the revoked cert is denied at the Envoy TLS layer
  (new handshake) and (once the authz source change ships) by
  `python-envoy-authz`.
- CRL freshness: confirm the CronJob regenerates the CRL before `nextUpdate`;
  verify that an expired CRL fails *all* client auth (negative test) so the
  freshness margin is understood and monitored.
- Trigger behavior: a config change produces an immediate reconciler run (new
  config-hash Job); an unchanged config does not re-run; CronJob and config Job
  never run concurrently (`Forbid`).
- Manifest validation: `.ci/validate.sh` (kubeconform) on all rendered YAML.
- Tracing (post-MVP): a run produces one trace (root `pki-run` + phase spans)
  visible in HyperDX, filterable by `service.namespace=homelab-pki`; confirm the
  `service.name == "opentofu"` tail-sampling policy keeps 100% of tofu traces
  (not dropped by the 1% sampler).

---

## Open decisions (confirm during planning)

- CA private-key delivery mechanism into the `default` secret backend (one-time
  manual load vs. a bootstrap path).
- Whether the optional plugin-cache PV is provisioned now or deferred.
- PKCS#12 passphrase source (keep literal default vs. per-user secret).
- OpenTofu version pin (≥1.11 for provider-call span coverage).
