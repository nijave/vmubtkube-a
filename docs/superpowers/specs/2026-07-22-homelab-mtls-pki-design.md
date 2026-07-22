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
Secrets. OpenTofu state lives in the **`kubernetes` backend** (a Secret). The Job
runs only when triggered (manual, Argo, or an optional `CronJob`), satisfying the
"must not run continually" constraint.

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
- Wire the CRL into the HA `HTTPProxy` (`clientValidation.crlSecret`).

**Out of scope**

- Regenerating or re-keying the CA.
- OCSP (CRL only).
- Automatic cert distribution onto devices (the `.p12` is retrieved manually).
- Changing the `python-envoy-authz` authorization extension.

---

## Architecture

| Concern | Decision |
|---|---|
| Delivery vehicle | One-shot **Kubernetes Job** (optional `CronJob`, `concurrencyPolicy: Forbid`) |
| Declarative engine | **OpenTofu** running inside the Job container |
| X.509 engine | **CFSSL** (sign + `gencrl`), **OpenSSL** (PKCS#12 packaging) |
| Tofu state | **`kubernetes` backend** — state stored in a Secret in-cluster |
| Provider cache | Optional PV mounted at `TF_PLUGIN_CACHE_DIR`; pruned when pinned provider versions change |
| CA cert source | Existing `default` `ClusterSecretStore`, key `ca-ha.apps.somemissing.info` |
| CA key source | Loaded once into the same secret backend, surfaced to the Job via ExternalSecret → mounted Secret. Never in git. |
| Namespaces | Job + state + per-device Secrets in `homelab-pki`; CRL Secret written into `default` (same namespace as the HA `HTTPProxy`) |

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
| CA cert Secret | as needed | `ca.crt` | already present in `default` for `HTTPProxy` |
| CRL Secret | `default` | `crl.pem` | Contour `clientValidation.crlSecret` |
| Tofu state Secret | `homelab-pki` | opaque tofu state | OpenTofu backend |

PKCS#12 passphrase handling (currently the literal `password`) is carried into a
Secret/config value rather than hard-coded; default preserved for compatibility.

---

## CRL consumption

Update the HA `HTTPProxy` (`proxy_homeassistant.yaml`) client validation to add
the CRL:

```yaml
tls:
  secretName: ha-apps-somemissing-info-tls
  clientValidation:
    caSecret: ca-ha-homelab-somemissing-info-tls
    crlSecret: <crl-secret>          # new
    optionalClientCertificate: true  # revisit: flip to required once migration done
```

`optionalClientCertificate` stays `true` during migration; flipping to required
is a follow-up decision once every device is on a new cert.

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

Manual Job (kubectl / Argo) by default. Optional `CronJob`
(`concurrencyPolicy: Forbid`) to refresh the CRL and re-render Secrets on a
schedule. Concurrency-forbid is the locking story for the `kubernetes` state
backend in a single-cluster homelab.

---

## Testing / verification

- Reconciler unit cases: the four worked examples above, plus idempotency
  (re-apply with no config change → no diff).
- Cert validation: `openssl verify -CAfile ca.crt <leaf>` and inspect that
  `extra_extensions` OIDs, EKU, SAN, and name constraints are present.
- CRL validation: `openssl crl -in crl.pem -noout -text` shows exactly
  `revoked_serials`; a revoked leaf is rejected by a client configured with the
  CRL.
- Manifest validation: `.ci/validate.sh` (kubeconform) on all rendered YAML.

---

## Open decisions (confirm during planning)

- CA private-key delivery mechanism into the `default` secret backend (one-time
  manual load vs. a bootstrap path).
- Whether the optional plugin-cache PV is provisioned now or deferred.
- PKCS#12 passphrase source (keep literal default vs. per-user secret).
