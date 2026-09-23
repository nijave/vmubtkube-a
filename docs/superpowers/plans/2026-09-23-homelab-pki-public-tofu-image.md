# homelab-pki Public OpenTofu Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retire the self-built `registry.apps.nickv.me/nijave/homelab-pki` image — run the reconcile Job/CronJob on the official `ghcr.io/opentofu/opentofu` image with a kustomize ConfigMap for config and a 10Gi PVC for the provider cache.

**Architecture:** `homelab-pki/` becomes a kustomize app (fluentbit pattern) behind a new child Argo Application. The `.tf` files plus a committed `.terraform.lock.hcl` ship as a hash-suffixed ConfigMap mounted read-only at `/config`; `TF_DATA_DIR` and the plugin cache live on PVC `pki-tofu-cache`; `tofu init -lockfile=readonly` pins provider versions and fails loudly on drift. The root `homelab-pki.yaml` is deleted; its projectcontour RBAC trio moves verbatim into `python-envoy-authz.yaml`.

**Tech Stack:** OpenTofu 1.12.6 (official image), kustomize, Argo CD, Renovate (docker + terraform managers), kubeconform/pluto pre-commit gates.

**Spec:** `docs/superpowers/specs/2026-09-23-homelab-pki-public-tofu-image-design.md`

## Global Constraints

- Image: `ghcr.io/opentofu/opentofu:1.12.6`, direct pull, `imagePullPolicy: IfNotPresent`, renovate annotation exactly `# renovate: datasource=docker depName=ghcr.io/opentofu/opentofu`.
- Env vars (verified against the local OpenTofu 1.12 binary via `strings`): `TF_DATA_DIR=/tofu/data` and `TF_PLUGIN_CACHE_DIR=/tofu/plugin-cache`. There is **no** `TOFU_PLUGIN_CACHE_DIR` in OpenTofu 1.12 — do not use it.
- `tofu init` flag: `-lockfile=readonly` (verified supported by `tofu init -help`).
- PVC `pki-tofu-cache`: 10Gi, `ReadWriteOnce`, `storageClassName: zfs-generic-iscsi-csi`, **no** annotations, no backup.
- ConfigMap base name: `homelab-pki-tofu-config`, hash suffixes enabled, keys = the six file basenames from `tofu/` including `.terraform.lock.hcl`.
- Workload manifests inside `homelab-pki/` carry **no** `metadata.namespace` (the kustomization sets `namespace: homelab-pki`).
- Every commit fires the pre-commit hooks (`.ci/validate.sh` kubeconform + pluto); `kubeconform`, `pluto`, `yq`, `kubectl` are on PATH; `kustomize` is not — use `kubectl kustomize`.
- `git ls-files` (used by `.ci/validate.sh`'s kustomize loop) only sees staged/tracked files: run `git add` **before** invoking `sh .ci/validate.sh` manually.
- Commit style: `type: lowercase imperative subject` (e.g. `feat: letsencrypt route53 clusterissuers (native dns01 solver)`), no scope parens beyond `chore(deps)`, stage explicit paths only.
- Work on branch `feat/homelab-pki-public-image` (already checked out; carries the spec commit `787a58d`).

## Review Focus

Five failure modes the spec implies but no in-cluster test can cover pre-merge; each is pinned to the task that owns its code.

1. **Stale lock after a hand-edited provider constraint** — must fail `init -lockfile=readonly`, never silently re-resolve. Pinned by the Task 2 mismatch probe.
2. **A `.tf`/lock change that doesn't roll the workloads** (hash not referenced) — would mean config changes never re-reconcile. Pinned by the Task 3 hash-mutation probe.
3. **Tofu writing into read-only `/config`** (wrong env spelling) — only visible as a runtime `read-only file system` error post-merge. Names verified during planning (see Global Constraints); pinned post-merge by the Task 6 log check.
4. **Root→child Argo ownership handoff pruning live objects** — pinned by the Task 6 watch steps.
5. **Renovate double-managing the tofu image** (regex manager + kubernetes manager) causing spurious PRs — pinned by the Task 4 filePattern grep.

---

### Task 1: Spec errata — corrected plugin-cache env var

**Files:**
- Modify: `docs/superpowers/specs/2026-09-23-homelab-pki-public-tofu-image-design.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a spec that matches the verified env spellings used by Tasks 3–5.

- [ ] **Step 1: Fix the env var name everywhere it appears**

In the spec file, replace every occurrence of `TOFU_PLUGIN_CACHE_DIR` with `TF_PLUGIN_CACHE_DIR` (three places: the "Tofu writes" table row, the workload YAML env block, the "Env var spellings" bullet).

- [ ] **Step 2: Replace the "verify at implementation" bullet with the verified fact**

Replace:

```markdown
- Env var spellings (`TF_DATA_DIR`, `TOFU_PLUGIN_CACHE_DIR`) and
  `-lockfile=readonly` support are verified against the running `tofu`
  during implementation; adjust names there if OpenTofu expects others.
```

with:

```markdown
- Env var spellings verified against the OpenTofu 1.12 binary (2026-09-23,
  `strings` on the local install): `TF_DATA_DIR` and `TF_PLUGIN_CACHE_DIR`
  are honored; no `TOFU_`-prefixed plugin-cache variant exists in 1.12.
  `-lockfile=readonly` is accepted by `tofu init`.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-23-homelab-pki-public-tofu-image-design.md
git commit -m "docs: correct plugin cache env var in homelab-pki spec"
```

---

### Task 2: Commit the tofu lock file, gitignore, and comment updates

**Files:**
- Modify: `.gitignore`
- Create: `homelab-pki/tofu/.terraform.lock.hcl` (generated)
- Modify: `homelab-pki/tofu/locals.tf:1-2` and `homelab-pki/tofu/locals.tf:66-68`

**Interfaces:**
- Consumes: nothing.
- Produces: `homelab-pki/tofu/.terraform.lock.hcl` with `h1:` hashes for linux/amd64 — Task 3's `configMapGenerator` lists this file.

- [ ] **Step 1: Ignore the local tofu data dir**

Append one line to `.gitignore` so it reads:

```
.claude
.tmp
local_files/
homelab-pki/tofu/.terraform/
```

- [ ] **Step 2: Generate the lock file**

Run: `cd homelab-pki/tofu && tofu init -backend=false`
Expected: exit 0; `.terraform.lock.hcl` created; providers `hashicorp/kubernetes ~> 3.0` and `registry.terraform.io/nijave/pki ~> 1.1` recorded.

- [ ] **Step 3: Verify the lock content**

Run: `grep -c '^provider "' homelab-pki/tofu/.terraform.lock.hcl`
Expected: `2`

Run: `grep -c 'h1:' homelab-pki/tofu/.terraform.lock.hcl`
Expected: `2` or more (one `h1:` hash per provider; the local linux/amd64 platform is recorded — the cluster workers are the same platform).

Run: `cd homelab-pki/tofu && tofu validate && tofu fmt -check -recursive`
Expected: both exit 0.

- [ ] **Step 4: Probe that a stale lock fails loudly**

Temporarily change the `pki` provider constraint in `homelab-pki/tofu/main.tf` from `version = "~> 1.1"` to `version = "~> 1.2"`, then:

Run: `cd homelab-pki/tofu && tofu init -backend=false -lockfile=readonly`
Expected: FAIL — tofu reports the lock file would need updating.

Revert: `git checkout -- homelab-pki/tofu/main.tf`, then re-run `tofu init -backend=false` — expected exit 0 (lock untouched; git diff clean).

- [ ] **Step 5: Update the stale image-rebuild comments in locals.tf**

Replace lines 1–2:

```hcl
# Adding or removing a device means editing this file and rebuilding the
# image (see homelab-pki/README.md).
```

with:

```hcl
# Adding or removing a device means editing this file and committing --
# the kustomize ConfigMap hash rolls the reconcile Job on the next Argo
# sync (see homelab-pki/README.md).
```

Replace lines 66–68:

```hcl
  # Revoke a device: add { serial_number = "<serial>", reason = "..." } here
  # (look up the current serial via `tofu output device_serials`), then
  # rebuild/push/apply. See homelab-pki/README.md.
```

with:

```hcl
  # Revoke a device: add { serial_number = "<serial>", reason = "..." } here
  # (look up the current serial via `tofu output device_serials`), then
  # commit/push. See homelab-pki/README.md.
```

- [ ] **Step 6: Commit**

```bash
git add .gitignore homelab-pki/tofu/.terraform.lock.hcl homelab-pki/tofu/locals.tf
git commit -m "feat: pin homelab-pki tofu providers via committed lockfile"
```

(Pre-commit hooks run validate.sh + pluto; no yaml files changed, so both report "no files to check" and pass.)

---

### Task 3: Create the homelab-pki kustomize app

**Files:**
- Create: `homelab-pki/kustomization.yaml`
- Create: `homelab-pki/rbac.yaml`
- Create: `homelab-pki/pvc.yaml`
- Create: `homelab-pki/reconcile-job.yaml`
- Create: `homelab-pki/crl-refresh-cronjob.yaml`
- Modify: `.ci/validate.sh:93`

**Interfaces:**
- Consumes: `homelab-pki/tofu/*` (six files incl. `.terraform.lock.hcl`) from Task 2.
- Produces: ConfigMap base name `homelab-pki-tofu-config` (hash-suffixed) and PVC name `pki-tofu-cache` — referenced by the workloads in this task and by the ad-hoc runbook in Task 6. Namespace comes from the kustomization (`homelab-pki`); no resource in this dir sets `metadata.namespace`.

- [ ] **Step 1: Write `homelab-pki/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: homelab-pki

resources:
  - rbac.yaml
  - pvc.yaml
  - reconcile-job.yaml
  - crl-refresh-cronjob.yaml

# Hash-suffixed ConfigMap so any .tf/lock change re-rolls the Job/CronJob
# that reference it (kustomize rewrites the configMap.name in pod specs).
configMapGenerator:
  - name: homelab-pki-tofu-config
    files:
      - tofu/main.tf
      - tofu/ca.tf
      - tofu/devices.tf
      - tofu/locals.tf
      - tofu/crl.tf
      - tofu/.terraform.lock.hcl
```

- [ ] **Step 2: Write `homelab-pki/rbac.yaml`**

```yaml
# pki-reconciler: cert/CRL Secret writes, the pki-ca ExternalSecret target,
# and the OpenTofu kubernetes-backend state Secret + lock Lease.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pki-reconciler
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pki-reconciler
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pki-reconciler
subjects:
  - kind: ServiceAccount
    name: pki-reconciler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pki-reconciler
---
# CA cert+key delivered from Bitwarden (ha-ca-crt / ha-ca-key). Opaque, read
# directly by tofu/ca.tf's kubernetes_secret_v1 data source. Never in git.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pki-ca
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
```

- [ ] **Step 3: Write `homelab-pki/pvc.yaml`**

```yaml
# OpenTofu plugin cache + TF_DATA_DIR. Regenerable: plain prune, no backup;
# a wiped cache just means one cold `tofu init`.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pki-tofu-cache
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: zfs-generic-iscsi-csi
```

- [ ] **Step 4: Write `homelab-pki/reconcile-job.yaml`**

```yaml
# Runs on every child-app sync: a .tf/lock change (new ConfigMap hash) or
# image tag bump re-renders the Job and Argo re-runs the hook.
apiVersion: batch/v1
kind: Job
metadata:
  name: pki-reconcile
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
          # renovate: datasource=docker depName=ghcr.io/opentofu/opentofu
          image: ghcr.io/opentofu/opentofu:1.12.6
          imagePullPolicy: IfNotPresent
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eux
              tofu -chdir=/config init -input=false -no-color -lockfile=readonly
              tofu -chdir=/config apply -input=false -auto-approve -no-color
          env:
            - name: TF_DATA_DIR
              value: /tofu/data
            - name: TF_PLUGIN_CACHE_DIR
              value: /tofu/plugin-cache
          volumeMounts:
            - name: config
              mountPath: /config
              readOnly: true
            - name: tofu-cache
              mountPath: /tofu
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { cpu: "1", memory: 512Mi }
      volumes:
        - name: config
          configMap:
            name: homelab-pki-tofu-config
        - name: tofu-cache
          persistentVolumeClaim:
            claimName: pki-tofu-cache
```

- [ ] **Step 5: Write `homelab-pki/crl-refresh-cronjob.yaml`**

```yaml
# concurrencyPolicy Forbid; the OpenTofu state lock also guards against
# overlap with the Sync-hook Job.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pki-crl-refresh
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
              # renovate: datasource=docker depName=ghcr.io/opentofu/opentofu
              image: ghcr.io/opentofu/opentofu:1.12.6
              imagePullPolicy: IfNotPresent
              command: ["/bin/sh", "-c"]
              args:
                - |
                  set -eux
                  tofu -chdir=/config init -input=false -no-color -lockfile=readonly
                  tofu -chdir=/config apply -input=false -auto-approve -no-color
              env:
                - name: TF_DATA_DIR
                  value: /tofu/data
                - name: TF_PLUGIN_CACHE_DIR
                  value: /tofu/plugin-cache
              volumeMounts:
                - name: config
                  mountPath: /config
                  readOnly: true
                - name: tofu-cache
                  mountPath: /tofu
              resources:
                requests: { cpu: 50m, memory: 128Mi }
                limits: { cpu: "1", memory: 512Mi }
          volumes:
            - name: config
              configMap:
                name: homelab-pki-tofu-config
            - name: tofu-cache
              persistentVolumeClaim:
                claimName: pki-tofu-cache
```

- [ ] **Step 6: Exclude the dir from direct validation in `.ci/validate.sh`**

Change line 93 from:

```sh
  | grep -vE '^(vendored/|fluentbit/|docs/|\.|renovate\.json|vendir)' \
```

to:

```sh
  | grep -vE '^(vendored/|fluentbit/|homelab-pki/|docs/|\.|renovate\.json|vendir)' \
```

(The kustomize-overlays loop validates the rendered output; the raw files are skipped, matching the fluentbit convention.)

- [ ] **Step 7: Stage, render, and inspect**

```bash
git add homelab-pki/ .ci/validate.sh
kubectl kustomize homelab-pki/ > /tmp/opencode/homelab-pki-rendered.yaml
```

Verify in `/tmp/opencode/homelab-pki-rendered.yaml`:
- a `kind: ConfigMap` named `homelab-pki-tofu-config-<hash>` in namespace `homelab-pki` with keys `main.tf`, `ca.tf`, `devices.tf`, `locals.tf`, `crl.tf`, `.terraform.lock.hcl`
- both workload `volumes[].configMap.name` values equal that hashed name (nameReference rewrite worked)
- every namespaced resource carries `namespace: homelab-pki`
- the PVC renders with `storageClassName: zfs-generic-iscsi-csi` and no annotations

- [ ] **Step 8: Hash-mutation probe (Review Focus #2)**

```bash
printf '\n# probe\n' >> homelab-pki/tofu/crl.tf
kubectl kustomize homelab-pki/ | grep 'name: homelab-pki-tofu-config'
git checkout -- homelab-pki/tofu/crl.tf
```

Expected: the printed ConfigMap name hash **differs** from Step 7's (config changes re-hash). Then re-render once more to confirm the original hash is back.

- [ ] **Step 9: Run the full validation gate**

```bash
git add homelab-pki/ && sh .ci/validate.sh && sh .ci/validate-pluto.sh
```

Expected: both exit 0 ("All manifests valid." / no deprecated APIs).

- [ ] **Step 10: Commit**

```bash
git add homelab-pki/ .ci/validate.sh
git commit -m "feat: homelab-pki kustomize app on public tofu image with cache pvc"
```

---

### Task 4: Root wiring — child Application, delete root manifest, relocate RBAC trio

**Files:**
- Create: `application.homelab-pki.yaml`
- Delete: `homelab-pki.yaml`
- Modify: `python-envoy-authz.yaml` (insert RBAC trio after line 18)

**Interfaces:**
- Consumes: the `homelab-pki/` kustomize dir from Task 3 (Application points at `path: homelab-pki/`).
- Produces: live-cluster layout where the child app owns all `homelab-pki`-namespace workloads and the root app owns the projectcontour RBAC trio via `python-envoy-authz.yaml`.

- [ ] **Step 1: Write `application.homelab-pki.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: homelab-pki
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  destination:
    server: "https://kubernetes.default.svc"
    namespace: homelab-pki
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
    repoURL: ssh://git@github.com/nijave/vmubtkube-a.git
    path: homelab-pki/
    targetRevision: HEAD
```

- [ ] **Step 2: Insert the projectcontour RBAC trio into `python-envoy-authz.yaml`**

Between line 18 (the `---` ending the `ca-ha-homelab-somemissing-info-tls` ExternalSecret) and line 19 (`apiVersion: external-secrets.io/v1` of the `homelab-pki` SecretStore), insert verbatim from the old `homelab-pki.yaml` (SA lines 21–25, Role lines 43–52, RoleBinding lines 54–66):

```yaml
# pki-crl-reader: identity used by the homelab-pki SecretStore below to
# copy the CRL k8s→k8s. The Role/RoleBinding grant it read access to the
# pki-crl Secret in the homelab-pki namespace (written by the tofu
# reconciler). Lives here, not in the homelab-pki kustomization, because
# the kustomize namespace transformer would rewrite the projectcontour
# ServiceAccount's namespace.
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
```

- [ ] **Step 3: Delete the root manifest**

```bash
git rm homelab-pki.yaml
```

- [ ] **Step 4: Verify the cutover state**

```bash
git add application.homelab-pki.yaml python-envoy-authz.yaml
sh .ci/validate.sh && sh .ci/validate-pluto.sh
grep -c 'pki-crl-reader' python-envoy-authz.yaml
git ls-files 'homelab-pki*' 
```

Expected: validation exits 0; grep count `5` (comment, SA `metadata.name`, pre-existing SecretStore `serviceAccount.name`, RoleBinding subject, RoleBinding `roleRef.name`); `git ls-files` shows only `homelab-pki/` files — `homelab-pki.yaml` gone.

- [ ] **Step 5: Commit**

```bash
git add application.homelab-pki.yaml python-envoy-authz.yaml homelab-pki.yaml
git commit -m "feat: move homelab-pki to child argo app, relocate crl-reader rbac"
```

---

### Task 5: Retire the image plumbing — renovate rule, blackbox probe, TODO, README, Dockerfile

**Files:**
- Modify: `renovate.json:266-270`
- Modify: `application.blackbox-exporter.yaml:126-129`
- Modify: `TODO.md:72`
- Modify: `homelab-pki/README.md` (full rewrite)
- Delete: `homelab-pki/Dockerfile`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the final repo state — no references to `registry.apps.nickv.me/nijave/homelab-pki` anywhere.

- [ ] **Step 1: Remove the renovate package rule**

In `renovate.json`, delete this object from `packageRules`:

```json
    {
      "description": "homelab-pki: self-built semver tags; tftest never passes the service's tag filter",
      "matchPackageNames": ["registry.apps.nickv.me/nijave/homelab-pki"],
      "versioning": "semver"
    },
```

(The following `jellyfin.yaml and python-envoy-authz.yaml…` rule stays; JSON stays valid — the removed object sat mid-array with its trailing comma.)

- [ ] **Step 2: Remove the blackbox probe**

In `application.blackbox-exporter.yaml`, delete:

```yaml
            - name: renovate-releases-homelab-pki
              url: https://renovate-releases.apps.somemissing.info/v1/releases/nijave/homelab-pki
              module: renovate_releases_2xx
              interval: 60s
```

- [ ] **Step 3: Touch up TODO.md line 72**

Change:

```markdown
`^v` semver for the
jellyfin fork; plain semver for homelab-pki) plus annotations on each
```

to:

```markdown
`^v` semver for the
jellyfin fork; plain semver for homelab-pki, until it moved to the public
OpenTofu image 2026-09 and the rule was removed) plus annotations on each
```

- [ ] **Step 4: Rewrite `homelab-pki/README.md`**

Replace the entire file with:

````markdown
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
````

- [ ] **Step 5: Delete the Dockerfile**

```bash
git rm homelab-pki/Dockerfile
```

- [ ] **Step 6: Verify nothing references the old image**

```bash
git add renovate.json application.blackbox-exporter.yaml TODO.md homelab-pki/README.md homelab-pki/Dockerfile
sh .ci/validate.sh && sh .ci/validate-pluto.sh
rg -n 'nijave/homelab-pki' --glob '!docs/' || echo CLEAN
rg -n 'homelab-pki' renovate.json || echo CLEAN
```

Expected: validation exits 0; both greps print `CLEAN` (docs/ contains historical specs/reports that intentionally keep their mentions).

Review Focus #5 — confirm renovate's kubernetes manager cannot double-manage the new image lines:

```bash
rg -n 'kubernetes' renovate.json | head -5
```

Expected: the `kubernetes.managerFilePatterns` list (lines 21–28) does not match `homelab-pki/` — only `fluentbit|immich|operators|thanos|woodpecker` subdirs and specific root files appear. The regex customManager (`/\.yaml$/`) owns the annotated image lines exclusively.

- [ ] **Step 7: Commit**

```bash
git add renovate.json application.blackbox-exporter.yaml TODO.md homelab-pki/README.md homelab-pki/Dockerfile
git commit -m "chore: remove homelab-pki image build, renovate rule, and probe"
```

---

### Task 6: Post-merge rollout verification (no commit)

**Files:** none (operational checks against the live cluster).

**Interfaces:**
- Consumes: everything from Tasks 2–5 merged to `main` and synced by Argo.
- Produces: evidence the migration converged (spec's verification checklist items 4–6).

- [ ] **Step 1: Child app health**

```bash
kubectl -n argocd get application homelab-pki
```

Expected: `Synced` / `Healthy`. (Progressing right after merge is fine; re-check until Synced.)

- [ ] **Step 2: Handoff integrity (Review Focus #4)**

```bash
kubectl -n homelab-pki get sa,role,rolebinding,externalsecret,pvc,cm,cronjob
kubectl -n projectcontour get sa pki-crl-reader
kubectl -n homelab-pki get secret pki-ca pki-crl
```

Expected: `pki-reconciler` SA/Role/RoleBinding, `pki-ca` ExternalSecret, `pki-tofu-cache` PVC `Bound`, one `homelab-pki-tofu-config-<hash>` ConfigMap, `pki-crl-refresh` CronJob; the projectcontour SA exists; both Secrets exist (no deletion fallout from the root-app prune race).

- [ ] **Step 3: Hook job success + read-only mount behavior (Review Focus #3)**

```bash
kubectl -n homelab-pki wait --for=condition=complete job/pki-reconcile --timeout=600s \
  || kubectl -n homelab-pki get jobs
kubectl -n homelab-pki logs job/pki-reconcile | tail -50
```

Expected: `tofu init` downloads the two providers once (cold cache), reports the lock file as consistent, `apply` completes with no changes or expected changes only, and there are **no** `read-only file system` errors (proves `TF_DATA_DIR`/`TF_PLUGIN_CACHE_DIR` redirect every write off `/config`).

- [ ] **Step 4: Warm-cache run**

```bash
kubectl -n homelab-pki create job --from=cronjob/pki-crl-refresh pki-manual-warmcheck
kubectl -n homelab-pki wait --for=condition=complete job/pki-manual-warmcheck --timeout=600s
kubectl -n homelab-pki logs job/pki-manual-warmcheck | grep -iE 'installing|downloading' || echo "no downloads"
kubectl -n homelab-pki delete job pki-manual-warmcheck
```

Expected: `no downloads` — providers come from the PVC cache.

- [ ] **Step 5: CRL consumers still healthy**

```bash
kubectl -n projectcontour get externalsecret pki-crl
kubectl -n projectcontour get deployment python-envoy-authz
```

Expected: ExternalSecret `Ready=True`, deployment available. (The HA HTTPProxy path is covered by the CRL Secret existing in `default` — check `kubectl -n default get externalsecret pki-crl` if wired there.)

- [ ] **Step 6: Renovate detection**

After the next scheduled Renovate run (or a manual dry run), confirm the Dependency Dashboard lists `ghcr.io/opentofu/opentofu` and the two terraform providers from `homelab-pki/tofu/`. No action needed on the PRs themselves.

---

## Self-Review

**Spec coverage:** lock file bootstrap (Task 2), ConfigMap + hash rolling (Tasks 2–3), public image + envs + script (Task 3), PVC (Task 3), child app + root deletion + RBAC relocation (Task 4), renovate/blackbox/TODO/Dockerfile/README cleanup (Task 5), migration watch + verification checklist items 1–5 (Tasks 2–5 local, Task 6 in-cluster), spec env-var errata (Task 1). Spec's checklist item 6 (renovate picks up deps) is Task 6 Step 6. No gaps.

**Placeholder scan:** the only `<...>` tokens left are intentional runbook placeholders (`pki-manual-<name>`, `<hash>`, `<name>`) inside documentation and expected-output text — no TBD/TODO steps.

**Type consistency:** ConfigMap base name `homelab-pki-tofu-config`, PVC `pki-tofu-cache`, env values `/tofu/data` + `/tofu/plugin-cache`, image `ghcr.io/opentofu/opentofu:1.12.6`, and the `TF_`-prefixed env spellings are identical across Tasks 1, 3, 5, 6.

**Review Focus:** all five lines have pinned tests in Tasks 2–6.
