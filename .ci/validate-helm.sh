#!/bin/sh
set -euo pipefail

# Renders every Helm-source Application the way ArgoCD does (helm template
# with the app's valuesObject, release name, and namespace) and validates the
# output with kubeconform. Catches chart/values mismatches, values.schema.json
# violations, and template errors before ArgoCD hits them at sync time.
#
# --kube-version / --api-versions approximate the live cluster so charts that
# gate on .Capabilities (e.g. VPA templates) render the same objects ArgoCD
# applies. Bump KUBE_VERSION when the cluster upgrades.
# Chart rendering lives in .ci/lib/render-helm.sh (shared with
# .ci/validate-prom-selectors.sh); this script keeps discovery, validation,
# and deprecation checks.
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/render-helm.sh"
helm_init_caps
if [ -n "${HELM_KUBE_FALLBACK:-}" ]; then
  echo "WARNING: cluster version undetectable; using fallback"
fi
echo "rendering against Kubernetes $KUBE_VERSION"
if [ -n "${HELM_API_FALLBACK:-}" ]; then
  echo "WARNING: API discovery unavailable; using fallback capability list"
fi

# Prefer local schema mirrors when usable, exclusively — same rationale as
# validate.sh (offline, deterministic; the mirrors are complete copies).
# MASTER_STRICT_FALLBACK: version-agnostic escape hatch for the cukk-upgrade
# race (see validate.sh); without it every built-in kind is skipped during the
# window before yannh/kubernetes-json-schema publishes the new patch's dir.
MASTER_STRICT_FALLBACK="-schema-location https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json"
# CRDs-catalog commit pinned for datreeio/CRDs-catalog#991 (see sync-schemas.sh)
SCHEMA_LOCATIONS="
  -schema-location default
  -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/f1e7f6bc0537bf0622ffe6e47dbaa85914fabbec/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
  $MASTER_STRICT_FALLBACK"
if [ -n "${SCHEMA_MIRROR:-}" ]; then
  KUBE_VERSION="$KUBE_VERSION" sh "$(dirname "$0")/sync-schemas.sh" \
    || echo "WARNING: schema mirror sync failed; continuing with what's on disk" >&2
  if [ -d "$SCHEMA_MIRROR/kubernetes-json-schema/v${KUBE_VERSION}-standalone-strict" ] \
    && [ -d "$SCHEMA_MIRROR/CRDs-catalog/.git" ]; then
    SCHEMA_LOCATIONS="
  -schema-location $SCHEMA_MIRROR/kubernetes-json-schema/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json
  -schema-location $SCHEMA_MIRROR/kubernetes-json-schema/master-standalone-strict/{{.ResourceKind}}{{.KindSuffix}}.json
  -schema-location $SCHEMA_MIRROR/CRDs-catalog/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json
  $MASTER_STRICT_FALLBACK"
  else
    echo "WARNING: schema mirror unusable; validating against remote locations" >&2
  fi
fi

# -ignore-missing-schemas: charts ship CRs of their own CRDs (rendered in the
# same release) that the CRDs-catalog may not carry; missing-schema kinds are
# reported in the summary as skipped, not failed.
# lib/render-helm.sh renders without --include-crds: CRDs are skipped anyway,
# and some charts' crds/ (altinity-clickhouse-operator) carry duplicate YAML
# keys that kubeconform can't even parse.
KUBECONFORM="kubeconform
  -strict -summary
  -ignore-missing-schemas
  -skip CustomResourceDefinition
  -kubernetes-version $KUBE_VERSION
  $SCHEMA_LOCATIONS"
if [ -n "${KUBECONFORM_CACHE:-}" ]; then
  mkdir -p "$KUBECONFORM_CACHE"
  KUBECONFORM="$KUBECONFORM -cache $KUBECONFORM_CACHE"
fi

# Also tee rendered output through pluto (deprecated/removed apiVersions in
# the NEXT minor) when the binary is available — charts are the most likely
# place a to-be-removed API hides.
if command -v pluto >/dev/null 2>&1; then
  PLUTO_TARGET="${PLUTO_TARGET:-$(echo "$KUBE_VERSION" | awk -F. '{printf "v%d.%d.0", $1, $2+1}')}"
  echo "checking deprecations against Kubernetes $PLUTO_TARGET"
  PLUTO="pluto detect - --ignore-deprecations --target-versions k8s=$PLUTO_TARGET"
else
  echo "WARNING: pluto not installed; skipping deprecation checks" >&2
  PLUTO=""
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RENDER_TMPDIR="$WORKDIR"  # scratch dir for lib/render-helm.sh
# shellcheck disable=SC2034  # consumed by the sourced helper
export RENDER_TMPDIR

# Every Application doc in the repo, one per file (see extract_apps).
extract_apps "$WORKDIR/apps" > "$WORKDIR/apps.txt"

rendered=0
while read -r f app <&3; do
  chart=$(yq '.spec.source.chart // ""' "$app")
  if [ -n "$chart" ]; then
    header="$chart@$(yq '.spec.source.targetRevision' "$app")"
  else
    # git-source app: only a local vendored chart (Chart.yaml with its deps
    # built into charts/) is Helm; plain manifests are covered by validate.sh.
    path=$(yq '.spec.source.path // ""' "$app")
    [ -n "$path" ] && [ -f "$path/Chart.yaml" ] || continue
    header="local chart $path"
  fi
  echo "--- $f ($header)"
  render_helm_app "$app" > "$WORKDIR/rendered.yaml"
  $KUBECONFORM "$WORKDIR/rendered.yaml"
  [ -n "$PLUTO" ] && $PLUTO < "$WORKDIR/rendered.yaml"
  rendered=$((rendered + 1))
done 3< "$WORKDIR/apps.txt"

echo "All $rendered Helm applications rendered and validated."
