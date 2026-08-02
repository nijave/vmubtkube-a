# homelab-pki

Declarative Home Assistant mTLS client-cert PKI. `tofu/` holds the entire
desired state: CA import (`ca.tf`), per-device key/cert/PKCS12 issuance
(`devices.tf`, `locals.tf`), and CRL generation (`crl.tf`), all using the
[`nijave/pki`](https://registry.terraform.io/providers/nijave/pki) provider.
`homelab-pki.yaml`'s Job (Argo Sync hook) and CronJob (`pki-crl-refresh`,
every 6h) both run `tofu init` then one `tofu` command against this config --
adding or removing a device is a `for_each` over `local.devices` in
`locals.tf`, no separate reconciler step.

**Staged cutover in progress:** both containers currently run `tofu plan`
only, not `apply` -- see "One-time CA/device import" below. Once the plan
looks right, a follow-up change flips them to `tofu apply -auto-approve`.

## Local validation

From `homelab-pki/tofu/`:

```sh
tofu init -backend=false
tofu validate
tofu fmt -check -recursive
```

This checks syntax/types without touching the cluster (`-backend=false`
skips the kubernetes backend; data sources like `data.kubernetes_secret.ca`
aren't evaluated by `validate`, only by `plan`/`apply`).

## Adding or removing a device

Edit `local.users`/`local.devices` in `locals.tf`, rebuild and push the
image (`docker build`/`push`, bump the tag), update the tag in
`homelab-pki.yaml`. Argo picks it up on next sync; the Sync-hook Job's
`tofu` run creates/destroys the corresponding `pki_private_key`/
`pki_certificate`/`pki_bundle`/`kubernetes_secret` resources (once the
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

**Not yet performed against this repo's `homelab-pki` namespace.** The import
*approach* (mechanics of bringing the existing CA and 5 devices --
`nick-desktop`, `nick-ipad`, `nick-xps`, `pixel7`, `kara-iphone` -- under
these resource addresses) was validated byte-identical against the real CA
and certs in a separate harness:
`~/Documents/workspace/go/src/github.com/nijave/terraform-provider-pki/migration/homelab-pki-import/`.
That run proved the approach works, but it did not touch production.

The actual production cutover is driven by `tofu/imports.tf` -- declarative
`import` blocks (no manual `terraform import` CLI commands, no one-off pod)
that bind the CA and 5 devices' existing keys/certs into this config's
resource addresses. Rollout is staged across three changes:

1. **This state:** `imports.tf` is in config, and the Job/CronJob run
   `tofu plan` only. Safe to merge/deploy as-is -- review the plan in
   `kubectl logs job/pki-reconcile -n homelab-pki`; expect "N to import",
   the one-time `private_key_pem` pending-set, and creates for the new
   `pki-<device>`/`pki-crl` Secrets, no unexpected reissues.
2. Once that plan looks right, flip the Job/CronJob command to
   `tofu apply -auto-approve`. One apply imports the CA/devices, destroys
   the now-orphaned old `pki-<name>-<serial>` Secrets, and creates the new
   ones -- atomically and safely (see the design spec for why the ordering
   can't race).
3. Immediately after that apply succeeds, delete `tofu/imports.tf` and
   `locals.tf`'s `legacy_device_secrets` map. Their data sources read
   Secrets that apply just destroyed -- left in place, every later
   plan/apply (including the CronJob's next run) fails.

Full detail in the "Migration / cutover procedure" section of
`docs/superpowers/specs/2026-08-01-homelab-pki-provider-migration-design.md`.
