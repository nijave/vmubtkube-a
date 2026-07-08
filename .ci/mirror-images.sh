#!/bin/sh
# Mirror images referenced as registry.apps.nickv.me/<path>:<tag> from their
# upstream registries to the local registry.
#
# Source of truth for upstream coordinates is renovate.json:
#   - registryAliases["registry.apps.nickv.me"] -> default upstream registry
#   - packageRules[].matchPackageNames + registryUrls -> per-image overrides
#   - ignoreDeps -> mirror paths to skip (locally-built images)
# plus `# renovate: ... registryUrl=<url> depName=<name>` annotations in the
# manifests themselves (used where renovate's registryAliases can't express
# the upstream, e.g. thanos/thanos living on quay.io).
#
# Convention assumed: the mirror path equals the upstream repo path, so e.g.
# registry.apps.nickv.me/thanos/thanos is copied from quay.io/thanos/thanos.
# Bare-name mirrors (registry.apps.nickv.me/thanos) will resolve against the
# default upstream and almost certainly fail — rename them to org/image first.
#
# Only mirrors refs that appear on lines *added* since the diff base:
#   - pull_request: origin/$CI_COMMIT_TARGET_BRANCH
#   - push:         $CI_COMMIT_BEFORE
#   - otherwise:    HEAD^
#
# Requires: yq (mikefarah), jq, regctl, git, grep, sort, awk, sed, comm.
set -euo pipefail

MIRROR_REG="registry.apps.nickv.me"
BUILDKIT_FILE="woodpecker/buildkit.woodpecker.yaml"
RENOVATE_FILE="renovate.json"

for cmd in yq jq regctl git grep sort awk sed comm; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 1; }
done

# Pull the registry's self-signed CA out of the buildkitd-config ConfigMap and
# point regctl at it. Single source of truth for the cert.
CA_DIR=$(mktemp -d)
OVERRIDES=$(mktemp)
IGNORE=$(mktemp)
REFS=$(mktemp)
RAW_DIFF=$(mktemp)
trap 'rm -rf "$CA_DIR" "$OVERRIDES" "$IGNORE" "$REFS" "$RAW_DIFF"' EXIT
yq ea '
  select(.kind == "ConfigMap" and .metadata.name == "buildkitd-config")
  | .data["'"$MIRROR_REG"'.crt"]
' "$BUILDKIT_FILE" > "$CA_DIR/$MIRROR_REG.crt"
if [ ! -s "$CA_DIR/$MIRROR_REG.crt" ]; then
  echo "failed to extract $MIRROR_REG CA cert from $BUILDKIT_FILE" >&2
  exit 1
fi
regctl registry set "$MIRROR_REG" --cacert "$(cat "$CA_DIR/$MIRROR_REG.crt")"

strip_url() { printf '%s' "$1" | sed -E 's|^https?://||; s|/.*$||'; }

DEFAULT_UPSTREAM=$(jq -r --arg r "$MIRROR_REG" '.registryAliases[$r] // empty' "$RENOVATE_FILE")
if [ -z "$DEFAULT_UPSTREAM" ]; then
  echo "renovate.json has no registryAliases[$MIRROR_REG]" >&2
  exit 1
fi
DEFAULT_HOST=$(strip_url "$DEFAULT_UPSTREAM")

# Override map: matchPackageNames entry -> upstream registry host. Skips rules
# with no registryUrls (those are pure grouping/description rules).
jq -r '
  .packageRules[]?
  | select(.registryUrls and (.registryUrls | length) > 0)
  | .registryUrls[0] as $url
  | (.matchPackageNames // [])[]
  | "\(.) \($url)"
' "$RENOVATE_FILE" | while read -r name url; do
  printf '%s %s\n' "$name" "$(strip_url "$url")"
done > "$OVERRIDES"

# Manifest annotations are a second override source: renovate rules that are
# handled by the regex manager (e.g. thanos/thanos) carry their upstream in a
# `# renovate: ... registryUrl=... depName=...` comment instead of
# packageRules registryUrls. packageRules entries stay first in the file, so
# they win the awk first-match lookup below.
grep -rh --include='*.yaml' --include='*.yml' -E '#[[:space:]]*renovate:.*registryUrl=' . 2>/dev/null \
  | awk '{
      url = ""; name = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^registryUrl=/) url = substr($i, 13)
        if ($i ~ /^depName=/) name = substr($i, 9)
      }
      if (url != "" && name != "") print name, url
    }' \
  | sort -u | while read -r name url; do
      printf '%s %s\n' "$name" "$(strip_url "$url")"
    done >> "$OVERRIDES"

jq -r '.ignoreDeps[]? // empty' "$RENOVATE_FILE" > "$IGNORE"

# Pick a diff base appropriate for the trigger, then mirror refs found on
# added lines only. Re-runs against the same base are idempotent (regctl copy
# no-ops when digests match).
case "${CI_PIPELINE_EVENT:-}" in
  pull_request)
    target_branch="${CI_COMMIT_TARGET_BRANCH:-main}"
    # depth=100 covers main's history back ~3-4 weeks at typical merge rates,
    # enough for nearly all PRs (Renovate bot PRs are <5 commits ahead).
    # If the merge-base falls outside this, the git-diff check below fails
    # loudly with a clear error rather than silently producing empty refs.
    git fetch --no-tags --depth=100 origin "$target_branch" >/dev/null 2>&1 || true
    BASE_REF="origin/$target_branch"
    ;;
  push)
    if [ -n "${CI_COMMIT_BEFORE:-}" ] \
       && [ "$CI_COMMIT_BEFORE" != "0000000000000000000000000000000000000000" ]; then
      BASE_REF="$CI_COMMIT_BEFORE"
    else
      BASE_REF="HEAD^"
    fi
    ;;
  *)
    BASE_REF="${BASE_REF:-HEAD^}"
    ;;
esac

echo "diff base: $BASE_REF"
# Detect git diff failure explicitly — without this, a missing merge-base
# (e.g. shallow clone) silently produces empty $REFS and CI passes with
# mirrored=0 failed=0, masking the failure.
# Restrict to YAML: docs (*.md) legitimately quote mirror refs in prose and
# must not trigger mirroring.
if ! git diff --unified=0 "$BASE_REF"...HEAD -- '*.yaml' '*.yml' > "$RAW_DIFF" 2>&1; then
  echo "ERROR: git diff against $BASE_REF failed:" >&2
  cat "$RAW_DIFF" >&2
  exit 1
fi
# Extract mirror refs from added lines. grep returns 1 when there are no
# matches, which is legitimate (a PR with no mirror image changes) — guard
# with `|| true` so pipefail doesn't treat it as a failure.
#
# This only catches the single-line `image: registry/repo:tag` style (e.g.
# the thanos manifests). Charts that split the reference across sibling
# `registry:`/`tag:` keys (e.g. democratic-csi's valuesObject, which Helm
# concatenates itself) never produce a line containing both the path and the
# tag, so they're invisible to this regex — handled separately below.
grep -E '^\+[^+]' "$RAW_DIFF" \
  | grep -oE "$MIRROR_REG/[A-Za-z0-9._/-]+:[A-Za-z0-9._+-]+" \
  | sort -u > "$REFS" || true

# Extract refs expressed as sibling `registry:`/`tag:` keys anywhere in
# changed YAML files (any nesting depth — e.g. Helm valuesObject blocks).
# Compare old vs new file content and keep only refs that are new or changed,
# mirroring the "added lines only" behavior of the regex extraction above.
YQ_REGISTRY_TAG_REFS='[.. | select(tag == "!!map" and has("registry") and has("tag")) | select(.registry | test("^'"$MIRROR_REG"'(/|$)")) | (.registry + ":" + (.tag | tostring))] | .[]'
git diff --name-only --diff-filter=d "$BASE_REF"...HEAD -- '*.yaml' | while IFS= read -r f; do
  [ -n "$f" ] || continue
  OLD_YAML=$(mktemp)
  git show "$BASE_REF:$f" > "$OLD_YAML" 2>/dev/null || : > "$OLD_YAML"
  yq eval-all "$YQ_REGISTRY_TAG_REFS" "$OLD_YAML" 2>/dev/null | sort -u > "$OLD_YAML.refs" || true
  yq eval-all "$YQ_REGISTRY_TAG_REFS" "$f" 2>/dev/null | sort -u > "$OLD_YAML.new" || true
  comm -13 "$OLD_YAML.refs" "$OLD_YAML.new" 2>/dev/null >> "$REFS" || true
  rm -f "$OLD_YAML" "$OLD_YAML.refs" "$OLD_YAML.new"
done
sort -u -o "$REFS" "$REFS"

mirrored=0
skipped=0
failed=0

while IFS= read -r full; do
  [ -n "$full" ] || continue
  target=${full%%:*}
  tag=${full#*:}
  repo=${target#"$MIRROR_REG/"}

  if grep -qxF "$target" "$IGNORE"; then
    echo "skip $full (ignoreDeps)"
    skipped=$((skipped + 1))
    continue
  fi

  host=$(awk -v key="$repo" '$1 == key { print $2; exit }' "$OVERRIDES")
  [ -n "$host" ] || host="$DEFAULT_HOST"

  src="$host/$repo:$tag"
  echo "==> $src -> $full"
  if regctl image copy "$src" "$full"; then
    mirrored=$((mirrored + 1))
  else
    echo "FAILED: $src -> $full" >&2
    failed=$((failed + 1))
  fi
done < "$REFS"

echo
echo "mirrored=$mirrored skipped=$skipped failed=$failed"
[ "$failed" -eq 0 ]
