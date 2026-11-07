#!/bin/sh
set -euo pipefail

# Materializes the caches every other validating step reads, so exactly one pod
# writes them:
#
#   $SCHEMA_MIRROR     kubeconform schema mirrors (.ci/sync-schemas.sh)
#   $HELM_CHART_CACHE  Helm chart tarballs (.ci/lib/render-helm.sh)
#
# All step pods of a workflow share one workspace PVC, so the caches are visible
# to the steps that depend_on this one. Both used to be built implicitly by
# whichever step got there first: validate.sh and validate-helm.sh each ran
# sync-schemas.sh within the same second of the pipeline starting, and
# validate-helm.sh plus validate-prom-selectors.sh each pulled all 27 Helm
# charts straight from upstream (~54 downloads per pipeline, no retry).
#
# Runs as a step of its own (see the DAG note in .woodpecker.yaml). The
# consumers still call sync-schemas.sh themselves, which is a no-op once warm,
# so nothing here is required for pre-commit or for running one script by hand.

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
SELFDIR=$(dirname "$0")

if [ -n "${SCHEMA_MIRROR:-}" ]; then
  echo "=== schema mirrors ($SCHEMA_MIRROR) ==="
  sh "$SELFDIR/sync-schemas.sh"
fi

# shellcheck disable=SC1091
. "$SELFDIR/lib/render-helm.sh"

if [ -n "${HELM_CHART_CACHE:-}" ]; then
  echo "=== helm chart cache ($HELM_CHART_CACHE) ==="
  # prime_app_charts pulls one tarball per chart+version and fails on a chart
  # that cannot be fetched, which is the point: better a clear failure here than
  # two render steps racing the same upstream repo later.
  extract_apps "$WORKDIR/apps" > "$WORKDIR/apps.txt"
  prime_app_charts "$WORKDIR/apps.txt"
  echo "chart cache holds $(find "$HELM_CHART_CACHE" -maxdepth 1 -name '*.tgz' | wc -l) tarballs"
fi

echo "Caches ready."
