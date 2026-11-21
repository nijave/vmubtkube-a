# shellcheck shell=sh
# Diff-base selection shared by the CI scripts that act on "what this PR
# changed" (.ci/mirror-images.sh, .ci/verify-images.sh). One source of truth so
# both agree on which commit a PR is diffed against.
#
#   - pull_request: origin/$CI_COMMIT_TARGET_BRANCH (fetched shallowly)
#   - push:         $CI_COMMIT_BEFORE (unless this is the branch's first push)
#   - otherwise:    $BASE_REF if set (lets callers/tests override), else HEAD^
#
# Usage: source this file, then call compute_diff_base. Sets BASE_REF.
compute_diff_base() {
  case "${CI_PIPELINE_EVENT:-}" in
    pull_request)
      target_branch="${CI_COMMIT_TARGET_BRANCH:-main}"
      # depth=100 covers main's history back ~3-4 weeks at typical merge rates,
      # enough for nearly all PRs (Renovate bot PRs are <5 commits ahead).
      # If the merge-base falls outside this, the git-diff check in the caller
      # fails loudly with a clear error rather than silently producing an
      # empty diff.
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
}
