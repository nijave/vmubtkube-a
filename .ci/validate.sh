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
KUBECONFORM="kubeconform
  -strict -summary
  -skip CustomResourceDefinition
  -schema-location default
  -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"

# Match validation to the live cluster version (cukk auto-upgrades the
# cluster, so never hardcode it). Works in CI step pods via the default SA
# (GET /version is allowed by system:public-info-viewer) and locally via
# kubeconfig; falls back to master schemas when no cluster is reachable.
if [ -z "${KUBE_VERSION:-}" ]; then
  KUBE_VERSION=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
  KUBE_VERSION=${KUBE_VERSION#v}
fi
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
  echo "--- $base"
  $KUBECONFORM "$base"/*.yaml
done

echo "All manifests valid."
