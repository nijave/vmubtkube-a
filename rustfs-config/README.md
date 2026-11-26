# rustfs-config

Declarative buckets, policies, users and consumer credentials for the HA
rustfs (`application.rustfs.yaml`). `tofu/` holds the desired state and uses
the [`aminueza/minio`](https://registry.terraform.io/providers/aminueza/minio)
provider: rustfs serves MinIO's admin API.

Same layout as `homelab-pki/`. The Sync-hook Job (`rustfs-config-reconcile`)
and the CronJob of the same name (every 6h) run the official
`ghcr.io/opentofu/opentofu` image in namespace `rustfs`. The config ships as
a kustomize-generated ConfigMap at `/config`. The provider reads the root keys
from Secret `rustfs-root` as `MINIO_USER` and `MINIO_PASSWORD`. State lives in
Secret `tfstate-default-rustfs-config` in namespace `rustfs`, and that state
holds every consumer's secret key.

## Local validation

From `rustfs-config/tofu/`:

```sh
tofu init -backend=false
tofu validate
tofu fmt -check -recursive
```

## Adding a consumer

1. In the consumer's manifests, bind the reconciler to its namespace, so it
   can write the credentials Secret there:

   ```yaml
   apiVersion: rbac.authorization.k8s.io/v1
   kind: RoleBinding
   metadata:
     name: rustfs-config-secret-writer
     namespace: <consumer namespace>
   subjects:
     - kind: ServiceAccount
       name: rustfs-config-reconciler
       namespace: rustfs
   roleRef:
     apiGroup: rbac.authorization.k8s.io
     kind: ClusterRole
     name: rustfs-config-secret-writer
   ```

2. Add an entry to `local.consumers` in `tofu/consumers.tf`:

   ```hcl
   immich = { namespace = "immich", access = "readwrite" } # or "readonly"
   ```

   The key becomes the bucket name and the rustfs user name (its access key).
3. Commit and push. After the sync, Secret `s3-<key>` in the consumer
   namespace holds `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
   `AWS_ENDPOINT_URL`, `AWS_REGION` and `BUCKET`.

The policy allows the consumer's own bucket only, and not `CreateBucket`.
Clients that create the bucket before an upload (rclone by default) need that
turned off: `--s3-no-check-bucket` for rclone, `no_check_bucket = true` in its
config.

## Removing a consumer

Delete its entry. The next run deletes the user, policy and Secret, then the
bucket if empty. A bucket that still holds objects stops the run with
`bucket "<key>" is not empty` (`force_destroy` stays off) and the Job fails
until one of these happens:

- Empty the bucket, and the next run deletes it.
- Keep the data without management:
  `tofu state rm 'minio_s3_bucket.consumer["<key>"]'` from a one-off Job (see
  `homelab-pki/README.md`, "Ad-hoc runs").

## Rotating a consumer key

Run a one-off Job with:

```sh
tofu -chdir=/config apply -input=false -auto-approve -no-color \
  -replace='random_password.consumer["<key>"]'
```

The user's secret and the `s3-<key>` Secret update in the same run. Restart
the consumer so it reads the new key.

## Drift

The CronJob restores a user, policy or Secret that someone changed or deleted
outside git (a console edit, a recreated namespace).
