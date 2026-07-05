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
# Match the live cluster version (cukk auto-upgrades it); CI step pods can
# GET /version via the default SA (system:public-info-viewer), local runs use
# kubeconfig. Falls back to a pinned floor when no cluster is reachable.
if [ -z "${KUBE_VERSION:-}" ]; then
  KUBE_VERSION=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
  KUBE_VERSION=${KUBE_VERSION#v}
fi
[ -n "$KUBE_VERSION" ] || { echo "WARNING: cluster version undetectable; using fallback"; KUBE_VERSION="1.35.0"; }
echo "rendering against Kubernetes $KUBE_VERSION"

# Discover the cluster's API versions (group/version plus group/version/Kind,
# matching what ArgoCD passes) so .Capabilities-gated templates render exactly
# what the cluster gets. Needs only the discovery endpoints, which
# system:discovery grants to every authenticated principal — no extra RBAC.
API_VERSIONS=$( {
  kubectl api-versions 2>/dev/null
  kubectl api-resources --no-headers 2>/dev/null | awk '{print $(NF-2)"/"$NF}'
} | sort -u | sed 's/^/--api-versions /' | tr '\n' ' ' ) || true
if [ -z "$API_VERSIONS" ]; then
  echo "WARNING: API discovery unavailable; using fallback capability list"
  API_VERSIONS="--api-versions autoscaling.k8s.io/v1 --api-versions monitoring.coreos.com/v1"
fi

# -ignore-missing-schemas: charts ship CRs of their own CRDs (rendered in the
# same release) that the CRDs-catalog may not carry; missing-schema kinds are
# reported in the summary as skipped, not failed.
KUBECONFORM="kubeconform
  -strict -summary
  -ignore-missing-schemas
  -skip CustomResourceDefinition
  -kubernetes-version $KUBE_VERSION
  -schema-location default
  -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
if [ -n "${KUBECONFORM_CACHE:-}" ]; then
  mkdir -p "$KUBECONFORM_CACHE"
  KUBECONFORM="$KUBECONFORM -cache $KUBECONFORM_CACHE"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

APP_Q='select(.kind=="Application")'
rendered=0
for f in application.*.yaml; do
  # Extract the Application doc first: applying `// {}` fallbacks directly to
  # a multi-doc file emits one fallback per filtered-out document.
  yq "$APP_Q" "$f" > "$WORKDIR/app.yaml"
  chart=$(yq '.spec.source.chart // ""' "$WORKDIR/app.yaml")
  [ -z "$chart" ] && continue   # git-source app; covered by validate.sh

  repo=$(yq '.spec.source.repoURL' "$WORKDIR/app.yaml")
  version=$(yq '.spec.source.targetRevision' "$WORKDIR/app.yaml")
  release=$(yq '.spec.source.helm.releaseName // .metadata.name' "$WORKDIR/app.yaml")
  namespace=$(yq '.spec.destination.namespace // "default"' "$WORKDIR/app.yaml")
  yq '.spec.source.helm.valuesObject // {}' "$WORKDIR/app.yaml" > "$WORKDIR/values.yaml"

  echo "--- $f ($chart@$version)"
  case "$repo" in
    http*) chart_ref="$chart"; repo_flag="--repo $repo" ;;
    *)
      # Pull OCI charts first and template the local tarball: some helm
      # versions print registry pull chatter (Pulled:/Digest:) to stdout,
      # which corrupts the piped manifest stream.
      helm pull "oci://$repo/$chart" --version "$version" -d "$WORKDIR" >/dev/null
      chart_ref="$WORKDIR/$chart-$version.tgz"; repo_flag=""
      ;;
  esac
  # shellcheck disable=SC2086
  helm template "$release" "$chart_ref" $repo_flag \
    --version "$version" --namespace "$namespace" \
    --values "$WORKDIR/values.yaml" --include-crds \
    --kube-version "$KUBE_VERSION" $API_VERSIONS \
    | $KUBECONFORM -
  rendered=$((rendered + 1))
done

echo "All $rendered Helm applications rendered and validated."
