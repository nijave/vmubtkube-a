#!/bin/sh
set -eu

# Hermetic tests for .ci/verify-images.sh: no network, no registry. regctl is
# stubbed with a script that succeeds for an allow-list and fails otherwise,
# recording every probe. Each test builds a tiny git repo and runs the script
# with BASE_REF=HEAD~1, like a PR diff.
# Run: sh .ci/test/verify-images-test.sh

cd "$(dirname "$0")/../.."
# pre-commit exports an absolute GIT_DIR/GIT_WORK_TREE for the hook's checkout,
# and those take precedence over `git -C`, so every temporary repo below would
# silently operate on this repository instead (same trap .ci/test/cache-test.sh
# documents). Drop them so the temp repos are honoured.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
VERIFY_SCRIPT="$PWD/.ci/verify-images.sh"

ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Stub regctl: `manifest head <ref>` exits 0 iff ref is in $TMP/allow,
# otherwise 1 (missing). Every probe is recorded in $TMP/calls.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/regctl" <<STUB
#!/bin/sh
[ "\$1" = "manifest" ] && [ "\$2" = "head" ] || exit 2
printf '%s\n' "\$3" >> "$TMP/calls"
grep -qxF "\$3" "$TMP/allow" && exit 0
exit 1
STUB
chmod +x "$TMP/bin/regctl"
: > "$TMP/allow"
: > "$TMP/calls"

# run_verify <dir>: run verify-images.sh inside the temp repo at <dir>, with
# the stub on PATH. Outputs are kept in $TMP/out for the last run.
run_verify() {
  _dir=$1
  : > "$TMP/calls"
  ( cd "$_dir" && RETRY_SLEEP=0 REGCTL="$TMP/bin/regctl" sh "$VERIFY_SCRIPT" ) > "$TMP/out" 2>&1
}

make_repo() {
  _dir=$1
  mkdir -p "$_dir"
  git -C "$_dir" init -q
  git -C "$_dir" config user.email "ci@test"
  git -C "$_dir" config user.name "ci"
  git -C "$_dir" commit -q --allow-empty -m init
}

commit_at() {
  # commit_at <dir> <file> <content on stdin>: overwrite file, commit
  _dir=$1
  _file=$2
  cat > "$_dir/$_file"
  git -C "$_dir" add "$_file"
  git -C "$_dir" commit -qm "change $_file"
}

allow() {
  printf '%s\n' "$@" >> "$TMP/allow"
}

calls_is() {
  # calls_is <expected refs, newline-separated>: exact set of probed refs.
  # Compared unique: a missing ref is retried 3 times and so probed 3 times.
  _expected=$(mktemp)
  printf '%s\n' "$@" | sort -u > "$_expected"
  if ! sort -u "$TMP/calls" | diff -u "$_expected" - > "$TMP/diff"; then
    cat "$TMP/diff" >&2
    rm -f "$_expected"
    fail "unexpected regctl calls (see diff above)"
  fi
  rm -f "$_expected"
}

# 1. a PR touching no image refs makes zero registry requests
mkdir -p "$TMP/r1"
make_repo "$TMP/r1"
commit_at "$TMP/r1" app.yaml <<'EOF'
kind: ConfigMap
data:
  key: value
EOF
# second commit changes a non-image line only (file is still in the diff)
commit_at "$TMP/r1" app.yaml <<'EOF'
kind: ConfigMap
data:
  key: value2
EOF
run_verify "$TMP/r1"
[ ! -s "$TMP/calls" ] || fail "no-image-change PR made registry calls: $(cat "$TMP/calls")"
grep -q "checked=0 missing=0" "$TMP/out" || fail "expected checked=0 summary"
ok "no image changes -> zero regctl calls"

# 2. a bumped `image:` scalar -> only the new ref is checked
mkdir -p "$TMP/r2"
make_repo "$TMP/r2"
commit_at "$TMP/r2" app.yaml <<'EOF'
spec:
  containers:
    - name: main
      image: alpine/k8s:1.37.2
EOF
commit_at "$TMP/r2" app.yaml <<'EOF'
spec:
  containers:
    - name: main
      image: alpine/k8s:1.38.0
EOF
allow "alpine/k8s:1.38.0"
run_verify "$TMP/r2"
calls_is "alpine/k8s:1.38.0"
grep -q "ok      alpine/k8s:1.38.0" "$TMP/out" || fail "bumped scalar not reported ok"
ok "bumped image: scalar -> only new ref checked"

# 3. immich-style repository/tag split map -> correct ref built (multi-doc)
mkdir -p "$TMP/r3"
make_repo "$TMP/r3"
commit_at "$TMP/r3" app.yaml <<'EOF'
kind: PersistentVolumeClaim
metadata:
  name: immich
---
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    helm:
      valuesObject:
        controllers:
          main:
            containers:
              main:
                image:
                  repository: ghcr.io/immich-app/immich-server
                  tag: v3.4.1
EOF
commit_at "$TMP/r3" app.yaml <<'EOF'
kind: PersistentVolumeClaim
metadata:
  name: immich
---
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  source:
    helm:
      valuesObject:
        controllers:
          main:
            containers:
              main:
                image:
                  repository: ghcr.io/immich-app/immich-server
                  tag: v3.4.2
EOF
allow "ghcr.io/immich-app/immich-server:v3.4.2"
run_verify "$TMP/r3"
calls_is "ghcr.io/immich-app/immich-server:v3.4.2"
ok "immich-style repository/tag map -> ref built"

# 4. digest-pinned tag -> repository:tag@digest
mkdir -p "$TMP/r4"
make_repo "$TMP/r4"
DIGEST=sha256:c8e2d17498838af5d91e12eb7c11220b3434a7b7131a333e3af52ad5e0b80882
commit_at "$TMP/r4" app.yaml <<EOF
spec:
  image:
    repository: docker.io/valkey/valkey
    tag: 9.2-alpine@$DIGEST
EOF
commit_at "$TMP/r4" app.yaml <<EOF
spec:
  image:
    repository: docker.io/valkey/valkey
    tag: 9.3-alpine@$DIGEST
EOF
allow "docker.io/valkey/valkey:9.3-alpine@$DIGEST"
run_verify "$TMP/r4"
calls_is "docker.io/valkey/valkey:9.3-alpine@$DIGEST"
ok "digest-pinned tag -> ref with digest checked"

# 5. unchanged refs in a changed file are not checked; skip lists hold for
#    newly added templated/mirror/bare/URL refs
mkdir -p "$TMP/r5"
make_repo "$TMP/r5"
commit_at "$TMP/r5" app.yaml <<'EOF'
spec:
  containers:
    - name: main
      image: alpine/k8s:1.37.2
EOF
commit_at "$TMP/r5" app.yaml <<'EOF'
spec:
  containers:
    - name: main
      image: alpine/k8s:1.37.2
    - name: mirror
      image: registry.apps.nickv.me/thanos/thanos:v0.39.0
    - name: tpl
      image: "{{ .Values.img }}"
    - name: env
      image: $MYIMAGE
    - name: bare
      image: alpine/k8s
    - name: url
      image:
        repository: oci://example.com/foo
        tag: 1.0
EOF
run_verify "$TMP/r5"
[ ! -s "$TMP/calls" ] || fail "unchanged/skipped refs were probed: $(cat "$TMP/calls")"
grep -q "skip registry.apps.nickv.me/thanos/thanos:v0.39.0 (local mirror)" "$TMP/out" \
  || fail "mirror ref not reported as skipped"
grep -q "skip alpine/k8s (no tag/digest)" "$TMP/out" || fail "bare ref not reported as skipped"
grep -q "skip .* (templated)" "$TMP/out" || fail "templated ref not reported as skipped"
ok "unchanged, templated, mirror, bare and URL refs not checked"

# 6. a new file added by the PR has all its refs checked
mkdir -p "$TMP/r6"
make_repo "$TMP/r6"
commit_at "$TMP/r6" app.yaml <<'EOF'
kind: ConfigMap
data:
  key: value
EOF
cat > "$TMP/r6/new.yaml" <<'EOF'
spec:
  image:
    repository: quay.io/thanos/thanos
    tag: v0.39.0
EOF
git -C "$TMP/r6" add new.yaml
git -C "$TMP/r6" commit -qm "add new.yaml"
allow "quay.io/thanos/thanos:v0.39.0"
run_verify "$TMP/r6"
calls_is "quay.io/thanos/thanos:v0.39.0"
ok "new file -> its refs checked"

# 7. a missing ref fails the run, but every ref is still checked
mkdir -p "$TMP/r7"
make_repo "$TMP/r7"
commit_at "$TMP/r7" app.yaml <<'EOF'
spec:
  containers:
    - name: a
      image: alpine/k8s:1.37.2
    - name: b
      image: ghcr.io/immich-app/immich-machine-learning:v3.4.2-openvino
EOF
commit_at "$TMP/r7" app.yaml <<'EOF'
spec:
  containers:
    - name: a
      image: alpine/k8s:1.38.0
    - name: b
      image: ghcr.io/immich-app/immich-machine-learning:v3.4.2-doesnotexist
EOF
allow "alpine/k8s:1.38.0"
if run_verify "$TMP/r7"; then
  fail "missing ref did not fail the run"
fi
calls_is "alpine/k8s:1.38.0" "ghcr.io/immich-app/immich-machine-learning:v3.4.2-doesnotexist"
grep -q "MISSING ghcr.io/immich-app/immich-machine-learning:v3.4.2-doesnotexist" "$TMP/out" \
  || fail "missing ref not reported"
grep -q "checked=2 missing=1" "$TMP/out" || fail "summary wrong"
ok "missing ref -> non-zero exit, all refs still checked"

# 8. a broken diff base fails loudly instead of passing silently
mkdir -p "$TMP/r8"
make_repo "$TMP/r8"
commit_at "$TMP/r8" app.yaml <<'EOF'
kind: ConfigMap
data:
  key: value
EOF
if ( cd "$TMP/r8" && RETRY_SLEEP=0 REGCTL="$TMP/bin/regctl" BASE_REF=does-not-exist \
       sh "$VERIFY_SCRIPT" ) > "$TMP/out" 2>&1; then
  fail "broken diff base did not fail"
fi
grep -q "ERROR: git diff against does-not-exist failed" "$TMP/out" \
  || fail "broken diff base error not reported"
ok "broken diff base -> loud failure"

echo "all verify-images tests passed"
