#!/bin/sh
# Mirror images referenced as registry.apps.nickv.me/<path>:<tag> from their
# upstream registries to the local registry.
#
# Source of truth for upstream coordinates is renovate.json:
#   - registryAliases["registry.apps.nickv.me"] -> default upstream registry
#   - packageRules[].matchPackageNames + registryUrls -> per-image overrides
#   - ignoreDeps -> mirror paths to skip (locally-built images)
#
# Convention assumed: the mirror path equals the upstream repo path, so e.g.
# registry.apps.nickv.me/thanos/thanos is copied from quay.io/thanos/thanos.
# Bare-name mirrors (registry.apps.nickv.me/thanos) will resolve against the
# default upstream and almost certainly fail — rename them to org/image first.
#
# Requires: yq (mikefarah), jq, regctl, grep, sort, awk, sed.
set -eu

MIRROR_REG="registry.apps.nickv.me"
BUILDKIT_FILE="woodpecker/buildkit.woodpecker.yaml"
RENOVATE_FILE="renovate.json"

for cmd in yq jq regctl grep sort awk sed; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 1; }
done

# Pull the registry's self-signed CA out of the buildkitd-config ConfigMap and
# point regctl at it via REG_CERT_DIR. Single source of truth for the cert.
CA_DIR="${CA_DIR:-/tmp/mirror-ca}"
mkdir -p "$CA_DIR"
yq ea '
  select(.kind == "ConfigMap" and .metadata.name == "buildkitd-config")
  | .data["'"$MIRROR_REG"'.crt"]
' "$BUILDKIT_FILE" > "$CA_DIR/$MIRROR_REG.crt"
if [ ! -s "$CA_DIR/$MIRROR_REG.crt" ]; then
  echo "failed to extract $MIRROR_REG CA cert from $BUILDKIT_FILE" >&2
  exit 1
fi
export REG_CERT_DIR="$CA_DIR"

strip_url() { printf '%s' "$1" | sed -E 's|^https?://||; s|/.*$||'; }

DEFAULT_UPSTREAM=$(jq -r --arg r "$MIRROR_REG" '.registryAliases[$r] // empty' "$RENOVATE_FILE")
if [ -z "$DEFAULT_UPSTREAM" ]; then
  echo "renovate.json has no registryAliases[$MIRROR_REG]" >&2
  exit 1
fi
DEFAULT_HOST=$(strip_url "$DEFAULT_UPSTREAM")

OVERRIDES=$(mktemp)
IGNORE=$(mktemp)
REFS=$(mktemp)
trap 'rm -f "$OVERRIDES" "$IGNORE" "$REFS"' EXIT

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

jq -r '.ignoreDeps[]? // empty' "$RENOVATE_FILE" > "$IGNORE"

# Find every registry.apps.nickv.me/<repo>:<tag> reference across the repo.
grep -rEohI "$MIRROR_REG/[A-Za-z0-9._/-]+:[A-Za-z0-9._+-]+" \
  --include='*.yaml' --include='*.yml' . \
  | sort -u > "$REFS"

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
