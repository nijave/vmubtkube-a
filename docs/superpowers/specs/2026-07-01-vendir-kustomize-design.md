# vendir + kustomize: Operator Manifest Management

**Date**: 2026-07-01
**Status**: Implemented on `feature/vendir-kustomize` — 4 of 5 components; contour deferred; cluster rollout pending the 3-push sequence (not yet pushed to main)

> **Implementation status (2026-07-02):** CNPG, cert-manager, barman-cloud-plugin,
> and external-secrets CRDs are migrated to `vendir` + per-component ArgoCD apps
> on branch `feature/vendir-kustomize` (3 commits, validated, **not pushed**).
> **Contour is deferred** — its current `contour.yaml` is a stale release-1.32
> render (images bumped to v1.33.5) carrying extensive local ContourConfiguration
> (accesslog format, rateLimitService, tracing, policy headers, ingress-status-address,
> etc.) that the overlay in this spec does not preserve.
>
> Several values below were **corrected during implementation** — the barman repo
> slug/asset name, the external-secrets tag (v2.7.0, not v0.14.x) and CRD source
> (git `deploy/crds/bundle.yaml`, since no CRD-only release asset exists), checksum
> handling, and vendir `includePaths`/`newRootPath` semantics. Two safety changes
> not anticipated here were also made: the `crds` app is **repointed in place**
> (not deleted+recreated, to avoid cascade-deleting the ExternalSecret CRD) and
> `vendir.yml`/`vendir.lock.yml` are **excluded from the root app** (non-k8s kinds).
> Authoritative details: `2026-07-01-vendir-kustomize-migration-notes.md`.

---

## Problem

Upstream operator manifests (CNPG, cert-manager, contour, barman-cloud-plugin) are vendored as single YAML bundles in the repo root. Renovate's `kubernetes` manager bumps only the container image tags inside those files. When an operator release ships new or changed CRDs and RBAC alongside the image (as CNPG 1.29→1.30 did), Renovate's PR is dangerously incomplete: the operator starts but CRDs are missing or stale, causing crashes and requiring an out-of-band manual fix.

## Solution

Replace ad-hoc vendored YAML blobs with **vendir** for fetching and **kustomize** for local modifications. vendir fetches whole upstream release artifacts atomically (entire manifest bundle), pins them in `vendir.lock.yml`, and Renovate's native `vendir` manager tracks `tag`/`ref` fields in `vendir.yml` — bumping the whole release, not individual images. Local patches (image mirrors, resource limits, tracing args) are expressed as kustomize overlays on top of the unmodified upstream base.

---

## Component Scope

**Migrated to vendir + kustomize:**

| Component | Current file | vendir source | Notes |
|---|---|---|---|
| CNPG operator | `cnpg-1.30.0.yaml` | `githubRelease` from `cloudnative-pg/cloudnative-pg` | No local customizations |
| Barman Cloud Plugin | `barman-cloud-plugin-0.12.0.yaml` | `githubRelease` from `cloudnative-pg/cloudnative-pg-plugin-barman-cloud` | No local customizations |
| cert-manager | `cert-manager.yaml` | `githubRelease` from `cert-manager/cert-manager` | No current customizations; tracing patch placeholder for future use |
| Contour | `contour.yaml` | `git` source from `projectcontour/contour` at `examples/render/contour.yaml` | Envoy image uses private registry mirror; resource limits (verify vs upstream) |
| external-secrets CRDs | `crds/crd-externalsecrets.yaml` | `githubRelease` from `external-secrets/external-secrets` | CRD-only; no pruning |

**Not migrated:**

- `operators/clickhouse-operator.yaml` — already an ArgoCD Application using Helm chart; no changes needed
- `operators/mongodb-community-operator.yaml` — same
- `external-dns.yaml` — standalone image-only deployment; Renovate image tracking is correct for it

**Not migrated but stays at root:**

- `contour-tracing.yaml` — an `ExtensionService` CR pointing to the OTel collector; not part of the contour upstream bundle and requires no vendoring

---

## Directory Structure

```
vendir.yml
vendir.lock.yml
vendored/
  cnpg/
    base/
      cnpg-1.30.0.yaml       # written by vendir sync; ArgoCD app points here
  barman-cloud-plugin/
    base/
      barman-cloud-plugin-*.yaml
  cert-manager/
    base/
      cert-manager.yaml
    kustomization.yaml       # only present when patches exist
  contour/
    base/
      contour.yaml
    kustomization.yaml
  external-secrets-crds/
    base/
      external-secrets.crds.yaml
```

`base/` directories contain only upstream files written by `vendir sync`. They are committed to git so ArgoCD can render them without running vendir at sync time. Do not hand-edit anything under `base/`.

Components **without** local customizations (cnpg, barman-cloud-plugin, external-secrets-crds) have no `kustomization.yaml`. Their ArgoCD Applications point directly at `vendored/<name>/base/` using ArgoCD's plain directory source — this avoids the versioned-filename problem where `kustomization.yaml` would need to reference `base/cnpg-1.30.0.yaml` and would break when vendir bumps to `cnpg-1.31.0.yaml`.

Components **with** customizations (cert-manager, contour) have a `kustomization.yaml` at `vendored/<name>/`. Their ArgoCD Applications point at `vendored/<name>/` and ArgoCD auto-detects kustomize. cert-manager has no current customizations but gets a `kustomization.yaml` so future patches (tracing) can be added without changing the Application spec.

---

## vendir.yml

```yaml
apiVersion: vendir.k14s.io/v1alpha1
kind: Config
minimumRequiredVersion: 0.40.0
directories:
  - path: vendored/cnpg/base
    contents:
      - path: .
        githubRelease:
          slug: cloudnative-pg/cloudnative-pg
          tag: v1.30.0
          assetNames: ["cnpg-*.yaml"]

  - path: vendored/barman-cloud-plugin/base
    contents:
      - path: .
        githubRelease:
          slug: cloudnative-pg/cloudnative-pg-plugin-barman-cloud
          tag: v0.13.0
          assetNames: ["barman-cloud-plugin-*.yaml"]

  - path: vendored/cert-manager/base
    contents:
      - path: .
        githubRelease:
          slug: cert-manager/cert-manager
          tag: v1.20.3
          assetNames: ["cert-manager.yaml"]

  - path: vendored/contour/base
    contents:
      - path: .
        git:
          url: https://github.com/projectcontour/contour
          ref: v1.33.5
          depth: 1
        newRootPath: examples/render
        includePaths:
          - contour.yaml

  - path: vendored/external-secrets-crds/base
    contents:
      - path: .
        githubRelease:
          slug: external-secrets/external-secrets
          # TODO(impl): confirm GitHub release tag that matches chart 2.7.0 in application.external-secrets.yaml
          tag: v0.14.x
          assetNames: ["external-secrets.crds.yaml"]
```

During implementation, check each release's GitHub assets to determine whether checksums are published. If a `.sha256` or similar file is present alongside the asset, vendir can validate it; otherwise `disableAutoChecksumValidation: true` is needed per directory.

---

## Kustomize Overlays

### cnpg, barman-cloud-plugin, external-secrets-crds

No kustomize overlay. ArgoCD Application `source.path` points at `vendored/<name>/base/` and renders all YAML files in that directory. No `kustomization.yaml` is created. When vendir bumps the version and the filename changes (e.g., `cnpg-1.30.0.yaml` → `cnpg-1.31.0.yaml`), ArgoCD picks up the new file automatically — nothing else needs updating.

### cert-manager

No current customizations, but a `kustomization.yaml` is created so future patches can be added without changing the ArgoCD Application spec:

```yaml
# vendored/cert-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base/cert-manager.yaml
```

Future tracing patch: add `--tracing-enabled=true` and `--tracing-endpoint=otel-collector-opentelemetry-collector.monitoring:4317` to the three cert-manager Deployments. Use JSON 6902 patches (not strategic merge — `args` has no merge key so a strategic merge patch replaces the entire list).

### contour

Two confirmed local customizations:

1. **Envoy image** — the envoy DaemonSet container uses `registry.apps.nickv.me/envoyproxy/envoy:v1.38.3` (private registry mirror). The upstream base file will have the docker.io reference; a kustomize `images:` transform redirects it. Verify the exact image reference in the upstream file during implementation — it may be `docker.io/envoyproxy/envoy` or just `envoyproxy/envoy` (without explicit registry).

2. **Resource limits** — verify during implementation whether the resource requests/limits present in the current `contour.yaml` are from upstream or were added locally. If upstream, no patch needed. If local, add JSON 6902 patches.

```yaml
# vendored/contour/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - base/contour.yaml
images:
  - name: docker.io/envoyproxy/envoy    # verify exact name in upstream base file
    newName: registry.apps.nickv.me/envoyproxy/envoy
```

**mirror-images.sh consideration**: The `mirror-images` CI step diffs changed files looking for `registry.apps.nickv.me` image references. With the `images:` kustomize transform, the base file will show `docker.io/envoyproxy/envoy` (not the private registry reference), so the script won't detect it when contour is bumped. During implementation, update `mirror-images.sh` to also scan `vendored/*/base/` files and apply kustomize image transform mappings when looking for images to mirror.

---

## ArgoCD Application Changes

Each vendored component gets its own ArgoCD Application. This isolates sync failures per component and allows per-component prune/sync policies.

**No-customization components** (cnpg, barman-cloud-plugin, external-secrets-crds) — point at `vendored/<name>/base/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cnpg
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
  source:
    path: vendored/cnpg/base
    repoURL: ssh://git@github.com/nijave/vmubtkube-a.git
    targetRevision: HEAD
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - PruneLast=true
    - ServerSideApply=true
    - ApplyOutOfSyncOnly=true
```

**Kustomize components** (cert-manager, contour) — point at `vendored/<name>/` (ArgoCD auto-detects kustomize via `kustomization.yaml`). Same spec with `path: vendored/cert-manager`.

**external-secrets-crds** uses `prune: false` (never cascade-delete CRDs). All other components use `prune: true`.

`application.crds.yaml` (currently pointing at `crds/`) is deleted. The external-secrets CRDs move to `application.vendored-external-secrets-crds.yaml`.

---

## Migration Sequence

The root ArgoCD Application (`application.vmubtkube-a.yaml`) manages all `application.*.yaml` files in `./`. If we commit the deletions and additions in one push while `prune: true` is active, ArgoCD may prune resources belonging to newly-deleted Application objects before the new Applications have synced. Three-push sequence prevents this:

### Push 1 — Disable pruning

In `application.vmubtkube-a.yaml`:
- Remove `resources-finalizer.argocd.argoproj.io` from `metadata.finalizers`
- Set `syncPolicy.automated.prune: false`

Commit and push. Wait for ArgoCD to sync this change (confirm in UI — the root app should show `prune: false`).

### Push 2 — File migration

Delete from repo root:
- `cnpg-1.30.0.yaml`
- `cert-manager.yaml`
- `contour.yaml`
- `barman-cloud-plugin-0.12.0.yaml`
- `application.crds.yaml`
- `crds/` directory

Add to repo:
- `vendir.yml`
- `vendir.lock.yml` (from a local `vendir sync` run before this commit)
- `vendored/` tree with all base files and kustomization.yamls
- `application.vendored-cnpg.yaml`
- `application.vendored-barman-cloud-plugin.yaml`
- `application.vendored-cert-manager.yaml`
- `application.vendored-contour.yaml`
- `application.vendored-external-secrets-crds.yaml`

Commit and push. Wait for all new vendored Applications to reach `Synced/Healthy` in ArgoCD. Monitor for errors — if a new Application fails to sync, investigate before proceeding to Push 3.

### Push 3 — Restore pruning

In `application.vmubtkube-a.yaml`:
- Restore `resources-finalizer.argocd.argoproj.io`
- Set `syncPolicy.automated.prune: true`

Commit and push.

---

## Renovate Changes

### kubernetes manager — remove vendored files from scan

Remove `cert-manager`, `barman-cloud-plugin-.+`, `cnpg-.+`, and `contour` from `kubernetes.managerFilePatterns`. These files no longer exist as editable manifests.

`vendored/*/base/` is not in any existing pattern and needs no explicit exclusion.

### Remove cert-manager image grouping rule

The `packageRule` grouping the four `quay.io/jetstack/cert-manager-*` images (with comment "still requires re-downloading cert-manager.yaml from GitHub releases") is removed. vendir replaces the entire cert-manager bundle atomically; no individual image tracking is needed.

### Add vendir packageRules

```json
{
  "matchManagers": ["vendir"],
  "matchPackageNames": ["cloudnative-pg/cloudnative-pg"],
  "groupName": "cnpg-operator"
},
{
  "matchManagers": ["vendir"],
  "matchPackageNames": ["cloudnative-pg/cloudnative-pg-plugin-barman-cloud"],
  "groupName": "barman-cloud-plugin"
},
{
  "matchManagers": ["vendir"],
  "matchPackageNames": ["cert-manager/cert-manager"],
  "groupName": "cert-manager"
},
{
  "matchManagers": ["vendir"],
  "matchPackageNames": ["projectcontour/contour"],
  "groupName": "contour"
},
{
  "matchManagers": ["vendir"],
  "matchPackageNames": ["external-secrets/external-secrets"],
  "groupName": "external-secrets-crds"
}
```

The `vendir` manager is enabled by `config:recommended` and matches `**/vendir.yml` by default. No explicit manager config is needed.

### postUpgradeTasks — run vendir sync after version bumps

```json
"postUpgradeTasks": {
  "commands": ["vendir sync"],
  "fileFilters": ["vendored/**", "vendir.lock.yml"],
  "executionMode": "branch",
  "installTools": ["vendir"]
}
```

`installTools: ["vendir"]` tells Renovate to download the vendir binary before running commands. `executionMode: branch` runs once per PR branch rather than once per updated package. The updated `vendored/*/base/` files and `vendir.lock.yml` are staged and included in the Renovate PR.

**Verification required**: The Mend Renovate cloud app's support for `postUpgradeTasks` is not explicitly documented for the free tier. `vendir` appears in the `installTools` allowlist, indicating it is intended to work. Confirm empirically by watching the first Renovate PR after migration — if the vendir-synced base files are absent from the PR, fall back to the Woodpecker CI approach described below.

**Woodpecker fallback** (if postUpgradeTasks doesn't fire on cloud): Add a `vendir-sync` step to `.woodpecker.yaml` that runs only when `vendir.yml` changes, executes `vendir sync`, and commits `vendored/` + `vendir.lock.yml` back to the PR branch using Woodpecker's `CI_NETRC_*` env vars for git auth. Pin the vendir binary version with a `# renovate: datasource=github-releases depName=vmware-tanzu/carvel-vendir` annotation.
