# vendir + kustomize migration — implementation notes

Companion to `2026-07-01-vendir-kustomize-design.md`. Captures corrections and
deviations discovered during implementation, plus the verified push sequence.

## Scope actually migrated

| Component | Status | Notes |
|---|---|---|
| CNPG | ✅ migrated | byte-identical to current (v1.30.0) — purely mechanical |
| cert-manager | ✅ migrated | **stale-render refresh**: current is the v1.19.1 manifest with 3 images bumped to 1.20.3; vendoring refreshes CRDs/RBAC to true v1.20.3 (images already 1.20.3). No local config lost. |
| Barman Cloud Plugin | ✅ migrated | **stale-render refresh**: current is the 0.12.0 manifest with image bumped to 0.13.0; vendoring refreshes CRDs to 0.13.0 (adds `restoreAdditionalCommandArgs`, `lz4`). No local config lost. |
| external-secrets CRDs | ✅ migrated | **stale-render refresh**: current has 23 CRDs from an older ESO release; vendoring brings v2.7.0 (24 CRDs). Matches the chart 2.7.0 operator. |
| Contour | ✅ migrated | **kustomize overlay** preserving all local config; see contour section below |

**Note on content changes:** only CNPG is byte-identical. cert-manager, barman, and
es-crds all get CRD/manifest refreshes that bring the manifests in line with the
versions already running (their images/chart were previously bumped without
re-downloading the full manifest — the exact staleness this migration fixes).
These refreshes are backward-compatible (additive CRD fields, +1 ESO generator
CRD) and low-risk, but ArgoCD **will** apply CRD updates during Commit 2 — watch
those three apps' sync for any conversion-webhook or schema warnings.

## Corrections to the design spec (factual)

1. **Barman repo slug**: `cloudnative-pg/plugin-barman-cloud` (NOT
   `cloudnative-pg-plugin-barman-cloud`, which 404s). Release asset is
   `manifest.yaml` (NOT `barman-cloud-plugin-*.yaml` — upstream renamed it).
   No checksum file ships → `disableAutoChecksumValidation: true`.
2. **external-secrets**: tag is `v2.7.0` (NOT `v0.14.x` — ESO is at v2.x; chart
   2.7.0 ↔ app/git tag v2.7.0). There is **no CRD-only release asset** — the
   only YAML asset is the full `external-secrets.yaml` (controller + RBAC),
   which would double-deploy alongside the Helm chart. Sourced instead from
   **git** `deploy/crds/bundle.yaml` @ `v2.7.0`.
3. **vendir `includePaths` + `newRootPath`**: this vendir version (0.46.0)
   applies `includePaths` against the **pre-re-root** path. Patterns must use
   the full repo path (`examples/render/contour.yaml`, `deploy/crds/bundle.yaml`),
   not the re-rooted relative path, or the dir is pruned before re-rooting.
4. **Checksum validation**: CNPG/cert-manager/barman all need
   `disableAutoChecksumValidation: true` (vendir's release-notes parser can't
   match their checksums). Integrity is still pinned by `vendir.lock.yml`.

## Deviations from the design spec (judgment calls)

1. **Contour migrated with full kustomize overlay (2026-07-02).** Originally
   deferred because the current `contour.yaml` was a release-1.32 render with
   extensive local ContourConfiguration that a naive overlay would silently drop.
   Migrated in a separate 3-push sequence using:
   - **Strategic merge patch** on the ConfigMap to replace the entire
     `data.contour.yaml` with local config (accesslog format, rateLimitService,
     tracing→otel-collector, policy headers, enableExternalNameService,
     ingress-status-address, metrics).
   - **Strategic merge patches** on the Deployment and DaemonSet for resource
     limits on all 4 containers, envoy image (`registry.apps.nickv.me/envoyproxy/envoy:v1.38.3`,
     non-distroless), and metrics `hostPort: 8002`.
   - **JSON 6902 patches** to change the envoy Service from LoadBalancer→ClusterIP
     and add ArgoCD `Replace=true,Force=true` on the certgen Job.
   - **Separate `envoy-lb` Service** resource for the LoadBalancer with
     `external-dns`, `externalTrafficPolicy: Local`, `allocateLoadBalancerNodePorts: false`.
   - **Versioned certgen Job name** accepted from upstream (`contour-certgen-v1-33-5`);
     old static `contour-certgen` manually deleted after migration.
   - `contour-tracing.yaml` (ExtensionService) stays at root, managed by root app.
   - Renovate: `contour` removed from kubernetes `managerFilePatterns`, added as
     vendir `projectcontour/contour` rule; overlay patch files added to kubernetes
     scan so envoy image bumps are tracked independently.
2. **`mirror-images.sh` not changed.** The envoy image reference is in the
   strategic merge patch file (`patch-envoy-daemonset.yaml`) as a full
   `registry.apps.nickv.me/envoyproxy/envoy:v1.38.3` string on one line, so
   `mirror-images.sh` detects it in the git diff naturally — no kustomize
   `images:` transform to work around.
3. **CRDs repointed, not recreated.** `application.crds.yaml` keeps app identity
   `crds` and just changes `source.path` `crds/` → `vendored/external-secrets-crds/base`.
   The spec's delete-`application.crds.yaml`-+create-new approach would let the
   root app prune the orphaned `crds` Application in Push 3, whose
   `resources-finalizer` would **cascade-delete the ExternalSecret CRD** (data
   loss). Repointing in place deterministically avoids any cascade window.
4. **vendir files excluded from root app.** `vendir.yml` (`kind: Config`) and
   `vendir.lock.yml` (`kind: LockConfig`) sit at repo root and would otherwise be
   synced by the root app as unknown kinds → SyncError. Added to
   `application.vmubtkube-a.yaml` `directory.exclude`.

## Verified push sequences

ArgoCD root app uses `targetRevision: HEAD` (main), so each commit must be
pushed to main one at a time with ArgoCD confirmation between.

### Phase 1 — CNPG, cert-manager, barman, external-secrets CRDs (2026-07-02)

3-push sequence on `feature/vendir-kustomize`, cherry-picked to main:

1. **Disable prune + drop finalizer + exclude vendir files** from root app.
2. **File migration**: delete root YAML files, add `vendir.yml`, `vendir.lock.yml`,
   `vendored/` tree, per-component ArgoCD apps, repoint `application.crds.yaml`,
   update `renovate.json`.
3. **Restore prune + finalizer** on root app.

### Phase 2 — Contour (2026-07-02)

Separate 3-push sequence, committed directly on main:

1. **Disable prune + drop finalizer** on root app.
2. **File migration**: delete `contour.yaml` from root, add
   `vendored/contour/{kustomization.yaml,patch-*.yaml,envoy-lb-service.yaml}`,
   `application.vendored-contour.yaml`, update `renovate.json`. Manually deleted
   orphaned `contour-certgen` Job after new versioned Job completed.
3. **Restore prune + finalizer** on root app.

## Renovate caveats
- ~~`postUpgradeTasks` (vendir sync) support on the Mend free tier is unverified~~
  **Resolved:** Renovate's vendir manager has a built-in `updateArtifacts` step
  that runs `vendir sync` automatically (same pattern as npm lock files or Helm
  Chart.lock). `postUpgradeTasks` is self-hosted only, but irrelevant — the
  artifact updater handles syncing `vendored/*/base` files into the PR natively.
- The external-secrets CRD git ref bumps independently of the Helm chart and can
  drift; review CRD bumps against `application.external-secrets.yaml` chart version.
- vendir `matchPackageNames` use the repo slug as depName; confirm against the
  first Renovate run if grouping doesn't apply.
