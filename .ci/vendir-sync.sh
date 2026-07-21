#!/bin/sh
set -euo pipefail

# Runs `vendir sync` on PR branches and commits the updated vendored/*/base
# files locally. The commit lands in the shared workspace so the mirror-images
# step (which depends_on this step) sees the synced files in its BASE...HEAD
# diff. The commit is *not* pushed here: pushing needs the deploy key, which is
# a pull_request-scoped secret, and referencing it from a step that also runs
# on push events errors the whole pipeline at compile time. The push therefore
# lives in the separate vendir-push step (when: pull_request), which this step
# signals via the .tmp/vendir-push-needed marker below.

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

# Vendored Helm charts (git source) ship only Chart.lock, not their dependency
# charts/ — vendir can't manage the nested charts/ path, and ArgoCD's
# repo-server can't `helm dependency build` a git source whose dep repo isn't
# registered. Build the locked deps into charts/ here so ArgoCD renders the
# vendored chart offline. `dependency build` honors Chart.lock exactly and does
# not rewrite it, so the tarballs are byte-stable and this stays idempotent.
for chart_yaml in vendored/*/base/Chart.yaml; do
  [ -f "$chart_yaml" ] || continue
  chart_dir=$(dirname "$chart_yaml")
  [ -f "$chart_dir/Chart.lock" ] || continue
  yq -r '.dependencies[]?.repository | select(test("^https?://"))' "$chart_yaml" \
    | sort -u | while read -r url; do
        helm repo add "dep-$(printf '%s' "$url" | cksum | cut -d' ' -f1)" "$url" >/dev/null 2>&1 || true
      done
  echo "Building Helm dependencies for $chart_dir..."
  helm dependency build "$chart_dir"
done

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

# Signal the vendir-push step that there's a commit to push back to the PR
# branch. .tmp is gitignored, so this marker never ends up in the commit.
mkdir -p .tmp
: > .tmp/vendir-push-needed
echo "Committed vendir sync results; flagged for push."
