# Migrate homelab-pki onto terraform-provider-pki

**Date**: 2026-08-01
**Status**: Design — not yet implemented

---

## Problem

`homelab-pki` (this repo, `homelab-pki/`) currently provisions Home Assistant
mTLS client certs via a two-phase pipeline: a Python reconciler
(`homelab-pki/reconcile/*.py`) shells out to `openssl`/`cfssl` to compute a
create/keep/delete plan and mint cert bytes, then OpenTofu — using only
`hashicorp/kubernetes ~> 3.0` — writes the results into `kubernetes_secret`
objects. The reconciler exists solely because vanilla Terraform can't express
"keep an arbitrary set of existing certs, add/remove by identity" without a
pre-step that computes the plan imperatively.

`nijave/terraform-provider-pki` (a new, purpose-built Terraform/OpenTofu
provider, `~/Documents/workspace/go/src/github.com/nijave/terraform-provider-pki`)
closes that gap: `pki_certificate`/`pki_certificate_authority`/`pki_crl`/etc.
are real resources, so `for_each` over a native map gives "keep an arbitrary
set, add/remove by identity" for free — no reconciler needed. The provider is
published (`v1.0.0`, Terraform Registry; OpenTofu registry PR pending), and a
validation run (`terraform-provider-pki/migration/homelab-pki-import/`)
already imported this cluster's real CA and all 5 real device certs with zero
plan drift, issued and revoked a test cert, and proved the provider's CRL
generation fixes a **real production bug**: the current cfssl-generated CRL
encodes its issuer DN in the wrong attribute order (`O=homelab, OU=apps` vs.
the CA's actual `OU=apps, O=homelab`), so `openssl verify -crl_check` fails
against every real leaf cert today.

This spec covers rewriting `homelab-pki` onto the provider: delete
`reconcile/`, strip `cfssl`/`openssl`/`python` from the Dockerfile, express
devices/CA/CRL as native Terraform resources, and collapse the two-phase
apply into one.

## Scope

**In scope**

- Rewrite `homelab-pki/tofu/*.tf` to use `pki_*` resources for CA import,
  per-device key/cert/PKCS12 issuance, and CRL generation.
- Replace `config.hcl` + the `pki-config` ConfigMap (a documented
  hand-sync-required duplication) with native Terraform locals.
- Strip the Python reconciler and its runtime deps (`cfssl`, `openssl`,
  `python3`, `python-hcl2`, `kubernetes` client) from the image.
- Collapse the Job/CronJob command to a single `tofu init && tofu apply`.
- One-time manual import of the real CA + 5 real device certs/keys into the
  new resource addresses, preserving them byte-identically (no reissue).
- Document the new rotation/revocation runbook (serial is now
  provider-auto-assigned, not reconciler-assigned).

**Out of scope**

- CA rotation/regeneration (CA is imported once, never regenerated — same as
  today).
- Automating the one-time import into a Job (deliberately manual — see
  Migration procedure).
- Any change to `cert-manager` / `clusterissuer.yaml` / the DNSimple
  ACME issuers (a fully separate system, not touched by this migration).
- Wiring `HA_CRL` into `python-envoy-authz` or adding `crlSecret` to
  `proxy_homeassistant.yaml`'s `clientValidation` (tracked separately; this
  migration only changes how the CRL Secret is *produced*, not how it's
  consumed).

## Architecture

```
                 ┌─────────────────────────────┐
                 │ data.kubernetes_secret.ca    │  (reads pki-ca, from Bitwarden
                 │  (tls.crt / tls.key)         │   via ExternalSecret, unchanged)
                 └──────────────┬───────────────┘
                                │
                 ┌──────────────▼───────────────┐
                 │ pki_certificate_authority.ca  │  imported once, never regenerated
                 └──────────────┬───────────────┘
                                │ ca_certificate_pem / ca_private_key_pem
              ┌─────────────────┼─────────────────────┐
              │                 │                      │
   ┌──────────▼─────────┐ ┌─────▼──────────┐  ┌────────▼────────┐
   │ pki_private_key     │ │ pki_certificate │  │ pki_crl.ca       │
   │ pki_certificate      │ │  for_each       │  │  revoked = local │
   │ pki_bundle (p12)     │ │  local.devices  │  │   .revoked_serials│
   │  for_each            │ └─────────────────┘  └────────┬─────────┘
   │  local.devices        │                               │
   └──────────┬───────────┘                                │
              │                                            │
   ┌──────────▼───────────┐                    ┌───────────▼──────────┐
   │ kubernetes_secret     │                    │ kubernetes_secret     │
   │  pki-<device>         │                    │  pki-crl              │
   │  (tls.crt/tls.key/    │                    │  (crl.pem)            │
   │   <device>.p12)       │                    └───────────────────────┘
   └───────────────────────┘
```

`homelab-pki/tofu/main.tf` keeps the `kubernetes` backend
(`secret_suffix: homelab-pki`, unchanged — state stays where it is) and adds
the new provider:

```hcl
terraform {
  required_version = ">= 1.11.0"
  backend "kubernetes" {
    secret_suffix     = "homelab-pki"
    namespace         = "homelab-pki"
    in_cluster_config = true
  }
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 3.0" }
    pki        = { source = "registry.terraform.io/nijave/pki", version = "~> 1.0" }
  }
}

provider "kubernetes" {}
provider "pki" {}
```

The fully-qualified `registry.terraform.io/nijave/pki` source is used instead
of the shorthand `nijave/pki` (which defaults to `registry.opentofu.org`)
because the OpenTofu registry PR adding this provider hasn't merged yet;
`tofu` can pull from any registry given a full host in the source address.
Both providers already download at Job runtime today (the current setup
already does this for `hashicorp/kubernetes`), so no filesystem mirror is
needed.

The CA is read via `data "kubernetes_secret" "ca"` (in-cluster,
`hashicorp/kubernetes` provider) instead of a mounted volume — this drops the
`/ca` volume mount and `CA_CERT`/`CA_KEY` env vars from the Job/CronJob spec
entirely.

## Config shape (`homelab-pki/tofu/locals.tf`)

Native locals replace `config.hcl` and the `pki-config` ConfigMap (which
required hand-syncing two copies of the same data — that pain point goes
away entirely, since config now lives only as `.tf` in the image):

```hcl
locals {
  users = {
    nick = {
      key = { algorithm = "RSA", size = 2048 }
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
      key      = { algorithm = "RSA", size = 2048 }
      ekus     = ["clientAuth"]
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

  # Flatten to device name -> merged identity + key/eku settings, so
  # for_each can key on a stable identifier (device name), not a
  # provider-computed value like serial.
  devices = merge([
    for uname, u in local.users : {
      for d in u.devices : d => merge(u.identity, {
        user = uname
        key  = u.key
        ekus = u.ekus
      })
    }
  ]...)

  # Revoke a device: add { serial_number = "<serial>", reason = "..." } here.
  # Look up the current serial via `tofu output device_serials`.
  revoked_serials = []
}
```

Each `pki_certificate`'s `subject`/`san` blocks use the **ordered `attribute`
form** (never named fields) — required for byte-identical import, since the
real DN order (`commonName, uid, displayName, givenName, surname,
organization`) doesn't match the schema's canonical named-field order. This is
built via a `dynamic "attribute"` block over a per-device ordered list that
skips unset optional identity fields, mirroring
`terraform-provider-pki/migration/homelab-pki-import/devices.tf` exactly.

`basic_constraints` and `key_usage` are declared explicitly on every
`pki_certificate_authority`/`pki_certificate` (the two documented import
gotchas from the validation run):

1. **Must declare `basic_constraints`/`key_usage` explicitly**, even when
   their values equal the resource's own defaults. `ImportState` always
   populates these blocks from the certificate's real X.509 extensions, so an
   omitted block in config plans as `null` — a block-shape mismatch, not a
   no-op — and would force a reissue with a fresh `not_before` on the
   settling apply.
2. **`private_key_pem` shows as a pending `+` (null → configured) on the
   first plan immediately after import.** Expected — the private key can't
   be recovered from a certificate alone. One `apply` clears it; the
   following `plan` is a genuine no-op. Doesn't reissue anything (confirmed
   by `id` staying identical across the settling apply).

Devices produce, per name: `pki_private_key`, `pki_certificate` (signed by
`pki_certificate_authority.ca`), `pki_bundle` (`format = "pkcs12"`, write-only
password fixed to the literal string `"password"` via `password_wo` —
preserves current behavior exactly, since that password isn't a real secret
today either), and `kubernetes_secret` (`tls.crt`, `tls.key`, `<name>.p12`).

An output exposes current serials for operators doing revocation:

```hcl
output "device_serials" {
  value = { for name, cert in pki_certificate.device : name => cert.id }
}
```

## Job / CronJob / Dockerfile changes

- **Dockerfile**: drop `python3`, `py3-pip`, `cfssl`/`cfssljson`,
  `python-hcl2`, `kubernetes` (python client), `pytest`. Keep only the `tofu`
  binary (same multi-stage copy from `ghcr.io/opentofu/opentofu:1.12-minimal`)
  and `ca-certificates`. `COPY tofu/ /app/tofu/` only — `reconcile/` and
  `cfssl/` directories are deleted from the repo.
- **Job (`pki-reconcile`, Argo Sync hook)** and **CronJob
  (`pki-crl-refresh`)**: both commands collapse to:
  ```sh
  set -eux
  cd /app/tofu
  tofu init -input=false -no-color
  tofu apply -input=false -auto-approve -no-color
  ```
  No `python -m reconcile.main`, no `secrets.auto.tfvars.json` copy step.
- **Volumes**: drop the `config` (ConfigMap) and `ca` (Secret) volume mounts
  and the `PKI_CONFIG`/`CA_CERT`/`CA_KEY` env vars — config is baked into the
  image as `.tf`, and the CA is read via `data "kubernetes_secret"` instead
  of a mounted file. `work` emptyDir can also go (no more
  `secrets.auto.tfvars.json` intermediate file).
- **RBAC**: unchanged — the existing `pki-reconciler` Role's secrets
  wildcard (`get/list/watch/create/update/patch/delete` on all Secrets in
  `homelab-pki`) already covers reading `pki-ca` and writing the new
  `pki-<device>`/`pki-crl` Secrets.
- **`pki-config` ConfigMap**: deleted from `homelab-pki.yaml` — config is now
  only in `.tf`, so adding/removing a device is an image rebuild, not a
  ConfigMap edit. (This is a deliberate trade of "edit a ConfigMap" for "edit
  `.tf` + rebuild image" — consistent with treating config as code now that
  there's no reconciler to read a mounted file at runtime.)

## Migration / cutover procedure

The existing kubernetes-backend state (`secret_suffix: homelab-pki`) only
contains `kubernetes_secret.cert[*]` (keyed `pki-<name>-<serial>`) and
`kubernetes_secret.crl[0]` — entirely different resource types/addresses than
the new config. A naive `tofu apply` against unmodified state would destroy
all 5+1 old secrets and create ~20 new resources with no guarantee the new
certs match the real CA/keys byte-for-byte. Instead, cutover is a **one-time
manual bootstrap**, run once, before the Job/CronJob are ever switched to the
new image:

1. Build and push the new `homelab-pki` image. Do **not** yet update the
   Job/CronJob manifests to reference it.
2. Run a one-off pod from that image (`kubectl run`/`exec`, same
   `pki-reconciler` ServiceAccount) against the same in-cluster kubernetes
   backend. Manually `terraform import` the CA and all 5 devices'
   `pki_certificate_authority`/`pki_private_key`/`pki_certificate`, following
   the exact procedure already proven in
   `terraform-provider-pki/migration/homelab-pki-import/fetch-secrets.sh`:
   extract each secret's `tls.crt`/`tls.key` via `kubectl get secret ... -o
   jsonpath=... | base64 -d`, then `terraform import <addr>
   file:///tmp/....crt` / `file:///tmp/....key`.
3. `tofu plan` should show only the expected one-time `private_key_pem`
   pending-set (gotcha #2 above) — no other diffs. If `basic_constraints`/
   `key_usage` show diffs, fix the config to match reality (gotcha #1) before
   applying. Apply once to settle.
4. Add the new (not imported) resources to config — `kubernetes_secret` per
   device, `pki_bundle` per device, `pki_crl`, `kubernetes_secret` for the
   CRL — and apply. This creates `pki-<device>` and `pki-crl` Secrets
   alongside the still-present old `pki-<device>-<serial>` ones.
5. Verify: `openssl verify -CAfile` the new CA output against each new
   device cert; `openssl verify -crl_check` a device cert against the new
   CRL (confirms the issuer-order fix actually applies in this cluster, not
   just in the validation harness).
6. The rewritten config (from step 1's image) never declares
   `kubernetes_secret.cert[*]`/`kubernetes_secret.crl[0]` (the old
   `variables.tf`-driven resources) in the first place, so they're already
   orphaned in state relative to config by this point. Apply once more (or
   `tofu state rm` first if a dry no-op plan is preferred before the
   destroy) to remove them — this is the step that actually deletes the old
   `pki-<name>-<serial>` Secrets, so do it only after step 5's verification
   passes.
7. Only then update the Job/CronJob manifests to the new image and
   collapsed command, and let Argo Sync take over ongoing `tofu apply`.

This keeps "old secrets go away" a deliberate, verified step rather than
folding a first-time import into an automated Sync-hook Job run.

## Rotation & revocation runbook

Since `serial_number` is now `Optional+Computed` (provider-assigned), a
device's current serial is only known after apply. Document this in
`homelab-pki/README.md`, replacing the old reconciler-based notes:

- **Revoke a device** (lost/sold): look up its current serial via `tofu
  output device_serials` (or the `pki/serial` label on its Secret — kept for
  at-a-glance identification even though it's no longer part of the Secret
  name). Add `{ serial_number = "<serial>", reason = "..." }` to
  `local.revoked_serials`, apply. `pki_crl.ca` updates in place (CRL number
  increments); the device's own cert/Secret are untouched — still valid,
  just now CRL-listed.
- **Rotate a device's key/cert** (routine rotation, or reissue after
  revoking a lost device): `tofu apply -replace='pki_private_key.device["<name>"]'`
  forces a new key, cascading to a new `pki_certificate` (new
  provider-assigned serial), new `pki_bundle` content, and an in-place
  update of the same `pki-<name>` Secret (same name — no orphaned old
  Secret to clean up, unlike the old serial-suffixed naming). If the
  rotation is security-motivated, also add the *old* serial to
  `revoked_serials`.

## Testing / validation

- No more `homelab-pki/reconcile/tests/*` (the code they test is deleted).
- Correctness for the CA/device import step is already established by
  `terraform-provider-pki/migration/homelab-pki-import/FINDINGS.md` (zero
  drift on all 6 imported resources, fresh-issuance and
  revocation/CRL-validation both proven against real cluster material).
- This migration's own verification is the cutover procedure's step 5
  (`openssl verify`/`openssl verify -crl_check` against the real new
  Secrets in this cluster) — a dry run in a scratch namespace is not
  practical here since the whole point is reusing the one real CA, so
  verification happens against production in the deliberate, staged
  procedure above rather than a separate test environment.

## Open follow-ups (explicitly not this spec)

- Wiring `HA_CRL` into `python-envoy-authz` and adding `crlSecret` to
  `proxy_homeassistant.yaml` — tracked in the original
  `2026-07-22-homelab-mtls-pki-design.md` plan, unaffected by this
  migration's change of *how* the CRL Secret is produced.
- Publishing to the OpenTofu registry (PR pending, outside this repo).
