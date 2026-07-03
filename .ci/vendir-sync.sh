#!/bin/sh
set -euo pipefail

# Runs `vendir sync` on PR branches when vendir.yml or vendir.lock.yml changes,
# then commits the updated vendored/*/base files back to the branch.
# Woodpecker provides git credentials via CI_NETRC_* env vars.

# Only act on PRs — push-to-main should already have synced files
if [ "${CI_PIPELINE_EVENT}" != "pull_request" ]; then
  echo "Not a PR event (${CI_PIPELINE_EVENT}), skipping."
  exit 0
fi

# Check if vendir.yml or vendir.lock.yml changed in this PR
TARGET_BRANCH="${CI_COMMIT_TARGET_BRANCH:-main}"
git fetch origin "${TARGET_BRANCH}" --depth=1
CHANGED_FILES=$(git diff --name-only "origin/${TARGET_BRANCH}...HEAD")

if ! echo "${CHANGED_FILES}" | grep -qE '^vendir\.(yml|lock\.yml)$'; then
  echo "No changes to vendir.yml or vendir.lock.yml, skipping."
  exit 0
fi

echo "vendir.yml or vendir.lock.yml changed, running vendir sync..."
vendir sync

if git diff --quiet && git diff --cached --quiet; then
  echo "vendir sync produced no changes."
  exit 0
fi

echo "Committing vendir sync results..."
git config user.email "woodpecker@ci"
git config user.name "Woodpecker CI"
git add vendored/ vendir.lock.yml
git commit -m "chore: vendir sync

Co-authored-by: Woodpecker CI <woodpecker@ci>"

# Push back to the PR branch
git push origin "HEAD:${CI_COMMIT_SOURCE_BRANCH}"
echo "Pushed vendir sync results to ${CI_COMMIT_SOURCE_BRANCH}."
