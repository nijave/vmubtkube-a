#!/bin/sh
set -euo pipefail

# Maintains local mirrors of the schema repos kubeconform validates against
# so validate.sh / validate-helm.sh run offline. Two reasons this beats the
# per-URL downloads (even with -cache):
#   1. kubeconform never caches misses, and every CR kind (Application,
#      ExternalSecret, ...) 404s the default schema location before falling
#      through to the CRDs-catalog — hundreds of round-trips per run.
#   2. The downloads hit raw.githubusercontent.com (Fastly CDN), which is a
#      flaky, unauthenticated path. The git smart protocol on github.com is
#      a separate, reliable endpoint and picks up your gh/ssh credentials.
#
# Usage: SCHEMA_MIRROR=.tmp/schemas [KUBE_VERSION=1.35.6] sh .ci/sync-schemas.sh
# Idempotent; no-ops in a few ms once synced. kubernetes-json-schema is a
# blob-less sparse clone holding only the requested version's strict schemas;
# a cluster upgrade just sparse-checkout-adds the new directory.

MIRROR=${SCHEMA_MIRROR:-.tmp/schemas}
KJS="$MIRROR/kubernetes-json-schema"
CRDS="$MIRROR/CRDs-catalog"

if [ -z "${KUBE_VERSION:-}" ]; then
  KUBE_VERSION=$(kubectl version -o json 2>/dev/null | yq '.serverVersion.gitVersion // ""' || true)
  KUBE_VERSION=${KUBE_VERSION#v}
fi
[ -n "$KUBE_VERSION" ] || { echo "sync-schemas: no KUBE_VERSION and no cluster reachable; skipping" >&2; exit 0; }
VDIR="v${KUBE_VERSION}-standalone-strict"

mkdir -p "$MIRROR"

if [ ! -d "$KJS/.git" ]; then
  git clone --quiet --depth 1 --filter=blob:none --no-checkout \
    https://github.com/yannh/kubernetes-json-schema "$KJS"
  git -C "$KJS" sparse-checkout set --no-cone "/$VDIR/*"
  git -C "$KJS" checkout --quiet master
elif [ ! -d "$KJS/$VDIR" ]; then
  git -C "$KJS" sparse-checkout add --no-cone "/$VDIR/*"
fi
if [ ! -d "$KJS/$VDIR" ]; then
  # version directory landed upstream after our pinned commit
  git -C "$KJS" fetch --quiet --depth 1 origin master
  git -C "$KJS" reset --quiet --hard origin/master
fi
[ -d "$KJS/$VDIR" ] \
  || echo "WARNING: kubernetes-json-schema has no $VDIR; kubeconform will fall back to remote" >&2

if [ ! -d "$CRDS/.git" ]; then
  git clone --quiet --depth 1 https://github.com/datreeio/CRDs-catalog "$CRDS"
elif [ ! -f "$CRDS/.git/FETCH_HEAD" ] || [ -n "$(find "$CRDS/.git/FETCH_HEAD" -mtime +7)" ]; then
  # refresh weekly so new CRD versions (renovate chart bumps) keep validating;
  # best-effort — a stale mirror still beats the flaky raw CDN
  if git -C "$CRDS" fetch --quiet --depth 1 origin main; then
    git -C "$CRDS" reset --quiet --hard origin/main
  else
    echo "WARNING: CRDs-catalog refresh failed; using stale mirror" >&2
  fi
fi

echo "schema mirrors ready in $MIRROR ($VDIR)"
