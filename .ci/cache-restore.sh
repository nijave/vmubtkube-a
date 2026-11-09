#!/bin/sh
set -euo pipefail

# Restores the S3-backed CI caches into the shared workspace before `prepare`
# runs. Runs with `failure: ignore`: an empty bucket, a cold cache or an
# unreachable rustfs only means the prepare step has to download things again.
# Design: docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md
#
# rclone is configured from RCLONE_CONFIG_CICACHE_* env (.woodpecker.yaml), so a
# missing or rotated credential fails here, in a step that cannot fail the
# pipeline.
#
#   charts/<chart>-<version>.tgz -> .tmp/charts   (helm_chart cache, read by prepare)
#   tools/<name>/<version>/<name> -> .tmp/cache-in/tools
#   schemas/<repo>.git.tar,*.head -> .tmp/cache-in/schemas

CACHE=${CI_CACHE_BUCKET:-cicache:ci-cache}
RCLONE="rclone --retries 2 --low-level-retries 2 --timeout 30s --contimeout 10s"

# Bucket creation lives here: it is idempotent, and keeping it out of a Job
# means nothing else owns bucket lifecycle.
$RCLONE mkdir "$CACHE"

mkdir -p .tmp/charts .tmp/cache-in/tools .tmp/cache-in/schemas
$RCLONE copy "$CACHE/charts" .tmp/charts
$RCLONE copy "$CACHE/tools" .tmp/cache-in/tools
$RCLONE copy "$CACHE/schemas" .tmp/cache-in/schemas

echo "cache restored: $(find .tmp/charts -name '*.tgz' | wc -l) charts, $(find .tmp/cache-in/tools -type f | wc -l) tools, $(find .tmp/cache-in/schemas -type f | wc -l) schema objects"
