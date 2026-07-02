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
| **Contour** | ⏸️ **DEFERRED** | see below |

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

1. **Contour deferred.** The current `contour.yaml` is a **release-1.32 render**
   (controller-gen v0.18.0, header comment `release-1.32`) with only the images
   bumped to v1.33.5 — the exact stale-render problem this migration fixes. But
   it also carries extensive **local ContourConfiguration** the spec didn't
   account for: custom accesslog format, `rateLimitService` (failOpen, x-rate-limit,
   resource-exhausted), `tracing`→otel-collector, `policy` request/response headers,
   `ingress-status-address: contour.k8s.somemissing.info`, `enableExternalNameService`,
   `metrics`, plus envoy pinned at `v1.38.3` (non-distroless; upstream bundles
   `distroless-v1.35.10`) and resource limits on 4 containers. A naive overlay
   (envoy `images:` + resource patches) would silently drop all that production
   config. Contour needs its own focused migration that preserves the
   ContourConfiguration (strategic-merge the ConfigMap data) and refreshes the
   render 1.32→current. **`contour.yaml` and `contour-tracing.yaml` stay at root,
   managed by the root app, and `contour` stays in `renovate.json` kubernetes
   patterns.** No `application.vendored-contour.yaml` is created.
2. **`mirror-images.sh` not changed.** Its fix was driven by contour's kustomize
   `images:` transform. With contour deferred, envoy bumps are still detected
   normally via the literal `registry.apps.nickv.me/...` line in `contour.yaml`.
   Revisit when contour migrates.
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

## Verified push sequence (3 commits on `feature/vendir-kustomize`)

ArgoCD root app uses `targetRevision: HEAD` (main), so each commit must be applied
to main in turn with ArgoCD confirmation between. Cherry-pick each commit to main:

### Commit 1 — harden root app (disable prune, drop finalizer, exclude vendir files)
Edit `application.vmubtkube-a.yaml`: remove `resources-finalizer` from
`metadata.finalizers`; `syncPolicy.automated.prune: true → false`; add
`vendir.yml` / `vendir.lock.yml` to `directory.exclude`.
**After push:** confirm in ArgoCD UI that root app shows `prune: false`.

### Commit 2 — file migration
- Delete: `cnpg-1.30.0.yaml`, `cert-manager.yaml`, `barman-cloud-plugin-0.12.0.yaml`,
  `crds/crd-externalsecrets.yaml` (and `crds/`).
- Add: `vendir.yml`, `vendir.lock.yml`, `vendored/{cnpg,barman-cloud-plugin,cert-manager,external-secrets-crds}/`,
  `application.vendored-{cnpg,barman-cloud-plugin,cert-manager}.yaml`.
- Modify: `application.crds.yaml` (repoint path), `renovate.json`.
- **Unchanged (contour deferred):** `contour.yaml`, `contour-tracing.yaml`, `external-dns.yaml`.
**After push, BEFORE commit 3 — verify in ArgoCD:**
  - `cnpg`, `barman-cloud-plugin`, `cert-manager`, `crds` apps all `Synced` + `Healthy`.
  - No `OutOfSync`/`Degraded` on those apps. CNPG clusters, cert-manager, ESO still healthy.
  - Root app shows the operator resources as gone from its managed set (now owned by the vendored apps).
  - If any vendored app fails to sync, **stop** and investigate before commit 3.

### Commit 3 — restore root app pruning
Edit `application.vmubtkube-a.yaml`: restore `resources-finalizer`;
`syncPolicy.automated.prune: false → true` (vendir excludes remain).
**After push:** confirm root app pruning re-enabled; nothing unexpectedly pruned.

## Renovate caveats
- `postUpgradeTasks` (vendir sync) support on the Mend free tier is unverified —
  watch the first post-migration Renovate PR. If the synced `vendored/*/base`
  files are absent, add the Woodpecker `vendir-sync` fallback from the design spec.
- The external-secrets CRD git ref bumps independently of the Helm chart and can
  drift; review CRD bumps against `application.external-secrets.yaml` chart version.
- vendir `matchPackageNames` use the repo slug as depName; confirm against the
  first Renovate run if grouping doesn't apply.
