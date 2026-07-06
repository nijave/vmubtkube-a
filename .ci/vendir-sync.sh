#!/bin/sh
set -euo pipefail

# Runs `vendir sync` on PR branches and commits the updated vendored/*/base
# files back to the branch. The Woodpecker step's `path:` filter ensures this
# only runs when vendir.yml or vendir.lock.yml actually changed.

# Gating formerly done by the Woodpecker `when:` filter (the step must always
# exist because mirror-images depends_on it — Woodpecker rejects DAG edges to
# condition-filtered steps).
if [ "${CI_PIPELINE_EVENT:-}" != "pull_request" ]; then
  echo "Not a pull_request event; vendir sync only runs on PRs."
  exit 0
fi
git fetch --quiet origin "${CI_COMMIT_TARGET_BRANCH:-main}"
if git diff --quiet FETCH_HEAD -- vendir.yml vendir.lock.yml; then
  echo "vendir.yml/vendir.lock.yml unchanged vs ${CI_COMMIT_TARGET_BRANCH:-main}; skipping sync."
  exit 0
fi

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

# Push back to the PR branch over SSH. The clone remote is credential-less
# HTTPS (Woodpecker injects netrc only into trusted clone plugins, never into
# commands steps), so push with the deploy key from VENDIR_PUSH_SSH_KEY.
command -v ssh >/dev/null || apk add --no-cache openssh-client
KEY_FILE=$(mktemp)
printf '%s\n' "$VENDIR_PUSH_SSH_KEY" > "$KEY_FILE"
KNOWN_HOSTS=$(mktemp)
# github.com's published ed25519 host key (docs.github.com: GitHub's SSH key fingerprints)
echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' > "$KNOWN_HOSTS"
export GIT_SSH_COMMAND="ssh -i $KEY_FILE -o UserKnownHostsFile=$KNOWN_HOSTS -o IdentitiesOnly=yes"
git push "git@github.com:${CI_REPO}.git" "HEAD:${CI_COMMIT_SOURCE_BRANCH}"
rm -f "$KEY_FILE"
echo "Pushed vendir sync results to ${CI_COMMIT_SOURCE_BRANCH}."
