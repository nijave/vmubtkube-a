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
# $HELM_CHART_CACHE (optional)
#   When set to a directory, charts are pulled into it as `<chart>-<version>.tgz`
#   and rendered from there instead of being fetched per render. Callers that
#   render the same Applications concurrently (validate-helm.sh and
#   validate-prom-selectors.sh both render all 27 Helm apps) then share one set
#   of downloads, and .ci/prepare-cache.sh can prime the cache from a single pod
#   so neither of them touches the network. Unset locally, nothing changes.
#
# helm_retry <attempts> <command...>
#   Runs a network-bound helm command with linear backoff. Chart repos are
#   third-party services that fail transiently — validate-helm has failed on
#   `charts.external-secrets.io` and `open-telemetry.github.io` index fetches
#   dying with "context deadline exceeded" after helm's client timeout.
#
# chart_tarball <repoURL> <chart> <version>
#   Prints the local tarball for <chart>@<version>, pulling it into
#   $HELM_CHART_CACHE first if it isn't there yet (HTTP and OCI charts alike).
#
# prime_app_charts <apps.txt>
#   Pulls every Helm-source Application's chart into $HELM_CHART_CACHE. Reads
#   the "<source-file> <app-doc-file>" list produced by extract_apps.
#
# render_helm_app <app_doc_file>
#   Renders one Application doc (a single-doc file; YAML or JSON — yq reads
#   both) to stdout the way ArgoCD does: helm template with the app's
#   valuesObject, release name, and destination namespace, plus the
#   discovered capabilities, or the app's spec.source.helm.apiVersions when
#   set (ArgoCD then uses that list instead of the cluster's). Return codes:
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

helm_retry() {
  attempts=$1
  shift
  n=1
  while :; do
    if "$@"; then
      return 0
    fi
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    delay=$((n * 5))
    echo "helm_retry: attempt $n/$attempts failed; retrying in ${delay}s" >&2
    sleep "$delay"
    n=$((n + 1))
  done
}

chart_tarball() {
  _repo=$1
  _chart=$2
  _version=$3
  _dir=${HELM_CHART_CACHE:?chart_tarball needs HELM_CHART_CACHE}
  mkdir -p "$_dir"
  _tarball="$_dir/$_chart-$_version.tgz"
  if [ -f "$_tarball" ]; then
    echo "$_tarball"
    return 0
  fi
  # Pull into a private directory and rename into place: two steps sharing the
  # cache can miss the same chart at the same moment, and a half-written shared
  # tarball would break every later render.
  _tmp="$_dir/.pull.$$"
  rm -rf "$_tmp"
  mkdir -p "$_tmp"
  # OCI pulls print "Pulled:/Digest:" chatter to stdout, which would corrupt the
  # tarball path printed below.
  _rc=0
  case "$_repo" in
    http*) helm_retry 3 helm pull --repo "$_repo" "$_chart" --version "$_version" -d "$_tmp" >/dev/null || _rc=$? ;;
    *) helm_retry 3 helm pull "oci://$_repo/$_chart" --version "$_version" -d "$_tmp" >/dev/null || _rc=$? ;;
  esac
  if [ "$_rc" -ne 0 ]; then
    rm -rf "$_tmp"
    return 1
  fi
  # A version range (e.g. "2.x") resolves upstream, so glob instead of assuming
  # the requested version ends up in the file name. The temp dir is private to
  # this call, so the first match is the only chart that was fetched.
  set -- "$_tmp/$_chart"-*.tgz
  if [ ! -f "$1" ]; then
    rm -rf "$_tmp"
    return 1
  fi
  mv "$1" "$_tarball"
  rm -rf "$_tmp"
  echo "$_tarball"
}

prime_app_charts() {
  : "${HELM_CHART_CACHE:?prime_app_charts needs HELM_CHART_CACHE}"
  while read -r _f app_doc <&3; do
    chart=$(yq '.spec.source.chart // ""' "$app_doc")
    # git-source Applications render from a vendored chart on disk, nothing to pull
    [ -n "$chart" ] || continue
    repo=$(yq '.spec.source.repoURL' "$app_doc")
    version=$(yq '.spec.source.targetRevision' "$app_doc")
    echo "chart cache: $chart@$version" >&2
    chart_tarball "$repo" "$chart" "$version" >/dev/null || return 1
  done 3< "$1"
}

render_helm_app() {
  app_doc=$1
  [ -n "$app_doc" ] || return 1
  [ -d "${RENDER_TMPDIR:-}" ] || {
    echo "render_helm_app: RENDER_TMPDIR is not set to an existing directory" >&2
    return 2
  }
  caps=$(yq '.spec.source.helm.apiVersions // [] | .[]' "$app_doc" \
    | sed 's/^/--api-versions /' | tr '\n' ' ')
  caps=${caps:-$API_VERSIONS}

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
      --kube-version "$KUBE_VERSION" $caps || return 2
    return 0
  fi

  repo=$(yq '.spec.source.repoURL' "$app_doc")
  version=$(yq '.spec.source.targetRevision' "$app_doc")
  release=$(yq '.spec.source.helm.releaseName // .metadata.name' "$app_doc")
  namespace=$(yq '.spec.destination.namespace // "default"' "$app_doc")
  yq '.spec.source.helm.valuesObject // {}' "$app_doc" > "$RENDER_TMPDIR/values.yaml"
  if [ -n "${HELM_CHART_CACHE:-}" ]; then
    # Serve the chart from the shared cache instead of a per-render download.
    chart_ref=$(chart_tarball "$repo" "$chart" "$version") || return 2
    repo_flag=""
  else
    case "$repo" in
      http*) chart_ref="$chart"; repo_flag="--repo $repo" ;;
      *)
        # Pull OCI charts first and template the local tarball: some helm
        # versions print registry pull chatter (Pulled:/Digest:) to stdout,
        # which corrupts the piped manifest stream.
        helm_retry 3 helm pull "oci://$repo/$chart" --version "$version" -d "$RENDER_TMPDIR" >/dev/null || return 2
        chart_ref="$RENDER_TMPDIR/$chart-$version.tgz"; repo_flag=""
        ;;
    esac
  fi
  # shellcheck disable=SC2086
  helm_retry 3 helm template "$release" "$chart_ref" $repo_flag \
    --version "$version" --namespace "$namespace" \
    --values "$RENDER_TMPDIR/values.yaml" \
    --kube-version "$KUBE_VERSION" $caps || return 2
}
