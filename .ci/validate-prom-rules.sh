#!/bin/sh
set -euo pipefail

# Checks every PrometheusRule with promtool and runs the rule unit tests:
#   1. extract .spec of each PrometheusRule into <namespace>/<name>.yaml
#   2. promtool check rules on each extracted file (syntax, PromQL, templates)
#   3. promtool test rules on .ci/test/prom-rules/*.test.yaml
#
# Object discovery has two modes:
#   PROM_OBJECTS=<file>  JSON array of every object ArgoCD applies, written by
#                        .ci/validate-prom-selectors.sh (PROM_OBJECTS_OUT).
#                        Includes Helm-rendered rules (kube-prometheus-stack).
#                        The CI step uses this, so nothing is rendered twice.
#   unset                hand-written manifests, kustomize overlays, and plain
#                        vendored bases, gathered the same way as
#                        .ci/validate-prom-selectors.sh but without Helm
#                        rendering (fast enough for the pre-commit hook).
#
# Unit tests reference rule files by "<namespace>/<metadata.name>.yaml" in
# rule_files; they run from the extracted rules directory, so that path is the
# PrometheusRule's identity, not its path in this repo. Add a test by dropping
# a new <name>.test.yaml next to the existing ones.
#
# PROMTOOL overrides the binary (default: promtool on PATH).

PROMTOOL=${PROMTOOL:-promtool}
if ! command -v "$PROMTOOL" >/dev/null 2>&1; then
  echo "ERROR: promtool not found (install it from the Prometheus release" >&2
  echo "tarball, or point PROMTOOL at the binary)" >&2
  exit 1
fi
CI_DIR=$(cd "$(dirname "$0")" && pwd)
TEST_DIR="$CI_DIR/test/prom-rules"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
RULES_DIR="$WORKDIR/rules"
mkdir -p "$RULES_DIR"

# --- object discovery ----------------------------------------------------------
ALL_JSON="$WORKDIR/all.json"
if [ -n "${PROM_OBJECTS:-}" ]; then
  if [ ! -s "$PROM_OBJECTS" ]; then
    echo "ERROR: PROM_OBJECTS=$PROM_OBJECTS is missing or empty" >&2
    echo "(it is written by .ci/validate-prom-selectors.sh via PROM_OBJECTS_OUT)" >&2
    exit 1
  fi
  cp "$PROM_OBJECTS" "$ALL_JSON"
else
  NDJSON="$WORKDIR/objects.ndjson"
  : > "$NDJSON"
  # collect_stream <yaml-file> <source-label>: one JSON object per line,
  # tagged with where it came from for error messages.
  collect_stream() {
    yq -o=json '.' "$1" \
      | jq -c --arg src "$2" 'select(type == "object") | ._ci_source = $src' >> "$NDJSON"
  }
  if command -v kustomize >/dev/null 2>&1; then
    kustomize_build() { kustomize build "$1"; }
  else
    kustomize_build() { kubectl kustomize "$1"; }
  fi
  # Same enumeration as .ci/validate.sh / .ci/validate-prom-selectors.sh.
  for kz in $(git ls-files '*/kustomization.yaml' | grep -v '/base/'); do
    dir=$(dirname "$kz")
    kustomize_build "$dir" > "$WORKDIR/kustomized.yaml"
    collect_stream "$WORKDIR/kustomized.yaml" "kustomize $dir"
  done
  for base in vendored/*/base; do
    overlay=$(dirname "$base")
    [ -f "$overlay/kustomization.yaml" ] && continue
    [ -f "$base/Chart.yaml" ] && continue
    for f in "$base"/*.yaml; do
      collect_stream "$f" "$f"
    done
  done
  for f in $(git ls-files '*.yaml' \
    | grep -vE '^(vendored/|fluentbit/|homelab-pki/|docs/|\.|renovate\.json|vendir)' \
    | grep -v 'kustomization\.yaml'); do
    collect_stream "$f" "$f"
  done
  jq -s '.' < "$NDJSON" > "$ALL_JSON"
fi

# --- 1. extract rule files -----------------------------------------------------
# "<namespace>/<name>\t<source>" per PrometheusRule. A missing namespace is
# reported by validate-prom-selectors; here it just lands under _/.
jq -r '
  .[] | select(.kind == "PrometheusRule"
               and (.apiVersion // "" | startswith("monitoring.coreos.com/")))
  | "\(.metadata.namespace // "_")/\(.metadata.name)\t\(._ci_source // "?")"' \
  "$ALL_JSON" > "$WORKDIR/index.tsv"

DUPES=$(cut -f1 "$WORKDIR/index.tsv" | sort | uniq -d)
if [ -n "$DUPES" ]; then
  echo "ERROR: PrometheusRule namespace/name defined more than once:" >&2
  printf '%s\n' "$DUPES" >&2
  exit 1
fi

while IFS="$(printf '\t')" read -r id _src; do
  mkdir -p "$RULES_DIR/${id%/*}"
  jq --arg ns "${id%/*}" --arg n "${id#*/}" '
    .[] | select(.kind == "PrometheusRule"
                 and (.metadata.namespace // "_") == $ns and .metadata.name == $n)
    | .spec' "$ALL_JSON" | yq -P '.' > "$RULES_DIR/$id.yaml"
done < "$WORKDIR/index.tsv"

# --- 2. promtool check rules -------------------------------------------------
total=0
failed=0
while IFS="$(printf '\t')" read -r id src; do
  total=$((total + 1))
  # Lint findings (duplicate recording rules) warn but don't fail: the
  # kube-prometheus-stack chart ships one in kube-apiserver-availability.rules
  # that this repo can't change.
  if out=$(cd "$RULES_DIR" && "$PROMTOOL" check rules "$id.yaml" 2>&1); then
    case "$out" in
      *"lint error"*)
        echo "warn $id ($src)"
        printf '%s\n' "$out" | sed 's/^/     /' ;;
      *) echo "ok   $id ($src)" ;;
    esac
  else
    failed=$((failed + 1))
    echo "FAIL $id ($src)" >&2
    printf '%s\n' "$out" | sed 's/^/     /' >&2
  fi
done < "$WORKDIR/index.tsv"

if [ "$total" -eq 0 ]; then
  echo "ERROR: no PrometheusRule objects found; discovery is broken" >&2
  exit 1
fi
if [ "$failed" -ne 0 ]; then
  echo "ERROR: $failed of $total PrometheusRule(s) failed promtool check rules" >&2
  exit 1
fi
echo "All $total PrometheusRules pass promtool check rules."

# --- 3. promtool test rules --------------------------------------------------
set -- "$TEST_DIR"/*.test.yaml
if [ ! -e "$1" ]; then
  echo "No rule unit tests in $TEST_DIR."
  exit 0
fi
for t in "$@"; do
  cp "$t" "$RULES_DIR/"
done
(cd "$RULES_DIR" && for t in "$@"; do basename "$t"; done | xargs "$PROMTOOL" test rules)
echo "All rule unit tests passed."
