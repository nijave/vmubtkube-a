# Shared Helm rendering helpers for ArgoCD Application docs.
# shellcheck shell=sh disable=SC2034  # HELM_*_FALLBACK are read by callers
#
# Sourced (not executed) by .ci/validate-helm.sh and
# .ci/validate-prom-selectors.sh so both render Applications exactly the way
# ArgoCD does, without duplicating the chart-source handling: HTTP repo charts
# (template with --repo), OCI charts (pull-then-template, so registry pull
# chatter can't corrupt the piped manifest stream), and git-source apps whose
# path is a local vendored chart (Chart.yaml with deps built into charts/).
#
# helm_init_caps
#   Discovers the live cluster version and API versions so
#   .Capabilities-gated templates render the objects the cluster actually
#   gets, into $KUBE_VERSION and $API_VERSIONS. Needs only discovery
#   endpoints, which system:discovery / system:public-info-viewer grant to
#   every authenticated principal — no extra RBAC. HELM_KUBE_FALLBACK /
#   HELM_API_FALLBACK are set (non-empty) when a fallback was used, so
#   callers can warn.
#
# render_helm_app <app_doc_file>
#   Renders one Application doc (a single-doc file; YAML or JSON — yq reads
#   both) to stdout the way ArgoCD does: helm template with the app's
#   valuesObject, release name, and destination namespace, plus the
#   discovered capabilities. Return codes:
#     0  rendered (stdout carries the manifest stream)
#     1  not a Helm-source Application (git source without a local Chart.yaml
#        — plain manifests, kustomize, or no doc at all)
#     2  helm failed (its error output is already on stderr)
#   Scratch space is $RENDER_TMPDIR (caller creates and cleans it up);
#   $KUBE_VERSION / $API_VERSIONS come from helm_init_caps.
#
# extract_apps <outdir>
#   Writes every ArgoCD Application doc in the tracked manifests to its own
#   single-doc file under <outdir> and prints "<source-file> <app-doc-file>"
#   per Application. Applications live anywhere ArgoCD reads (subdirectories,
#   files not named application.*.yaml, several per file), so this scans every
#   tracked yaml outside vendored/ and docs/. Single-doc output matters: the
#   per-field yq queries in render_helm_app emit one result per document.

extract_apps() {
  mkdir -p "$1"
  n=0
  for f in $(git ls-files '*.yaml' | grep -vE '^(vendored/|docs/)'); do
    count=$(yq ea '[select(.kind == "Application")] | length' "$f")
    i=0
    while [ "$i" -lt "$count" ]; do
      n=$((n + 1))
      yq ea "[select(.kind == \"Application\")] | .[$i]" "$f" > "$1/app-$n.yaml"
      echo "$f $1/app-$n.yaml"
      i=$((i + 1))
    done
  done
}

helm_init_caps() {
  if [ -z "${KUBE_VERSION:-}" ]; then
    KUBE_VERSION=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
    KUBE_VERSION=${KUBE_VERSION#v}
  fi
  if [ -z "$KUBE_VERSION" ]; then
    HELM_KUBE_FALLBACK=1
    KUBE_VERSION="1.35.0"
  fi
  API_VERSIONS=$( {
    kubectl api-versions 2>/dev/null
    kubectl api-resources --no-headers 2>/dev/null | awk '{print $(NF-2)"/"$NF}'
  } | sort -u | sed 's/^/--api-versions /' | tr '\n' ' ' ) || true
  if [ -z "$API_VERSIONS" ]; then
    HELM_API_FALLBACK=1
    API_VERSIONS="--api-versions autoscaling.k8s.io/v1 --api-versions monitoring.coreos.com/v1"
  fi
}

render_helm_app() {
  app_doc=$1
  [ -n "$app_doc" ] || return 1
  [ -d "${RENDER_TMPDIR:-}" ] || {
    echo "render_helm_app: RENDER_TMPDIR is not set to an existing directory" >&2
    return 2
  }

  chart=$(yq '.spec.source.chart // ""' "$app_doc")
  if [ -z "$chart" ]; then
    # git-source app. If its path is a vendored Helm chart (local Chart.yaml
    # with its deps built into charts/), render it from disk the way ArgoCD
    # does; anything else is plain manifests / kustomize, not ours.
    path=$(yq '.spec.source.path // ""' "$app_doc")
    [ -n "$path" ] && [ -f "$path/Chart.yaml" ] || return 1
    release=$(yq '.spec.source.helm.releaseName // .metadata.name' "$app_doc")
    namespace=$(yq '.spec.destination.namespace // "default"' "$app_doc")
    yq '.spec.source.helm.valuesObject // {}' "$app_doc" > "$RENDER_TMPDIR/values.yaml"
    # shellcheck disable=SC2086
    helm template "$release" "$path" --namespace "$namespace" \
      --values "$RENDER_TMPDIR/values.yaml" \
      --kube-version "$KUBE_VERSION" $API_VERSIONS || return 2
    return 0
  fi

  repo=$(yq '.spec.source.repoURL' "$app_doc")
  version=$(yq '.spec.source.targetRevision' "$app_doc")
  release=$(yq '.spec.source.helm.releaseName // .metadata.name' "$app_doc")
  namespace=$(yq '.spec.destination.namespace // "default"' "$app_doc")
  yq '.spec.source.helm.valuesObject // {}' "$app_doc" > "$RENDER_TMPDIR/values.yaml"
  case "$repo" in
    http*) chart_ref="$chart"; repo_flag="--repo $repo" ;;
    *)
      # Pull OCI charts first and template the local tarball: some helm
      # versions print registry pull chatter (Pulled:/Digest:) to stdout,
      # which corrupts the piped manifest stream.
      helm pull "oci://$repo/$chart" --version "$version" -d "$RENDER_TMPDIR" >/dev/null || return 2
      chart_ref="$RENDER_TMPDIR/$chart-$version.tgz"; repo_flag=""
      ;;
  esac
  # shellcheck disable=SC2086
  helm template "$release" "$chart_ref" $repo_flag \
    --version "$version" --namespace "$namespace" \
    --values "$RENDER_TMPDIR/values.yaml" \
    --kube-version "$KUBE_VERSION" $API_VERSIONS || return 2
}
