# homelab-pki

Declarative Home Assistant mTLS client-cert PKI. `tofu/` holds the entire
desired state: CA import (`ca.tf`), per-device key/cert/PKCS12 issuance
(`devices.tf`, `locals.tf`), and CRL generation (`crl.tf`), all using the
[`nijave/pki`](https://registry.terraform.io/providers/nijave/pki) provider.

No baked image: the Sync-hook Job (`pki-reconcile`) and the CronJob
(`pki-crl-refresh`, every 6h) run the official `ghcr.io/opentofu/opentofu`
image. The config (`.tf` files plus the committed `.terraform.lock.hcl`)
ships as a kustomize-generated ConfigMap mounted read-only at `/config`;
`TF_DATA_DIR` and the plugin cache live on the `pki-tofu-cache` PVC, so
providers download once and never again on routine runs.

## Local validation

From `homelab-pki/tofu/`:

```sh
tofu init -backend=false
tofu validate
tofu fmt -check -recursive
```

`tofu init -backend=false` also refreshes `.terraform.lock.hcl` — commit it
together with any hand-edited `main.tf` provider-constraint change.
(Renovate's terraform manager updates constraint + lock file together in
its own PRs.)

## Adding or removing a device

Edit `local.users`/`local.devices` in `locals.tf`, commit, push. Argo
syncs the kustomize app (new ConfigMap hash → new Job spec) and the
Sync-hook Job's `tofu apply` creates/destroys the corresponding
`pki_private_key`/`pki_certificate`/`pki_bundle`/`kubernetes_secret_v1`
resources.

## Revoking a device (lost/sold)

1. Find its current serial: `tofu output device_serials` (or the
   `pki/serial` label on its `pki-<device>` Secret).
2. Add `{ serial_number = "<serial>", reason = "cessationOfOperation" }` to
   `local.revoked_serials` in `locals.tf`.
3. Commit/push. `pki_crl.ca` updates in place (CRL number increments) --
   the device's own cert/Secret are untouched (still valid, just now
   CRL-listed).

## Ad-hoc runs

- On-demand full reconcile:

  ```sh
  kubectl -n homelab-pki create job --from=cronjob/pki-crl-refresh pki-manual-<name>
  ```

- Rotation or any one-off tofu invocation: copy `reconcile-job.yaml` to a
  new file in `homelab-pki/` (drop the two `argocd.argoproj.io` hook
  annotations, rename `metadata.name`, edit `args`), list it in
  `kustomization.yaml` resources, and push. Reference the ConfigMap by its
  base name — kustomize's nameReference rewrite fills in the current hash.
  Remove the file after the run (`ttlSecondsAfterFinished` also ages it
  out; Argo prunes it on the next sync).

  Rotation args (forces a new key, cascading to a new certificate and an
  in-place update of the same `pki-<name>` Secret):

  ```sh
  tofu -chdir=/config init -input=false -no-color -lockfile=readonly
  tofu -chdir=/config apply -input=false -auto-approve -no-color \
    -replace='pki_private_key.device["<name>"]'
  ```

  If the rotation is security-motivated, also add the *old* serial to
  `revoked_serials` per the revocation steps above.
