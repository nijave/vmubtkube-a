#!/bin/sh
set -euo pipefail

# Validates every manifest ArgoCD will apply, the same way ArgoCD renders it:
#   1. hand-written manifests            -> kubeconform directly
#   2. dirs with a kustomization.yaml    -> kustomize build | kubeconform
#   3. vendored bases without an overlay -> kubeconform directly
#
# -skip CustomResourceDefinition: the strict schema set has no usable schema
# for the CRD kind itself (kubernetes-json-schema gap); CRD contents are
# upstream-generated anyway. The CRDs-catalog location validates our CRs
# (Application, ExternalSecret, HTTPProxy, Cluster, VPA, ...).
# Match validation to the live cluster version (cukk auto-upgrades the
# cluster, so never hardcode it). Works in CI step pods via the default SA
# (GET /version is allowed by system:public-info-viewer) and locally via
# kubeconfig; falls back to master schemas when no cluster is reachable.
if [ -z "${KUBE_VERSION:-}" ]; then
  KUBE_VERSION=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
  KUBE_VERSION=${KUBE_VERSION#v}
fi
export KUBE_VERSION

# Prefer local schema mirrors (see sync-schemas.sh): kubeconform re-requests
# every miss on every run (CR kinds 404 the default location regardless of
# -cache) and raw.githubusercontent.com is flaky. The mirrors are complete
# copies of both upstream repos, so when they're usable we validate against
# them exclusively — offline and deterministic; a kind absent upstream is a
# miss either way. Anything else falls back to the remote locations.
# A version-agnostic fallback: the master-standalone-strict directory is kept
# current upstream and carries every built-in kind regardless of released patch.
# This catches the race where cukk upgrades the cluster to a brand-new patch
# (e.g. 1.35.7) before yannh/kubernetes-json-schema publishes that patch's
# schema dir — both the mirror and the version-keyed remote default 404 in
# lockstep, so without this escape hatch every built-in kind errors as "could
# not find schema". master tracks the latest Kubernetes, but built-in kinds are
# structurally stable across patches, so it's a safe match for any recent patch.
MASTER_STRICT_FALLBACK="-schema-location https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json"

SCHEMA_LOCATIONS="
  -schema-location default
  -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
  $MASTER_STRICT_FALLBACK"
if [ -n "${SCHEMA_MIRROR:-}" ]; then
  sh "$(dirname "$0")/sync-schemas.sh" \
    || echo "WARNING: schema mirror sync failed; continuing with what's on disk" >&2
  if [ -n "$KUBE_VERSION" ] \
    && [ -d "$SCHEMA_MIRROR/kubernetes-json-schema/v${KUBE_VERSION}-standalone-strict" ] \
    && [ -d "$SCHEMA_MIRROR/CRDs-catalog/.git" ]; then
    # Mirror first (offline, deterministic); master-standalone-strict (local if
    # synced, else remote) as the escape hatch for a missing patch schema dir.
    SCHEMA_LOCATIONS="
  -schema-location $SCHEMA_MIRROR/kubernetes-json-schema/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json
  -schema-location $SCHEMA_MIRROR/kubernetes-json-schema/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json
  -schema-location $SCHEMA_MIRROR/CRDs-catalog/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
  $MASTER_STRICT_FALLBACK"
  else
    echo "WARNING: schema mirror unusable; validating against remote locations" >&2
  fi
fi

KUBECONFORM="kubeconform
  -strict -summary
  -skip CustomResourceDefinition
  $SCHEMA_LOCATIONS"

if [ -n "$KUBE_VERSION" ]; then
  echo "validating against Kubernetes $KUBE_VERSION"
  KUBECONFORM="$KUBECONFORM -kubernetes-version $KUBE_VERSION"
else
  echo "WARNING: cluster version undetectable; validating against master schemas"
fi

# Cache downloaded schemas across runs (used by the pre-commit hook; CI pods
# are ephemeral so caching there is pointless).
if [ -n "${KUBECONFORM_CACHE:-}" ]; then
  mkdir -p "$KUBECONFORM_CACHE"
  KUBECONFORM="$KUBECONFORM -cache $KUBECONFORM_CACHE"
fi

# alpine/k8s ships a kustomize binary; local machines may only have kubectl.
if command -v kustomize >/dev/null 2>&1; then
  kustomize_build() { kustomize build "$1"; }
else
  kustomize_build() { kubectl kustomize "$1"; }
fi

echo "=== hand-written manifests ==="
# Everything tracked except: vendored inputs (validated rendered below),
# kustomize-rendered dirs, kustomization files themselves, and non-k8s YAML.
git ls-files '*.yaml' \
  | grep -vE '^(vendored/|fluentbit/|docs/|\.|renovate\.json|vendir)' \
  | grep -v 'kustomization\.yaml' \
  | xargs $KUBECONFORM

echo "=== kustomize overlays ==="
for kz in $(git ls-files '*/kustomization.yaml' | grep -v '/base/'); do
  dir=$(dirname "$kz")
  echo "--- $dir"
  kustomize_build "$dir" | $KUBECONFORM -
done

echo "=== plain vendored bases (no overlay) ==="
for base in vendored/*/base; do
  overlay=$(dirname "$base")
  [ -f "$overlay/kustomization.yaml" ] && continue
  [ -f "$base/Chart.yaml" ] && continue   # Helm chart base; rendered by .ci/validate-helm.sh
  echo "--- $base"
  $KUBECONFORM "$base"/*.yaml
done

echo "All manifests valid."
