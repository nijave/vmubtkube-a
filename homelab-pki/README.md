# homelab-pki

Declarative Home Assistant mTLS client-cert PKI. `tofu/` holds the entire
desired state: CA import (`ca.tf`), per-device key/cert/PKCS12 issuance
(`devices.tf`, `locals.tf`), and CRL generation (`crl.tf`), all using the
[`nijave/pki`](https://registry.terraform.io/providers/nijave/pki) provider.
`homelab-pki.yaml`'s Job (Argo Sync hook) and CronJob (`pki-crl-refresh`,
every 6h) both run `tofu init` then one `tofu` command against this config --
adding or removing a device is a `for_each` over `local.devices` in
`locals.tf`, no separate reconciler step.

Both containers run `tofu apply -auto-approve`. The one-time cutover onto
this provider is complete -- see "One-time CA/device import" below.

## Local validation

From `homelab-pki/tofu/`:

```sh
tofu init -backend=false
tofu validate
tofu fmt -check -recursive
```

This checks syntax/types without touching the cluster (`-backend=false`
skips the kubernetes backend; data sources like `data.kubernetes_secret_v1.ca`
aren't evaluated by `validate`, only by `plan`/`apply`).

## Adding or removing a device

Edit `local.users`/`local.devices` in `locals.tf`, rebuild and push the
image (`docker build`/`push`, bump the tag), update the tag in
`homelab-pki.yaml`. Argo picks it up on next sync; the Sync-hook Job's
`tofu` run creates/destroys the corresponding `pki_private_key`/
`pki_certificate`/`pki_bundle`/`kubernetes_secret_v1` resources (once the
staged cutover below has flipped the Job to `apply` -- while it's still in
`plan` mode, this only shows up in the plan output, not the cluster).

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

```sh
tofu apply -replace='pki_private_key.device["<name>"]'
```

This forces a new key, cascading to a new `pki_certificate` (new
provider-assigned serial), new `pki_bundle` content, and an in-place update
of the same `pki-<name>` Secret (same name -- no orphaned old Secret). If the
rotation is security-motivated, also add the *old* serial to
`revoked_serials` per the revocation steps above.

## One-time CA/device import (complete)

The production cutover onto this provider is done. The real CA and 5 real
devices (`nick-desktop`, `nick-ipad`, `nick-xps`, `pixel7`, `kara-iphone`)
were imported byte-identically via a now-removed `tofu/imports.tf`
(declarative `import` blocks, no manual `terraform import` CLI commands, no
one-off pod) -- `Apply complete! Resources: 11 imported, 12 added, 6
changed, 6 destroyed.` -- confirmed against the live cluster with `openssl
verify` (a real device cert validates against the real CA, serial preserved
exactly). The import *mechanism* was validated in a separate harness before
being written into this config:
`~/Documents/workspace/go/src/github.com/nijave/terraform-provider-pki/migration/homelab-pki-import/`.

Full detail (the staged rollout, the two import gotchas, why the old
Secrets could be destroyed safely in the same apply) is in the "Migration /
cutover procedure" section of
`docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md`,
kept as a record of what happened.
