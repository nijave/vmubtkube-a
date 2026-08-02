# homelab-pki

Declarative Home Assistant mTLS client-cert PKI. `tofu/` holds the entire
desired state: CA import (`ca.tf`), per-device key/cert/PKCS12 issuance
(`devices.tf`, `locals.tf`), and CRL generation (`crl.tf`), all using the
[`nijave/pki`](https://registry.terraform.io/providers/nijave/pki) provider.
`homelab-pki.yaml`'s Job (Argo Sync hook) and CronJob (`pki-crl-refresh`,
every 6h) both run `tofu init` then one `tofu` command against this config --
adding or removing a device is a `for_each` over `local.devices` in
`locals.tf`, no separate reconciler step.

**Staged cutover, phase 2 of 3 in progress:** both containers now run
`tofu apply -auto-approve` -- phase 1's `tofu plan` run showed exactly the
expected diff (11 to import, 12 to add, 6 to change, 6 to destroy, no
unexpected reissues). See "One-time CA/device import" below for what this
apply does and the required phase 3 follow-up.

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

## One-time CA/device import

The production cutover is driven by `tofu/imports.tf` -- declarative
`import` blocks (no manual `terraform import` CLI commands, no one-off pod)
that bind the real CA and 5 real devices' existing keys/certs
(`nick-desktop`, `nick-ipad`, `nick-xps`, `pixel7`, `kara-iphone`) into this
config's resource addresses. The import *mechanism* was validated
byte-identical against the real CA and certs in a separate harness before
being written into this config:
`~/Documents/workspace/go/src/github.com/nijave/terraform-provider-pki/migration/homelab-pki-import/`.
Rollout is staged across three changes:

1. `imports.tf` shipped with the Job/CronJob running `tofu plan` only.
   Reviewed in `kubectl logs job/pki-reconcile -n homelab-pki`: exactly the
   expected diff (11 to import, 12 to add, 6 to change -- the documented
   one-time pending-sets -- 6 to destroy -- the old `pki-<name>-<serial>`
   Secrets and old CRL Secret -- no unexpected reissues). Done.
2. **This state:** the Job/CronJob command is now `tofu apply
   -auto-approve`. One apply imports the CA/devices, destroys the
   now-orphaned old Secrets, and creates the new `pki-<device>`/`pki-crl`
   ones -- atomically and safely (see the design spec for why the ordering
   can't race).
3. **Required follow-up, promptly after this apply succeeds once** (before
   the CronJob's next 6-hourly run): delete `tofu/imports.tf`,
   `locals.tf`'s `legacy_device_secrets` map, and the `legacy-*`
   volumes/volumeMounts in `homelab-pki.yaml`. They reference Secrets this
   apply destroys -- left in place, every later plan/apply fails.

Full detail in the "Migration / cutover procedure" section of
`docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md`.
