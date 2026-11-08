# shellcheck shell=sh
# Helpers for the S3-backed CI cache. Design:
# docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# Contract with the pipeline (paths relative to the workspace):
#   .tmp/cache-in/   written by .ci/cache-restore.sh (rclone download)
#   .tmp/cache-out/  written here, uploaded by .ci/cache-save.sh
#
# Every function must survive a cold, partial or corrupt cache without failing
# the step: the restore/save steps run with `failure: ignore`, and a miss may
# only ever cost time.

# Git exports GIT_DIR/GIT_WORK_TREE to hooks, and those override `git -C` for
# every repository these helpers touch — a poisoned GIT_DIR once let `git init`
# mark the real checkout bare. Clear them for all callers (same guard as
# .ci/sync-schemas.sh).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SCHEMA_REPOS="kubernetes-json-schema CRDs-catalog"

# cache_restore_schemas <mirror-dir> <cache-in-dir>
#   Loads the cached git object directories into the schema mirror and
#   re-creates the worktree from the sparse-checkout config stored inside them,
#   so sync-schemas.sh afterwards only fetches what actually changed.
cache_restore_schemas() {
  _mirror=$1
  _in=$2
  for _repo in $SCHEMA_REPOS; do
    _tar="$_in/schemas/$_repo.git.tar"
    [ -f "$_tar" ] || continue
    mkdir -p "$_mirror/$_repo"
    if ! tar -C "$_mirror/$_repo" -xf "$_tar" 2>/dev/null; then
      echo "cache: $_repo.git.tar is unreadable; discarding it" >&2
      rm -rf "${_mirror:?}/$_repo"
      continue
    fi
    if ! git -C "$_mirror/$_repo" reset --hard HEAD >/dev/null 2>&1; then
      echo "cache: cannot materialise $_repo from cache; discarding it" >&2
      rm -rf "${_mirror:?}/$_repo"
    fi
  done
}

# cache_export_schemas <mirror-dir> <cache-in-dir> <cache-out-dir>
#   Stages <repo>.git.tar for the mirrors whose head changed (or whose tarball
#   the cache does not have — that is how an interrupted save heals), and always
#   stages the head file.
cache_export_schemas() {
  _mirror=$1
  _in=$2
  _out=$3
  mkdir -p "$_out/schemas"
  for _repo in $SCHEMA_REPOS; do
    [ -d "$_mirror/$_repo/.git" ] || continue
    _head=$(git -C "$_mirror/$_repo" rev-parse HEAD)
    _prev=$(cat "$_in/schemas/$_repo.head" 2>/dev/null || echo "")
    if [ "$_head" != "$_prev" ] || [ ! -f "$_in/schemas/$_repo.git.tar" ]; then
      tar -C "$_mirror/$_repo" -cf "$_out/schemas/$_repo.git.tar" .git
      echo "cache: exported $_repo.git.tar ($_head)" >&2
    fi
    echo "$_head" > "$_out/schemas/$_repo.head"
  done
}
