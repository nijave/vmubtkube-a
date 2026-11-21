#!/bin/sh
# Fail the PR when it introduces a container image reference whose tag/digest
# does not exist in its registry.
#
# Why: Renovate (hosted Mend app) bumps tags by tracking GitHub releases, but
# the release and the image are published independently — e.g. immich v3.4.2
# was released on GitHub while ghcr.io/immich-app/immich-machine-learning:
# v3.4.2-openvino was never pushed (their build failed). Renovate cannot run
# post-upgrade commands, Mergify auto-merged on green CI, and the pod sat in
# ImagePullBackOff. This step probes each NEW image ref in the diff with
# `regctl manifest head` so such a PR goes red and Mergify's ci/woodpecker
# requirement blocks the merge.
#
# Strictly diff-scoped: only refs that are NEW relative to the diff base
# (.ci/lib/diff-base.sh) and only in YAML files changed by the diff. A PR
# touching no image refs makes zero registry requests.
#
# Skipped on purpose:
#   - refs under registry.apps.nickv.me: the mirror is populated by
#     mirror-images.sh in this same pipeline, so probing it here would race it
#   - refs with no tag and no digest (chart default tag; nothing to verify)
#   - templated values ({{ ... }} or $...)
#   - values that are URLs with a scheme (http://, https://, oci://)
#
# Requires: yq (mikefarah), git, regctl. POSIX sh, busybox-compatible (the CI
# image is alpine: no grep --include, no bash-isms).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REGCTL="${REGCTL:-regctl}"
# Backoff between registry probes; overridable so tests can run fast.
RETRY_SLEEP="${RETRY_SLEEP:-2}"

for cmd in yq git "$REGCTL"; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 1; }
done

# shellcheck source=lib/diff-base.sh disable=SC1091
. "$SCRIPT_DIR/lib/diff-base.sh"
compute_diff_base

ERR=$(mktemp)
BASE_REFS=$(mktemp)
HEAD_REFS=$(mktemp)
NEW_REFS=$(mktemp)
CHECK_REFS=$(mktemp)
trap 'rm -f "$ERR" "$BASE_REFS" "$HEAD_REFS" "$NEW_REFS" "$CHECK_REFS"' EXIT

# shellcheck disable=SC2153  # BASE_REF is set by compute_diff_base (lib)
echo "diff base: $BASE_REF"
# Detect git diff failure explicitly — without this, a missing merge-base
# (e.g. shallow clone) silently produces an empty file list and CI passes
# having checked nothing.
if ! FILES=$(git diff --name-only --diff-filter=d "$BASE_REF"...HEAD -- '*.yaml' '*.yml' 2> "$ERR"); then
  echo "ERROR: git diff against $BASE_REF failed:" >&2
  cat "$ERR" >&2
  exit 1
fi
# Compare file contents at the merge-base, the same point the three-dot diff
# above uses. Against the target branch tip, a ref that main changed after
# the PR branched would look new and be probed for nothing.
MERGE_BASE=$(git merge-base "$BASE_REF" HEAD)

# Ref forms extracted per YAML version (eval-all: manifests are multi-doc):
#   - any string scalar of a key named `image` (single-line ref, e.g.
#     `image: alpine/k8s:1.37.2`, `image: foo@sha256:...`)
#   - any map with `repository` + `tag` (optionally `registry`), the Helm
#     valuesObject style — e.g. immich's
#     image: {repository: ghcr.io/immich-app/immich-server, tag: v3.4.2}.
#     A tag may carry a digest (`9.2-alpine@sha256:...`), which concatenates
#     into repository:tag@digest. Maps with `registry` + `tag` but no
#     `repository` are NOT extracted: `registry:tag` is not a valid ref and
#     mirror-images.sh already owns the sibling-key layout for the mirror.
YQ_SCALAR_IMAGE='[.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")] | .[]'
YQ_REPO_TAG='[.. | select(tag == "!!map" and has("repository") and has("tag") and (.tag != null) and (.repository | tag == "!!str") and ((.tag | tostring | length) > 0)) | ((select(.registry | tag == "!!str" and . != "") | .registry + "/") // "") + .repository + ":" + (.tag | tostring)] | .[]'

# A git diff failure above is fatal, but a file that cannot be parsed as YAML
# is not this step's problem (validate steps own that): treat unparseable as
# no refs, like mirror-images.sh does.
extract() {
  # extract <file> <outfile>: all refs present in that YAML version
  _file=$1
  _out=$2
  if [ -s "$_file" ]; then
    {
      yq eval-all "$YQ_SCALAR_IMAGE" "$_file" 2>/dev/null || true
      yq eval-all "$YQ_REPO_TAG" "$_file" 2>/dev/null || true
    } | sort -u > "$_out"
  else
    : > "$_out"
  fi
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  BASE_VER=$(mktemp)
  HEAD_VER=$(mktemp)
  git show "$MERGE_BASE:$f" > "$BASE_VER" 2>/dev/null || : > "$BASE_VER"
  cp "$f" "$HEAD_VER"
  extract "$BASE_VER" "$BASE_REFS"
  extract "$HEAD_VER" "$HEAD_REFS"
  rm -f "$BASE_VER" "$HEAD_VER"
  # comm -13: refs in HEAD but not in the base = introduced by this diff
  comm -13 "$BASE_REFS" "$HEAD_REFS" >> "$NEW_REFS" || true
done <<EOF
$FILES
EOF

# Dedupe across files (the per-file comm only compares each file against its
# own base version; the same ref may appear in several files).
sort -u "$NEW_REFS" | while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    # Templated: the real value only exists after Helm render (or at runtime)
    *'{{'*|*'$'*)
      echo "skip $ref (templated)" >&2
      continue
      ;;
    # Local mirror: mirror-images.sh populates it in this same pipeline;
    # probing it here would race that step.
    registry.apps.nickv.me | registry.apps.nickv.me/*)
      echo "skip $ref (local mirror)" >&2
      continue
      ;;
    # A URL is not an image ref
    http://* | https://* | oci://*)
      echo "skip $ref (URL scheme)" >&2
      continue
      ;;
  esac
  # Tag or digest required: a bare `image: repo/name` (chart default tag)
  # cannot be verified. For a digest ref the `@` settles it; otherwise the
  # last path segment must have a non-empty tag (a colon before the last /
  # is a registry port, not a tag).
  case "$ref" in
    *@*) ;;
    *)
      seg=${ref##*/}
      tag=${seg#*:}
      if [ "$tag" = "$seg" ] || [ -z "$tag" ]; then
        echo "skip $ref (no tag/digest)" >&2
        continue
      fi
      ;;
  esac
  printf '%s\n' "$ref"
done > "$CHECK_REFS"

checked=0
missing=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  checked=$((checked + 1))
  ok=0
  attempt=1
  # Retry to absorb transient registry/network errors; a genuinely missing
  # tag fails all 3 attempts.
  while [ "$attempt" -le 3 ]; do
    if "$REGCTL" manifest head "$ref" >/dev/null 2>&1; then
      ok=1
      break
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] && sleep "$RETRY_SLEEP"
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok      $ref"
  else
    echo "MISSING $ref"
    missing=$((missing + 1))
  fi
done < "$CHECK_REFS"

echo
echo "checked=$checked missing=$missing"
# All refs are checked even when some are missing, so one bad tag reports
# every problem in the PR, not just the first.
[ "$missing" -eq 0 ]
