#!/bin/sh
set -euo pipefail

# Pushes the vendir-sync commit back to the PR branch over SSH.
#
# Split out of vendir-sync.sh so the deploy-key secret is referenced only from
# a step gated to `when: event=pull_request`. vendir-sync must stay unfiltered
# (mirror-images depends_on it, and Woodpecker rejects a DAG edge to a
# condition-filtered step), so it cannot carry the PR-only secret without
# erroring push-to-main pipelines at compile time. This step has no dependents,
# so filtering it out on push is safe.
#
# vendir-sync writes .tmp/vendir-push-needed only when it actually commits;
# absent that marker there is nothing to push.

if [ ! -f .tmp/vendir-push-needed ]; then
  echo "No vendir-sync commit to push; nothing to do."
  exit 0
fi

# The clone remote is credential-less HTTPS (Woodpecker injects netrc only into
# trusted clone plugins, never into commands steps), so push with the deploy
# key from VENDIR_PUSH_SSH_KEY.
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
