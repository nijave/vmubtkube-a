#!/bin/sh
set -euo pipefail

# Flags apiVersions that are deprecated or removed in the NEXT Kubernetes
# minor, over the same manifest streams as .ci/validate.sh. kubeconform (which
# validates against the CURRENT cluster version) only fails once an API is
# already gone; cukk auto-upgrades the cluster, so this is the pre-upgrade
# warning. Helm-rendered output is covered separately: .ci/validate-helm.sh
# tees its streams through pluto when the binary is present.
#
# Policy: removals in the target version fail; deprecations are printed but
# don't fail (--ignore-deprecations) — they have at least a release of runway.

if ! command -v pluto >/dev/null 2>&1; then
  echo "WARNING: pluto not installed; skipping deprecation checks" >&2
  exit 0
fi

# Target the next minor above the live cluster version (see validate.sh for
# why /version needs no extra RBAC). PLUTO_TARGET overrides, e.g. to test a
# specific upgrade target.
if [ -z "${PLUTO_TARGET:-}" ]; then
  v=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
  v=${v#v}
  if [ -n "$v" ]; then
    PLUTO_TARGET=$(echo "$v" | awk -F. '{printf "v%d.%d.0", $1, $2+1}')
  else
    echo "WARNING: cluster version undetectable; using pluto's default targets"
    PLUTO_TARGET=""
  fi
fi
[ -n "$PLUTO_TARGET" ] && echo "checking deprecations against Kubernetes $PLUTO_TARGET"

PLUTO="pluto detect - --ignore-deprecations ${PLUTO_TARGET:+--target-versions k8s=$PLUTO_TARGET}"

if command -v kustomize >/dev/null 2>&1; then
  kustomize_build() { kustomize build "$1"; }
else
  kustomize_build() { kubectl kustomize "$1"; }
fi

echo "=== hand-written manifests ==="
git ls-files '*.yaml' \
  | grep -vE '^(vendored/|fluentbit/|docs/|\.|renovate\.json|vendir)' \
  | grep -v 'kustomization\.yaml' \
  | xargs awk 'FNR==1 && NR>1 {print "---"} {print}' | $PLUTO

echo "=== kustomize overlays ==="
for kz in $(git ls-files '*/kustomization.yaml' | grep -v '/base/'); do
  dir=$(dirname "$kz")
  echo "--- $dir"
  kustomize_build "$dir" | $PLUTO
done

echo "=== plain vendored bases (no overlay) ==="
for base in vendored/*/base; do
  overlay=$(dirname "$base")
  [ -f "$overlay/kustomization.yaml" ] && continue
  echo "--- $base"
  awk 'FNR==1 && NR>1 {print "---"} {print}' "$base"/*.yaml | $PLUTO
done

echo "No removed APIs for target version."
