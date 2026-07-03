#!/bin/sh
set -euo pipefail

# Runs `vendir sync` on PR branches and commits the updated vendored/*/base
# files back to the branch. The Woodpecker step's `path:` filter ensures this
# only runs when vendir.yml or vendir.lock.yml actually changed.

echo "Running vendir sync..."
vendir sync

if git diff --quiet && git diff --cached --quiet; then
  echo "vendir sync produced no file changes."
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
