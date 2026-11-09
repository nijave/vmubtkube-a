#!/bin/sh
set -euo pipefail

# Uploads what `.prepare` staged. Additive only (rclone copy never deletes), so
# a bad run can leave a stale object behind but can never remove a good one.
# Runs with `failure: ignore`.
CACHE=${CI_CACHE_BUCKET:-cicache:ci-cache}
RCLONE="rclone --retries 2 --low-level-retries 2 --timeout 30s --contimeout 10s"

# Count each directory only when it exists: `set -e` plus `pipefail` would abort
# on a `find` over a directory that a failed prepare never created.
count_files() {
  _dir=$1
  shift
  [ -d "$_dir" ] || { echo 0; return 0; }
  find "$_dir" -type f "$@" | wc -l
}

STAGED=$(count_files .tmp/cache-out)
if [ -d .tmp/charts ]; then
  $RCLONE copy .tmp/charts "$CACHE/charts"
fi
if [ -d .tmp/cache-out/schemas ]; then
  $RCLONE copy .tmp/cache-out/schemas "$CACHE/schemas"
fi
if [ -d .tmp/cache-out/tools ]; then
  $RCLONE copy .tmp/cache-out/tools "$CACHE/tools"
fi
echo "cache saved: $STAGED staged objects, $(count_files .tmp/charts -name '*.tgz') charts in the workspace"
