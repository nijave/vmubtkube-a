# homelab-pki Provider Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite `homelab-pki/` onto the `nijave/pki` Terraform provider — delete the Python/cfssl/openssl reconciler, express CA/device/CRL state as native `pki_*` resources, and collapse the Job/CronJob to a single `tofu apply`.

**Architecture:** `homelab-pki/tofu/*.tf` becomes the entire desired-state config: `locals.tf` holds users/devices as native Terraform data, `ca.tf` imports the CA as a `pki_certificate_authority`, `devices.tf` uses `for_each` over a flattened device map to produce `pki_private_key`/`pki_certificate`/`pki_bundle`/`kubernetes_secret` per device, `crl.tf` produces the CRL and its Secret. The Dockerfile drops everything except the `tofu` binary. This plan covers only the code/manifest rewrite (all locally verifiable via `tofu validate`) — the one-time production import/cutover is a separate manual procedure documented in the design spec and is explicitly **not** automated here.

**Tech Stack:** OpenTofu ≥1.11.0, `nijave/pki ~> 1.0` (published on the Terraform Registry as `registry.terraform.io/nijave/pki`), `hashicorp/kubernetes ~> 3.0`, Alpine 3.24.1.

## Global Constraints

- Design doc: `docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md` — this plan implements it exactly; consult it for rationale on any decision below.
- Provider source is fully-qualified: `registry.terraform.io/nijave/pki`, version `~> 1.0` (the OpenTofu registry PR for this provider hasn't merged yet).
- `hashicorp/kubernetes` stays at `~> 3.0` (unchanged from current `main.tf`).
- Device Secrets are named `pki-<device-name>` (no serial suffix) — serial is provider-auto-assigned (`Optional+Computed`) and kept only as the `pki/serial` label, not the Secret name.
- CA is imported as a managed `pki_certificate_authority` resource, never regenerated. Its private key is read via `data "kubernetes_secret" "ca"` + `base64decode(...)` — no `/ca` volume mount.
- `subject`/`extra` blocks always use the **ordered `attribute` form**, never named fields (required for byte-identical import). DN order is fixed: `commonName, uid, displayName, givenName, surname, organization`, then any `organizationalUnit`s.
- `basic_constraints`/`key_usage` are always declared explicitly on `pki_certificate_authority`/`pki_certificate` (never omitted), per the documented import block-shape gotcha.
- PKCS12 password stays the literal string `"password"` via `pki_bundle`'s write-only `password_wo` (preserves current, non-secret behavior exactly).
- Device cert validity is `"175320h"` (~20 years), matching existing certs.
- Config (`local.users`/`local.devices`/`local.revoked_serials`) lives only as native `.tf` — no `config.hcl`, no `pki-config` ConfigMap.
- Out of scope: CA rotation, `cert-manager`/`clusterissuer.yaml`/DNSimple issuers, wiring `HA_CRL` into `python-envoy-authz` or `crlSecret` into `proxy_homeassistant.yaml`, and the actual one-time production import (documented separately, not automated by this plan).
- No task in this plan touches the live cluster or requires cluster credentials — every verification step is local (`tofu init -backend=false`, `tofu validate`, `tofu fmt -check`).

---

### Task 1: Delete the Python reconciler and its runtime artifacts

**Files:**
- Delete: `homelab-pki/reconcile/` (entire directory: `config.py`, `engine.py`, `__init__.py`, `main.py`, `plan.py`, `state.py`, `tests/`, `__pycache__/`)
- Delete: `homelab-pki/cfssl/` (entire directory: `ca-config.json`)
- Delete (local, gitignored, not tracked by git): `homelab-pki/.venv/`, `homelab-pki/.pytest_cache/`
- Modify: `homelab-pki/config.hcl` — delete this file (superseded by `locals.tf` in Task 3)
- Modify: `homelab-pki/.gitignore`

**Interfaces:**
- Consumes: nothing (this is pure deletion).
- Produces: a clean `homelab-pki/` directory containing only `Dockerfile`, `.gitignore`, `tofu/` — everything later tasks build on.

- [ ] **Step 1: Delete the reconciler, cfssl config, and old HCL config**

```bash
git rm -r homelab-pki/reconcile homelab-pki/cfssl homelab-pki/config.hcl
```

- [ ] **Step 2: Clean up local (gitignored) Python artifacts**

```bash
rm -rf homelab-pki/.venv homelab-pki/.pytest_cache
```

- [ ] **Step 3: Trim the now-stale `.gitignore` entries**

Replace the full contents of `homelab-pki/.gitignore`:

```
.terraform/
.terraform.lock.hcl
```

(The old entries — `.venv/`, `__pycache__/`, `*.pyc`, `.pytest_cache/` — were all Python artifacts; nothing in the rewritten `homelab-pki/` produces them. The new entries cover the `tofu init -backend=false` artifacts that later tasks' validation steps will create locally.)

- [ ] **Step 4: Verify nothing referencing the deleted code remains**

```bash
grep -rn "reconcile\|cfssl\|config\.hcl\|python" homelab-pki/ --include="*.tf" --include="Dockerfile" 2>/dev/null
```

Expected: no output (Dockerfile still references these until Task 2 rewrites it — if this grep is run before Task 2, seeing hits in `Dockerfile` is expected and fine).

- [ ] **Step 5: Commit**

```bash
git add -A homelab-pki/
git commit -m "chore(homelab-pki): remove Python/cfssl reconciler, superseded by terraform-provider-pki"
```

---

### Task 2: Rewrite the Dockerfile to drop cfssl/openssl/python

**Files:**
- Modify: `homelab-pki/Dockerfile`

**Interfaces:**
- Consumes: `homelab-pki/tofu/` (copied into the image; doesn't need to exist with final content yet for this task, but the `COPY tofu/ /app/tofu/` line must be present for later tasks' files to land in the image).
- Produces: an image containing only the `tofu` binary + `ca-certificates` + `/app/tofu/*.tf`.

- [ ] **Step 1: Replace the full contents of `homelab-pki/Dockerfile`**

```dockerfile
# homelab-pki/Dockerfile
#
# Image bundles OpenTofu + the tofu/ config (pki_* resources from the
# nijave/pki provider express CA import, per-device issuance, and CRL
# generation declaratively). Entry point is /bin/sh; the Job/CronJob run
# sequence is:
#   tofu -chdir=/app/tofu init
#   tofu -chdir=/app/tofu apply -auto-approve
#
# NOTE on base image: `ghcr.io/opentofu/opentofu:1.12` (the full image)
# cannot be used as a Dockerfile FROM base -- as of OpenTofu 1.10 it ships an
# ONBUILD trigger (`ONBUILD RUN exit 1`) that deliberately fails any build
# that FROMs it, per https://opentofu.org/docs/intro/install/docker/ ("direct
# usage of the official images is no longer supported"). The supported
# pattern (Method 1 in that doc) is a multi-stage build that copies the
# `tofu` binary out of the `-minimal` tag (a scratch image containing only
# the static binary at /usr/local/bin/tofu, no ONBUILD trap) onto a plain
# alpine base -- which is what this Dockerfile does below.
#
# Build + push (manual, until CI step lands):
#   cd homelab-pki
#   docker build -t registry.apps.nickv.me/nijave/homelab-pki:0.2.0 .
#   docker push registry.apps.nickv.me/nijave/homelab-pki:0.2.0

FROM ghcr.io/opentofu/opentofu:1.12-minimal AS tofu

FROM alpine:3.24.1
COPY --from=tofu /usr/local/bin/tofu /usr/local/bin/tofu

RUN apk add --no-cache ca-certificates=20260413-r0

COPY tofu/ /app/tofu/

WORKDIR /app
ENTRYPOINT ["/bin/sh"]
```

- [ ] **Step 2: Verify the Dockerfile no longer references deleted deps**

```bash
grep -n "python\|cfssl\|openssl\|pip" homelab-pki/Dockerfile
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add homelab-pki/Dockerfile
git commit -m "chore(homelab-pki): strip cfssl/openssl/python from the image, tofu-only"
```

---

### Task 3: `main.tf` + `locals.tf` — provider/backend config and native device data

**Files:**
- Modify: `homelab-pki/tofu/main.tf` (rewrite)
- Create: `homelab-pki/tofu/locals.tf`
- Delete: `homelab-pki/tofu/variables.tf` (superseded — no external tfvars input anymore)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `local.users`, `local.devices` (map, keyed by device name, each value = merged identity + `key`/`ekus`), `local.device_domain`, `local.device_validity`, `local.device_attributes` (map, keyed by device name, each value = ordered list of `{oid, value}`), `local.revoked_serials` (list). Required providers `kubernetes` and `pki` registered for Tasks 4–6 to use.

- [ ] **Step 1: Delete the old `variables.tf`**

```bash
git rm homelab-pki/tofu/variables.tf
```

- [ ] **Step 2: Replace the full contents of `homelab-pki/tofu/main.tf`**

```hcl
# homelab-pki/tofu/main.tf
terraform {
  required_version = ">= 1.11.0"

  backend "kubernetes" {
    secret_suffix     = "homelab-pki"
    namespace         = "homelab-pki"
    in_cluster_config = true
  }

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    pki = {
      source  = "registry.terraform.io/nijave/pki"
      version = "~> 1.0"
    }
  }
}

provider "kubernetes" {}
provider "pki" {}
```

- [ ] **Step 3: Create `homelab-pki/tofu/locals.tf`**

```hcl
# homelab-pki/tofu/locals.tf
#
# Devices/identities are native Terraform data, not a separate config.hcl +
# ConfigMap (that required hand-syncing two copies of the same data).
# Adding or removing a device means editing this file and rebuilding the
# image (see homelab-pki/README.md).

locals {
  users = {
    nick = {
      key  = { algorithm = "RSA", size = 2048 }
      ekus = ["clientAuth"]
      identity = {
        surname                    = "Venenga"
        given_name                 = "Nick"
        display_name               = "Nick V"
        organization               = "homelab"
        uid                        = "nick"
        primary_email              = "nick@venenga.com"
        additional_email_addresses = ["nijave@gmail.com"]
      }
      devices = ["nick-desktop", "nick-ipad", "nick-xps", "pixel7"]
    }
    kara = {
      key  = { algorithm = "RSA", size = 2048 }
      ekus = ["clientAuth"]
      identity = {
        surname       = "Gilmore"
        given_name    = "Kara"
        display_name  = "Kara G"
        organization  = "homelab"
        uid           = "kara"
        primary_email = "karakgilmore@gmail.com"
      }
      devices = ["kara-iphone"]
    }
  }

  # Flatten users -> devices to device name -> merged identity + key/ekus,
  # so for_each can key on a stable identifier (device name) instead of a
  # provider-computed value like serial number.
  devices = merge([
    for uname, u in local.users : {
      for d in u.devices : d => merge(u.identity, {
        user = uname
        key  = u.key
        ekus = u.ekus
      })
    }
  ]...)

  device_domain   = "ha.apps.somemissing.info"
  device_validity = "175320h" # 20 years, matching the existing certificates

  # Ordered DN attribute list per device (commonName, uid, displayName,
  # givenName, surname, organization, then any organizationalUnits) --
  # order matters for byte-identical import; skips unset optional fields.
  device_attributes = {
    for name, d in local.devices : name => concat(
      [{ oid = "commonName", value = lookup(d, "common_name", "${name}.${local.device_domain}") }],
      lookup(d, "uid", null) != null ? [{ oid = "uid", value = d.uid }] : [],
      lookup(d, "display_name", null) != null ? [{ oid = "displayName", value = d.display_name }] : [],
      lookup(d, "given_name", null) != null ? [{ oid = "givenName", value = d.given_name }] : [],
      lookup(d, "surname", null) != null ? [{ oid = "surname", value = d.surname }] : [],
      lookup(d, "organization", null) != null ? [{ oid = "organization", value = d.organization }] : [],
      [for ou in lookup(d, "organizational_units", []) : { oid = "organizationalUnit", value = ou }]
    )
  }

  # Revoke a device: add { serial_number = "<serial>", reason = "..." } here
  # (look up the current serial via `tofu output device_serials`), then
  # rebuild/push/apply. See homelab-pki/README.md.
  revoked_serials = []
}
```

- [ ] **Step 4: Validate syntax/types locally (no cluster access needed)**

```bash
cd homelab-pki/tofu && tofu init -backend=false -no-color && tofu validate -no-color
```

Expected: `Success! The configuration is valid.` (At this point only `main.tf`/`locals.tf` exist — a bare `terraform`/`provider`/`locals` block with no resources is valid on its own.)

- [ ] **Step 5: Commit**

```bash
git add homelab-pki/tofu/main.tf homelab-pki/tofu/locals.tf
git rm homelab-pki/tofu/variables.tf 2>/dev/null || true
git commit -m "feat(homelab-pki): add pki provider + native locals, replacing variables.tf/config.hcl"
```

---

### Task 4: `ca.tf` — CA data source + `pki_certificate_authority` resource

**Files:**
- Create: `homelab-pki/tofu/ca.tf`

**Interfaces:**
- Consumes: nothing beyond `main.tf`'s providers.
- Produces: `pki_certificate_authority.ca` (consumed by Tasks 5 and 6 as `pki_certificate_authority.ca.certificate_pem` / `.private_key_pem`), output `ca_certificate_pem`.

- [ ] **Step 1: Create `homelab-pki/tofu/ca.tf`**

```hcl
# homelab-pki/tofu/ca.tf
#
# The CA cert+key are delivered from Bitwarden via ExternalSecret into the
# `pki-ca` Secret (never in git, never regenerated) -- see homelab-pki.yaml.
# Imported once (see the migration procedure in the design spec); this
# resource never re-signs the CA itself.
data "kubernetes_secret" "ca" {
  metadata {
    name      = "pki-ca"
    namespace = "homelab-pki"
  }
}

resource "pki_certificate_authority" "ca" {
  private_key_pem = base64decode(data.kubernetes_secret.ca.binary_data["tls.key"])

  validity      = "175320h"
  serial_number = "4d71d760878eb0a8831ce2e1d6028f61f1fc7d5f"

  subject {
    attribute {
      oid   = provider::pki::oid("organizationalUnit")
      value = "apps"
    }
    attribute {
      oid   = provider::pki::oid("organization")
      value = "homelab"
    }
  }

  # Declared explicitly even though they equal this resource's own defaults:
  # ImportState always populates these blocks from the real certificate's
  # extensions, so an omitted block plans as null -- a block-shape mismatch,
  # not a no-op -- and would force a reissue with a fresh not_before.
  basic_constraints {
    ca       = true
    critical = true
  }

  key_usage {
    critical = true
    usages   = ["keyCertSign", "crlSign"]
  }

  name_constraints {
    permitted_dns_domains = ["ha.apps.somemissing.info", ".ha.apps.somemissing.info"]
  }
}

output "ca_certificate_pem" {
  value = pki_certificate_authority.ca.certificate_pem
}
```

- [ ] **Step 2: Validate**

```bash
cd homelab-pki/tofu && tofu validate -no-color
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add homelab-pki/tofu/ca.tf
git commit -m "feat(homelab-pki): import CA as a managed pki_certificate_authority resource"
```

---

### Task 5: `devices.tf` — per-device key/cert/PKCS12/Secret via `for_each`

**Files:**
- Create: `homelab-pki/tofu/devices.tf`

**Interfaces:**
- Consumes: `local.devices`, `local.device_attributes`, `local.device_domain`, `local.device_validity` (Task 3); `pki_certificate_authority.ca` (Task 4).
- Produces: `pki_private_key.device[*]`, `pki_certificate.device[*]`, `pki_bundle.device[*]`, `kubernetes_secret.device[*]`, output `device_serials` (consumed by the revocation runbook in Task 8).

- [ ] **Step 1: Create `homelab-pki/tofu/devices.tf`**

```hcl
# homelab-pki/tofu/devices.tf
resource "pki_private_key" "device" {
  for_each = local.devices

  algorithm = each.value.key.algorithm
  rsa_bits  = each.value.key.size
}

resource "pki_certificate" "device" {
  for_each = local.devices

  ca_certificate_pem = pki_certificate_authority.ca.certificate_pem
  ca_private_key_pem = pki_certificate_authority.ca.private_key_pem
  public_key_pem     = pki_private_key.device[each.key].public_key_pem

  validity = local.device_validity

  subject {
    dynamic "attribute" {
      for_each = local.device_attributes[each.key]
      content {
        oid   = provider::pki::oid(attribute.value.oid)
        value = attribute.value.value
      }
    }
  }

  san {
    dns_names = ["${each.key}.${local.device_domain}"]
    email_addresses = compact(concat(
      [lookup(each.value, "primary_email", "")],
      lookup(each.value, "additional_email_addresses", [])
    ))
  }

  # Declared explicitly -- see the comment on pki_certificate_authority.ca in
  # ca.tf for why (applies to every imported device cert; harmless for new
  # ones created fresh, since a create has no prior state to mismatch).
  basic_constraints {
    ca       = false
    critical = true
  }

  key_usage {
    usages = ["digitalSignature", "keyEncipherment"]
  }

  extended_key_usage {
    usages = each.value.ekus
  }
}

resource "pki_bundle" "device" {
  for_each = local.devices

  format          = "pkcs12"
  certificate_pem = pki_certificate.device[each.key].certificate_pem
  private_key_pem = pki_private_key.device[each.key].private_key_pem
  chain_pem       = [pki_certificate_authority.ca.certificate_pem]
  friendly_name   = each.key

  # Write-only: preserves the current (non-secret) hardcoded password
  # exactly -- never stored in state.
  password_wo         = "password"
  password_wo_version = 1
}

resource "kubernetes_secret" "device" {
  for_each = local.devices

  metadata {
    name      = "pki-${each.key}"
    namespace = "homelab-pki"
    labels = {
      "pki/name"   = each.key
      "pki/serial" = pki_certificate.device[each.key].serial_number
    }
  }

  binary_data = {
    "tls.crt"         = base64encode(pki_certificate.device[each.key].certificate_pem)
    "tls.key"         = base64encode(pki_private_key.device[each.key].private_key_pem)
    "${each.key}.p12" = pki_bundle.device[each.key].content_base64
  }
  type = "Opaque"
}

# Look up a device's current serial for revocation: `tofu output device_serials`.
output "device_serials" {
  value = { for name, cert in pki_certificate.device : name => cert.serial_number }
}
```

- [ ] **Step 2: Validate**

```bash
cd homelab-pki/tofu && tofu validate -no-color
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add homelab-pki/tofu/devices.tf
git commit -m "feat(homelab-pki): issue per-device certs/PKCS12/Secrets via for_each"
```

---

### Task 6: `crl.tf` — CRL generation and its Secret

**Files:**
- Create: `homelab-pki/tofu/crl.tf`

**Interfaces:**
- Consumes: `local.revoked_serials` (Task 3); `pki_certificate_authority.ca` (Task 4).
- Produces: `pki_crl.ca`, `kubernetes_secret.crl`.

- [ ] **Step 1: Create `homelab-pki/tofu/crl.tf`**

```hcl
# homelab-pki/tofu/crl.tf
resource "pki_crl" "ca" {
  ca_certificate_pem = pki_certificate_authority.ca.certificate_pem
  ca_private_key_pem = pki_certificate_authority.ca.private_key_pem

  next_update = "168h"

  dynamic "revoked" {
    for_each = local.revoked_serials
    content {
      serial_number = revoked.value.serial_number
      reason        = lookup(revoked.value, "reason", null)
      revoked_at    = lookup(revoked.value, "revoked_at", null)
    }
  }
}

resource "kubernetes_secret" "crl" {
  metadata {
    name      = "pki-crl"
    namespace = "homelab-pki"
  }

  binary_data = { "crl.pem" = pki_crl.ca.crl_base64 }
  type        = "Opaque"
}
```

- [ ] **Step 2: Validate the full config and check formatting**

```bash
cd homelab-pki/tofu && tofu validate -no-color && tofu fmt -check -recursive
```

Expected: `Success! The configuration is valid.` and no output from `tofu fmt -check` (exit 0 means already formatted; if it lists files, run `tofu fmt -recursive` to fix and re-check).

- [ ] **Step 3: Commit**

```bash
git add homelab-pki/tofu/crl.tf
git commit -m "feat(homelab-pki): generate CRL and its Secret via pki_crl"
```

---

### Task 7: Update `homelab-pki.yaml` — drop ConfigMap/volumes, collapse Job/CronJob commands

**Files:**
- Modify: `homelab-pki.yaml` (full rewrite)

**Interfaces:**
- Consumes: nothing (manifest-only change; image tag bumped to `0.2.0` to match Task 2's Dockerfile comment).
- Produces: the deployed Job/CronJob that will run the new `tofu/*.tf` config once the new image is built/pushed (image build/push itself is a manual, out-of-agent step — see the design spec's migration procedure).

- [ ] **Step 1: Replace the full contents of `homelab-pki.yaml`**

```yaml
# Declarative mTLS client-cert PKI for Home Assistant.
#
# A single image (registry.apps.nickv.me/nijave/homelab-pki) bundles OpenTofu
# + the tofu/ config: pki_certificate_authority/pki_certificate/pki_crl/etc.
# (nijave/pki provider) express the CA import, per-device issuance, and CRL
# generation declaratively -- `tofu apply` alone reconciles everything
# (adding/removing a device is a for_each over the device map in
# homelab-pki/tofu/locals.tf, no separate reconciler needed). State lives in
# the kubernetes backend (a Secret).
#
# The reconcile Job is an Argo Sync hook (runs `tofu apply` on each sync); the
# CronJob re-runs periodically to keep the CRL fresh. Reconciliation is
# idempotent. The CA private key is delivered from Bitwarden via ExternalSecret
# and read directly by homelab-pki/tofu/ca.tf via a kubernetes_secret data
# source (no volume mount needed); cert/CRL Secrets are tofu-managed (not
# Argo-pruned).
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pki-reconciler
  namespace: homelab-pki
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pki-crl-reader
  namespace: projectcontour
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pki-reconciler
  namespace: homelab-pki
rules:
  # cert/CRL Secrets + reading pki-ca + the OpenTofu kubernetes-backend state
  # Secret.
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  # OpenTofu kubernetes-backend state lock.
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pki-crl-reader
  namespace: homelab-pki
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["pki-crl"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pki-reconciler
  namespace: homelab-pki
subjects:
  - kind: ServiceAccount
    name: pki-reconciler
    namespace: homelab-pki
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pki-reconciler
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pki-crl-reader
  namespace: homelab-pki
subjects:
  - kind: ServiceAccount
    name: pki-crl-reader
    namespace: projectcontour
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pki-crl-reader
---
# CA cert+key delivered from Bitwarden (ha-ca-crt / ha-ca-key). Opaque, read
# directly by homelab-pki/tofu/ca.tf's kubernetes_secret data source. Never
# in git.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pki-ca
  namespace: homelab-pki
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    name: pki-ca
  data:
    # conversionStrategy/decodingStrategy/metadataPolicy are CRD defaults spelled
    # out explicitly: Argo owns spec.data as an atomic list and diffs
    # client-side, so omitting them reads as permanent drift.
    - secretKey: tls.crt
      remoteRef:
        key: ha-ca-crt
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: tls.key
      remoteRef:
        key: ha-ca-key
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
---
# Immediate reconcile: Argo Sync hook runs `tofu apply` on each sync (idempotent).
apiVersion: batch/v1
kind: Job
metadata:
  name: pki-reconcile
  namespace: homelab-pki
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 86400
  template:
    spec:
      restartPolicy: Never
      serviceAccountName: pki-reconciler
      containers:
        - name: reconcile
          image: registry.apps.nickv.me/nijave/homelab-pki:0.2.0
          imagePullPolicy: Always
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eux
              cd /app/tofu
              tofu init -input=false -no-color
              tofu apply -input=false -auto-approve -no-color
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { cpu: "1", memory: 512Mi }
---
# Periodic re-run to keep the CRL fresh (regenerate before nextUpdate) and
# correct any drift. concurrencyPolicy Forbid; the OpenTofu state lock also
# guards against overlap with the Sync-hook Job.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pki-crl-refresh
  namespace: homelab-pki
spec:
  schedule: "0 */6 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      ttlSecondsAfterFinished: 86400
      template:
        spec:
          restartPolicy: Never
          serviceAccountName: pki-reconciler
          containers:
            - name: reconcile
              image: registry.apps.nickv.me/nijave/homelab-pki:0.2.0
              imagePullPolicy: Always
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eux
                  cd /app/tofu
                  tofu init -input=false -no-color
                  tofu apply -input=false -auto-approve -no-color
              resources:
                requests: { cpu: 50m, memory: 128Mi }
                limits: { cpu: "1", memory: 512Mi }
```

(Note what's gone versus the current file: the `pki-config` ConfigMap, both containers' `env` blocks — `PKI_NAMESPACE`/`PKI_CONFIG`/`CA_CERT`/`CA_KEY`/`HOME` — and both containers' `volumes`/`volumeMounts` — `config`, `ca`, `work`. Nothing needs to be mounted anymore: config is baked into the image as `.tf`, the CA is read via the `kubernetes_secret` data source, and there's no intermediate `secrets.auto.tfvars.json` file to stage.)

- [ ] **Step 2: Confirm the Job/CronJob no longer reference deleted volumes/env, then run this repo's real manifest validator**

```bash
grep -n "pki-config\|PKI_CONFIG\|CA_CERT\|CA_KEY\|volumeMounts\|volumes:" homelab-pki.yaml
```

Expected: no output.

```bash
sh .ci/validate.sh
```

This is the same `kubeconform` validation CI runs (`.ci/validate.sh`, wired up in `.woodpecker.yaml`'s `validate` step) — it schema-checks every hand-written manifest including `homelab-pki.yaml`, so it also verifies the YAML parses. (A `PreToolUse`/`PostToolUse` hook in this session already runs kubeconform automatically on file edits — if its output already showed this file passing, this step is a confirmation, not new information.)

- [ ] **Step 3: Commit**

```bash
git add homelab-pki.yaml
git commit -m "chore(homelab-pki): drop ConfigMap/CA volume, collapse Job/CronJob to plain tofu apply"
```

---

### Task 8: `homelab-pki/README.md` — validation, add/remove device, rotation/revocation runbook

**Files:**
- Create: `homelab-pki/README.md`

**Interfaces:**
- Consumes: nothing (documentation only).
- Produces: operator-facing documentation referenced by the design spec's migration procedure.

- [ ] **Step 1: Create `homelab-pki/README.md`**

```markdown
# homelab-pki

Declarative Home Assistant mTLS client-cert PKI. `tofu/` holds the entire
desired state: CA import (`ca.tf`), per-device key/cert/PKCS12 issuance
(`devices.tf`, `locals.tf`), and CRL generation (`crl.tf`), all using the
[`nijave/pki`](https://registry.terraform.io/providers/nijave/pki) provider.
`homelab-pki.yaml`'s Job (Argo Sync hook) and CronJob (`pki-crl-refresh`,
every 6h) both just run `tofu init && tofu apply` against this config --
adding or removing a device is a `for_each` over `local.devices` in
`locals.tf`, no separate reconciler step.

## Local validation

From `homelab-pki/tofu/`:

\`\`\`sh
tofu init -backend=false
tofu validate
tofu fmt -check -recursive
\`\`\`

This checks syntax/types without touching the cluster (`-backend=false`
skips the kubernetes backend; data sources like `data.kubernetes_secret.ca`
aren't evaluated by `validate`, only by `plan`/`apply`).

## Adding or removing a device

Edit `local.users`/`local.devices` in `locals.tf`, rebuild and push the
image (`docker build`/`push`, bump the tag), update the tag in
`homelab-pki.yaml`. Argo picks it up on next sync; the Sync-hook Job's
`tofu apply` creates/destroys the corresponding `pki_private_key`/
`pki_certificate`/`pki_bundle`/`kubernetes_secret` resources.

## Revoking a device (lost/sold)

1. Find its current serial: `tofu output device_serials` (or the
   `pki/serial` label on its `pki-<device>` Secret).
2. Add `{ serial_number = "<serial>", reason = "cessationOfOperation" }` to
   `local.revoked_serials` in `locals.tf`.
3. Rebuild/push/apply. `pki_crl.ca` updates in place (CRL number
   increments) -- the device's own cert/Secret are untouched (still valid,
   just now CRL-listed).

## Rotating a device's key/cert

Routine rotation, or reissuing after revoking a lost device:

\`\`\`sh
tofu apply -replace='pki_private_key.device["<name>"]'
\`\`\`

This forces a new key, cascading to a new `pki_certificate` (new
provider-assigned serial), new `pki_bundle` content, and an in-place update
of the same `pki-<name>` Secret (same name -- no orphaned old Secret). If the
rotation is security-motivated, also add the *old* serial to
`revoked_serials` per the revocation steps above.

## One-time CA/device import

Already performed for the existing CA and 5 devices (`nick-desktop`,
`nick-ipad`, `nick-xps`, `pixel7`, `kara-iphone`) -- see
`docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md`
for the full cutover procedure and
`~/Documents/workspace/go/src/github.com/nijave/terraform-provider-pki/migration/homelab-pki-import/`
for the validation run that proved it byte-identical against the real CA and
certs.
```

- [ ] **Step 2: Commit**

```bash
git add homelab-pki/README.md
git commit -m "docs(homelab-pki): add validation, add/remove device, rotation/revocation runbook"
```

---

### Task 9: Final full-config validation

**Files:**
- None created/modified — this task only verifies the combined output of Tasks 1–8.

**Interfaces:**
- Consumes: the complete `homelab-pki/tofu/*.tf` from Tasks 3–6 and `homelab-pki/Dockerfile`/`homelab-pki.yaml` from Tasks 2 and 7.
- Produces: confidence that the whole rewrite is internally consistent before handing off to the (separate, manual) production cutover procedure.

- [ ] **Step 1: Full validate + format check from a clean `tofu init`**

```bash
cd homelab-pki/tofu
rm -rf .terraform .terraform.lock.hcl
tofu init -backend=false -no-color
tofu validate -no-color
tofu fmt -check -recursive
```

Expected: `Success! The configuration is valid.`, no `fmt` output.

- [ ] **Step 2: Confirm the final file layout matches the design**

```bash
ls homelab-pki/tofu/
```

Expected: exactly `main.tf`, `locals.tf`, `ca.tf`, `devices.tf`, `crl.tf` (no `variables.tf`, no leftover `.terraform/`/`.terraform.lock.hcl` — those are gitignored per Task 1 but shouldn't be staged).

```bash
git status --porcelain homelab-pki/
```

Expected: clean (everything from Tasks 1–8 already committed; no stray untracked files besides what `.gitignore` already covers).

- [ ] **Step 3: Confirm no dangling references to the deleted reconciler anywhere in the repo**

```bash
grep -rln "reconcile\.\|python-hcl2\|cfssl\|PKI_CONFIG" --include="*.yaml" --include="*.tf" --include="Dockerfile" .
```

Expected: no output.

- [ ] **Step 4: Final commit (if Step 1's clean re-init or any fixes produced changes)**

```bash
git add homelab-pki/
git status --porcelain homelab-pki/ | grep -q . && git commit -m "chore(homelab-pki): final tofu fmt/validate pass" || echo "nothing to commit"
```

---

## Not covered by this plan (deliberately)

The one-time manual import of the real CA and 5 real devices into these new resource addresses, and the staged cutover that removes the old `pki-<name>-<serial>` Secrets, is **not** a task here — it requires live cluster access and irreversible state changes against production key material. Follow the "Migration / cutover procedure" section of
`docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md` manually once Tasks 1–9 are merged and the new image is built and pushed.
