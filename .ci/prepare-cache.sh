#!/bin/sh
set -euo pipefail

# Materializes the caches every other validating step reads, so exactly one pod
# writes them:
#
#   $SCHEMA_MIRROR     kubeconform schema mirrors (.ci/sync-schemas.sh)
#   $HELM_CHART_CACHE  Helm chart tarballs (.ci/lib/render-helm.sh)
#
# All step pods of a workflow share one workspace PVC, so the caches are visible
# to the steps that depend_on this one. Since the caches are also restored from
# and saved to the rustfs bucket (see .ci/cache-restore.sh / .ci/cache-save.sh),
# this script has a strict input/output contract:
#
#   .tmp/cache-in/   what the restore step downloaded (may be empty)
#   .tmp/cache-out/  what the save step must upload (staged here)
#
# Design: docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# The consumers still call sync-schemas.sh themselves, which is a no-op once
# warm, so nothing here is required for pre-commit or for running one script by
# hand.

SELFDIR=$(dirname "$0")
CACHE_IN=${CI_CACHE_IN:-.tmp/cache-in}
CACHE_OUT=${CI_CACHE_OUT:-.tmp/cache-out}

# shellcheck disable=SC1091
. "$SELFDIR/lib/cache.sh"

mkdir -p "$CACHE_OUT"

if [ -n "${SCHEMA_MIRROR:-}" ]; then
  echo "=== schema mirrors ($SCHEMA_MIRROR) ==="
  # Object directories only (tens of MB): the checkout is rebuilt locally,
  # because kubeconform needs the files on disk either way.
  cache_restore_schemas "$SCHEMA_MIRROR" "$CACHE_IN"
  sh "$SELFDIR/sync-schemas.sh"
  cache_export_schemas "$SCHEMA_MIRROR" "$CACHE_IN" "$CACHE_OUT"
fi

# shellcheck disable=SC1091
. "$SELFDIR/lib/render-helm.sh"

if [ -n "${HELM_CHART_CACHE:-}" ]; then
  echo "=== helm chart cache ($HELM_CHART_CACHE) ==="
  WORKDIR=$(mktemp -d)
  trap 'rm -rf "$WORKDIR"' EXIT
  extract_apps "$WORKDIR/apps" > "$WORKDIR/apps.txt"
  prime_app_charts "$WORKDIR/apps.txt"
  echo "chart cache holds $(find "$HELM_CHART_CACHE" -maxdepth 1 -name '*.tgz' | wc -l) tarballs"
fi

echo "Caches ready."
