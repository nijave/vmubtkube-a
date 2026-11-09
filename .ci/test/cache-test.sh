#!/bin/sh
set -eu

# Hermetic tests for .ci/lib/cache.sh: no network, no S3. Every helper takes
# directories, so temporary git repos and fake caches are enough.
# Run: sh .ci/test/cache-test.sh

cd "$(dirname "$0")/../.."
# pre-commit exports an absolute GIT_DIR/GIT_WORK_TREE for the hook's checkout,
# and those take precedence over `git -C`, so every temporary repo below would
# silently operate on this repository instead (same trap .ci/sync-schemas.sh
# documents). Drop them so -C is honoured.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
# shellcheck disable=SC1091
. .ci/lib/cache.sh

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

make_repo() {
  # make_repo <dir> [sparse-pattern...]: one commit, optionally a non-cone
  # sparse checkout like the mirrors sync-schemas.sh builds.
  _dir=$1
  shift
  mkdir -p "$_dir"
  git -C "$_dir" init -q
  git -C "$_dir" config user.email "ci@test"
  git -C "$_dir" config user.name "ci"
  echo '{}' > "$_dir/root.json"
  mkdir -p "$_dir/v1.99.0-standalone-strict"
  echo '{}' > "$_dir/v1.99.0-standalone-strict/pod.json"
  git -C "$_dir" add -A
  git -C "$_dir" commit -qm init
  if [ "$#" -gt 0 ]; then
    git -C "$_dir" sparse-checkout set --no-cone "$@"
  fi
}

# 1. a cold cache is a no-op, not an error
mkdir -p "$TMP/cold/schemas"
cache_restore_schemas "$TMP/m1" "$TMP/cold"
[ ! -d "$TMP/m1/kubernetes-json-schema/.git" ] || fail "cold restore created a repo"
ok "cold restore is a no-op"

# 2. a warm cache materialises the worktree
make_repo "$TMP/seed/kubernetes-json-schema"
mkdir -p "$TMP/warm/schemas"
tar -C "$TMP/seed/kubernetes-json-schema" -cf "$TMP/warm/schemas/kubernetes-json-schema.git.tar" .git
cache_restore_schemas "$TMP/m2" "$TMP/warm"
[ -f "$TMP/m2/kubernetes-json-schema/v1.99.0-standalone-strict/pod.json" ] \
  || fail "warm restore did not materialise the worktree"
ok "warm restore materialises the worktree"

# 3. restoring keeps the sparse-checkout config sync-schemas.sh relies on
make_repo "$TMP/seed-sparse/kubernetes-json-schema" "/v1.99.0-standalone-strict/*"
mkdir -p "$TMP/warm-sparse/schemas"
tar -C "$TMP/seed-sparse/kubernetes-json-schema" -cf "$TMP/warm-sparse/schemas/kubernetes-json-schema.git.tar" .git
cache_restore_schemas "$TMP/m3" "$TMP/warm-sparse"
grep -q "v1.99.0-standalone-strict" "$TMP/m3/kubernetes-json-schema/.git/info/sparse-checkout" \
  || fail "restore lost the sparse-checkout config"
ok "restore keeps the sparse-checkout config"

# 4. a truncated tarball is a miss, never a half-initialised repo
mkdir -p "$TMP/bad/schemas"
printf 'not a tar' > "$TMP/bad/schemas/kubernetes-json-schema.git.tar"
cache_restore_schemas "$TMP/m4" "$TMP/bad" 2>/dev/null || true
[ ! -e "$TMP/m4/kubernetes-json-schema/.git" ] || fail "corrupt tarball left a .git behind"
ok "corrupt tarball leaves no repo"

# 5. the first export writes both the tarball and the head
mkdir -p "$TMP/empty-in"
cache_export_schemas "$TMP/seed" "$TMP/empty-in" "$TMP/out1"
[ -f "$TMP/out1/schemas/kubernetes-json-schema.git.tar" ] || fail "first export skipped the tarball"
[ -f "$TMP/out1/schemas/kubernetes-json-schema.head" ] || fail "first export skipped the head"
ok "first export writes tarball and head"

# 6. an unchanged head is not re-exported
cache_export_schemas "$TMP/seed" "$TMP/out1" "$TMP/out2"
[ ! -f "$TMP/out2/schemas/kubernetes-json-schema.git.tar" ] || fail "unchanged head re-exported"
ok "unchanged head does not re-export"

# 7. head without tarball (interrupted save) is re-exported
mkdir -p "$TMP/head-only/schemas"
cp "$TMP/out1/schemas/kubernetes-json-schema.head" "$TMP/head-only/schemas/"
cache_export_schemas "$TMP/seed" "$TMP/head-only" "$TMP/out3"
[ -f "$TMP/out3/schemas/kubernetes-json-schema.git.tar" ] || fail "missing tarball was not re-exported"
ok "missing tarball with a matching head is re-exported"

# 8. a new commit is re-exported
echo '{"changed":true}' > "$TMP/seed/kubernetes-json-schema/root.json"
git -C "$TMP/seed/kubernetes-json-schema" commit -qam change
cache_export_schemas "$TMP/seed" "$TMP/out1" "$TMP/out4"
[ -f "$TMP/out4/schemas/kubernetes-json-schema.git.tar" ] || fail "changed head did not re-export"
ok "changed head re-exports"

echo "all cache tests passed"
