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
KUBE_VERSION="1.35"
API_VERSIONS="--api-versions autoscaling.k8s.io/v1 --api-versions monitoring.coreos.com/v1"

# -ignore-missing-schemas: charts ship CRs of their own CRDs (rendered in the
# same release) that the CRDs-catalog may not carry; missing-schema kinds are
# reported in the summary as skipped, not failed.
KUBECONFORM="kubeconform
  -strict -summary
  -ignore-missing-schemas
  -skip CustomResourceDefinition
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
