#!/bin/sh
set -euo pipefail

# Fails when a prometheus-operator selectable resource (ServiceMonitor,
# PodMonitor, Probe, ScrapeConfig, PrometheusRule, AlertmanagerConfig) is
# selected by no instance (Prometheus, PrometheusAgent, ThanosRuler,
# Alertmanager) — e.g. a ServiceMonitor missing the release: prom label every
# monitor in this repo is expected to carry. The matcher
# (.ci/prom-selectors.jq) implements operator semantics over one JSON array of
# EVERY object ArgoCD applies, gathered the same way .ci/validate.sh gathers
# them for kubeconform:
#   1. hand-written manifests            -> parsed directly
#   2. dirs with a kustomization.yaml    -> kustomize build
#   3. vendored bases without an overlay -> parsed directly
#   4. Helm-source Applications          -> rendered like .ci/validate-helm.sh
# Step 4 is not optional: the "prom" Prometheus CR (selectors release: prom)
# only exists in the kube-prometheus-stack render (application.kube-prometheus.yaml).
#
# Namespace defaulting: objects from Helm renders and kustomize overlays that
# don't set metadata.namespace get the owning Application's
# spec.destination.namespace (overlays are mapped to Applications by
# spec.source.path) — that's where ArgoCD deploys them. Hand-written root
# manifests belong to application.vmubtkube-a.yaml, which has NO destination
# namespace, so a monitoring.coreos.com resource without metadata.namespace
# there can't be placed at all and is reported as an error in its own right.
#
# A chart monitor that values can't fix or disable can still be dropped by
# pinning the Application's spec.source.helm.apiVersions (see
# application.volsync.yaml); the render honors that list like ArgoCD does.
#
# Application discovery scans every tracked yaml (excluding vendored/ and
# docs/), handling multi-doc files: Applications also live in subdirectories
# (immich/, woodpecker/, operators/), which the root application.*.yaml glob
# misses.

# --- cluster capabilities for Helm rendering (shared helper) -----------------
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/render-helm.sh"
helm_init_caps
if [ -n "${HELM_KUBE_FALLBACK:-}" ]; then
  echo "WARNING: cluster version undetectable; using fallback $KUBE_VERSION" >&2
fi
if [ -n "${HELM_API_FALLBACK:-}" ]; then
  echo "WARNING: API discovery unavailable; using fallback capability list" >&2
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RENDER_TMPDIR="$WORKDIR/render"
mkdir -p "$RENDER_TMPDIR"
NDJSON="$WORKDIR/objects.ndjson"

# collect_stream <yaml-file> <default-namespace>
#   Parse every document in the file into one JSON object per line and append
#   to $NDJSON. Objects without metadata.namespace inherit <default-namespace>
#   when it's non-empty (that's the destination namespace ArgoCD deploys into).
collect_stream() {
  yq -o=json '.' "$1" \
    | jq -c --arg ns "$2" '
        select(type == "object")
        | if $ns != "" and .metadata.namespace == null
          then .metadata.namespace = $ns
          else . end' >> "$NDJSON"
}

# --- Application discovery (shared with validate-helm.sh) -------------------
extract_apps "$WORKDIR/apps" > "$WORKDIR/apps.txt"
APPS_JSON="$WORKDIR/apps.json"
while read -r _ app <&3; do
  yq -o=json '.' "$app"
done 3< "$WORKDIR/apps.txt" | jq -s '.' > "$APPS_JSON"

# ns_for_path <dir>: destination namespace of the Application whose
# spec.source.path is <dir> ("" when there is no such Application, or the
# Application has no destination namespace).
ns_for_path() {
  jq -r --arg p "${1%/}" '
    [ .[] | select((.spec.source.path // "" | sub("/$"; "")) == $p) ]
    | if length > 0 then (.[0].spec.destination.namespace // "") else "" end' \
    "$APPS_JSON"
}

# --- 1. Helm-source Applications --------------------------------------------
while read -r _ app <&3; do
  name=$(yq '.metadata.name' "$app")
  destns=$(yq '.spec.destination.namespace // "default"' "$app")
  rc=0
  render_helm_app "$app" > "$WORKDIR/rendered.yaml" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "--- helm app $name"
    collect_stream "$WORKDIR/rendered.yaml" "$destns"
  elif [ "$rc" -ne 1 ]; then
    echo "ERROR: helm render failed for Application $name" >&2
    exit "$rc"
  fi
done 3< "$WORKDIR/apps.txt"

# --- 2. kustomize overlays (same loop as .ci/validate.sh) --------------------
if command -v kustomize >/dev/null 2>&1; then
  kustomize_build() { kustomize build "$1"; }
else
  kustomize_build() { kubectl kustomize "$1"; }
fi
for kz in $(git ls-files '*/kustomization.yaml' | grep -v '/base/'); do
  dir=$(dirname "$kz")
  echo "--- kustomize $dir"
  default_ns=$(ns_for_path "$dir")
  kustomize_build "$dir" > "$WORKDIR/kustomized.yaml"
  collect_stream "$WORKDIR/kustomized.yaml" "$default_ns"
done

# --- 3. plain vendored bases (same loop as .ci/validate.sh) ------------------
for base in vendored/*/base; do
  overlay=$(dirname "$base")
  [ -f "$overlay/kustomization.yaml" ] && continue
  [ -f "$base/Chart.yaml" ] && continue   # Helm chart base; rendered above
  echo "--- vendored base $base"
  for f in "$base"/*.yaml; do
    collect_stream "$f" ""
  done
done

# --- 4. hand-written manifests (same enumeration as .ci/validate.sh) ---------
echo "--- hand-written manifests"
# Everything tracked except: vendored inputs (collected above), kustomize-
# rendered dirs, kustomization files themselves, and non-k8s YAML. No namespace
# defaulting: the root Application (application.vmubtkube-a.yaml) has no
# destination namespace, so a missing namespace on a namespaced resource is
# itself an error, caught by the no-namespace check below.
for f in $(git ls-files '*.yaml' \
  | grep -vE '^(vendored/|fluentbit/|homelab-pki/|docs/|\.|renovate\.json|vendir)' \
  | grep -v 'kustomization\.yaml'); do
  collect_stream "$f" ""
done

ALL_JSON="$WORKDIR/all.json"
jq -s '.' < "$NDJSON" > "$ALL_JSON"

# --- no-namespace check -------------------------------------------------------
# monitoring.coreos.com resources are namespaced; after the defaulting above,
# anything still without metadata.namespace has no destination namespace to
# live in (hand-written root manifests, or an Application with no destination
# namespace) — report it rather than silently treating null as empty.
MISSING_NS=$(jq -r '
  .[] | select(.apiVersion | startswith("monitoring.coreos.com/"))
  | select(.metadata.namespace == null)
  | "\(.kind) \(.metadata.name) (no metadata.namespace)"' "$ALL_JSON" || true)
if [ -n "$MISSING_NS" ]; then
  echo "ERROR: monitoring.coreos.com resources without metadata.namespace" >&2
  echo "(no destination namespace to deploy them into; add one):" >&2
  printf '%s\n' "$MISSING_NS" >&2
  exit 1
fi

# --- run the matcher ----------------------------------------------------------
CI_DIR=$(dirname "$0")
FLAGGED=$(jq -r -f "$CI_DIR/prom-selectors.jq" "$ALL_JSON")
if [ -n "$FLAGGED" ]; then
  echo "ERROR: the following monitoring.coreos.com resources are selected by" >&2
  echo "no Prometheus/PrometheusAgent/ThanosRuler/Alertmanager instance" >&2
  echo "(add a matching instance selector label, e.g. release: prom):" >&2
  printf '%s\n' "$FLAGGED" >&2
  exit 1
fi
echo "Every monitoring.coreos.com resource is selected by an instance."
