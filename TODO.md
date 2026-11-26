# Follow-ups

Follow-ups from the 2026-07-05 validation-tooling review, the 2026-07-04
IaC best-practices review, and the 2026-11-25 bespoke-CI-tooling review (items
13-16). Context: this repo is chiefly updated by
LLMs/agents, so automated validation is high-value even with a single human
maintainer — it's the safety net and the fast feedback loop for agent-authored
changes.

## 1. Add pluto deprecated-API detection to manifest validation — RESOLVED 2026-08-14

Shipped the same evening the review filed it (PR #211, `e307cbd`).
`.ci/validate-pluto.sh` pipes the same streams as `.ci/validate.sh`
(hand-written manifests, kustomize overlays, plain vendored bases) through
`pluto detect`, and `.ci/validate-helm.sh` tees each rendered chart through
the same check. The target is the next minor above the live cluster version
(`kubectl version`; nothing hardcoded, so cukk auto-upgrades shift it).
Removals in the target fail the build; deprecations print but pass
(`--ignore-deprecations`). The Woodpecker `validate-pluto` and `validate-helm`
steps install the binary with `PLUTO_VERSION` pinned under the
`FairwindsOps/pluto` annotation (the `KUBECONFORM_VERSION` pattern), the
`pluto-validate` pre-commit hook mirrors the CI step, and the README
pre-commit section lists the binary. Caveat: renovate's regex manager doesn't
parse those env-var lines yet — see item 11. Re-verified 2026-08-14: `sh
.ci/validate-pluto.sh` exits clean against Kubernetes v1.37.0.

## 2. Explore policy/best-practice linting layer (conftest vs kube-linter)

Assess a policy/lint layer as guardrails for agent-authored changes — rules
that encode repo conventions an agent might not infer, enforced before merge.

- Highest signal: a small conftest/OPA policy pack over `application.*.yaml`
  (fully self-authored files) enforcing conventions such as automated sync +
  prune, project set, repoURL/mirror conventions
  (`registry.apps.nickv.me` image mirroring rules), no Bitnami sources.
- Secondary: kube-linter or Polaris against rendered output for
  production-readiness checks (probes, requests/limits, non-root). Expect
  noise from vendored upstream manifests — trial with a tuned config against
  the rendered streams from `.ci/validate.sh` before committing.
- Kyverno CLI is the alternative if reusing policies at admission time ever
  matters.
- Outcome: adopt/skip decision; if adopt, wire into the CI validation steps
  and pre-commit like the kubeconform checks.

## 3. Custom Renovate version API for private-registry images — RESOLVED 2026-08-16

Self-built images (`cukk`, `python-envoy-authz`, `cpu-benchmark`,
`qdirstat-cache-writer`, forked `gluetun`) sit in `renovate.json`
`ignoreDeps`, untracked by Renovate. Decision (2026-07-04): build a small
HTTP service Renovate queries as a **custom datasource** — not plain
docker-datasource hostRules.

- Service proxies `registry.apps.nickv.me` (registry v2 API tag/digest list)
  and returns Renovate's custom-datasource JSON (`releases: [{version}]`).
- Wire via `customDatasources` (defaultRegistryUrlTemplate → the API) plus
  customManagers regex / packageRules mapping each image; then remove them
  from `ignoreDeps`.
- Deploy the service from this repo (internal-only, `*.k8s` zone).
- **Blocked follow-up:** once tracked, pin the `:latest` +
  `imagePullPolicy: Always` tags to `:tag@sha256:...` form — priority order:
  `cukk.yaml` (node-upgrade operator, cluster-wide node/eviction RBAC),
  `python-envoy-authz.yaml` (Contour ext-authz path), `cpu-benchmark.yaml`,
  `qds.yaml` (untracked).

Resolved by the `renovate-release-api` deployment (PR #441, design doc
`docs/renovate-private-registry-datasource-design.md`): a Go service in
github.com/nijave/renovate-release-api exposed publicly at
`renovate-releases.apps.somemissing.info`, serving `/v1/releases/{repo}`
with per-tag digests and build timestamps. The wiring PR removed every
populated `ignoreDeps` entry, added per-image packageRules (latest-tracked
with `pinDigests` for cukk, python-envoy-authz, cpu-benchmark,
democratic-csi, and renovate-release-api itself; `^v` semver for the
jellyfin fork; plain semver for homelab-pki, until it moved to the public
OpenTofu image 2026-09 and the rule was removed) plus annotations on each
image line. democratic-csi joined the set beyond the original six: hex
SHAs never order, so latest-tracking is the only flow that yields updates;
the bootstrap copied `146445b` to `latest`, and its CI must keep publishing
`latest`. Digest pinning — the formerly blocked tail — now
arrives as Renovate `pinDigest` PRs, which also flip each workload's
`imagePullPolicy` to `IfNotPresent`. Remaining when their manifests land
in git: `qds.yaml` (qdirstat-cache-writer) and the forked
`qdm12/gluetun`. The mirror script now skips lines annotated
`datasource=custom.` (replacing the ignoreDeps skip list), and blackbox
probes assert a 200 with a non-empty releases array per tracked image.

## 4. Custom Renovate version API for the VectorChord CNPG image — RESOLVED 2026-08-14

Superseded by a pure `renovate.json` fix: a `regex:` versioning packageRule
maps the `PGMAJOR-VCMAJOR.VCMINOR.VCPATCH` tag onto four ordered numeric
components, so the stock docker datasource can rank them. No custom-datasource
service needed. Verified with a local `--platform=local` dry run: Renovate
proposes `17-1.1.1` (minor bucket) and `18-1.1.1` (major bucket) from
`17-0.4.3`; PG-major and VectorChord-major PRs require the manual
`ALTER EXTENSION vchord UPDATE` + reindex follow-up noted in the rule
description, so don't automerge them. This fix leaves the item-3 service
(private-registry images) untouched.

## 5. Kubernetes recommended labels on all workloads

Apply `app.kubernetes.io/name|instance|component|part-of|managed-by`
consistently. Current state varies: arr apps/jellyfin/mumble use
`app.kubernetes.io/*`, others use bare `app:`/`pod:` labels (event-exporter,
cloudflared, external-dns, vpa-recommender Service).

- **Selector immutability**: `spec.selector` on Deployments/StatefulSets
  can't change in place. Either add labels only to `metadata`/`template`
  (keeping old selectors), or accept delete+recreate (fine for
  `strategy: Recreate` apps; needs `argocd.argoproj.io/sync-options:
  Replace=true` or a manual delete).
- Keep Service selectors in sync with whatever the pods carry.
- Do namespace-by-namespace PRs to bound blast radius.

## 6. PR-level live cluster diff (investigated 2026-07-05, ready to build)

`argocd app diff --revision $CI_COMMIT_SHA` per app from a Woodpecker step —
repo-server renders the PR revision itself; respects `ignoreDifferences`.
Feasibility confirmed; design:

- Step image `quay.io/argoproj/argocd`; reach `argocd-server.argocd.svc`
  (ClusterIP, no NetworkPolicy in the way).
- Auth: local ArgoCD account (`accounts.ci-diff: apiKey` in
  `application.argocd.yaml` values) + RBAC `p, role:ci-diff, applications,
  get, default/*, allow` — read-only, config in git. Token minted once via
  `argocd account generate-token`, stored as a Woodpecker repo secret
  (`pull_request` events; same plaintext-DB tradeoff as
  `vendir_push_ssh_key`; ArgoCD masks Secret data in diffs).
- `app diff` exits 1 on differences — treat as informational, not failure.
- Gap: child Applications *new in the PR* aren't diffable (ArgoCD doesn't
  know them; bit us during the VPA rollout) — fall back to printing rendered
  manifests for apps ArgoCD doesn't have.
- Output: CI log initially; a PR comment would need a separate GitHub
  credential with PR-write (new permission decision).

## 7. Security-posture backlog (from the 2026-07-04 review)

Unscheduled but agreed-relevant; roughly by value:

- **NetworkPolicies**: only buildkit has one. Start with default-deny ingress
  + explicit allows in data-holding namespaces (immich, thanos, hyperdx).
- **Pod Security Standards**: no namespace has PSA labels. Start
  `warn=restricted` everywhere; `enforce=baseline` where workloads allow
  (buildkit and gluetun need exemptions).
- **Dedicated AppProject**: everything uses `project: default` (unrestricted
  repos/destinations). Create a project with sourceRepos allowlist (this repo
  + the specific Helm repos) and destination allowlists.
- **Root app self-exclusion**: `application.vmubtkube-a.yaml` can prune
  itself (prune:true + finalizer + self-referential path). Add it to its own
  `directory.exclude` and manage the root app out-of-band.
- **Thanos PKI hostPath**: store/receive-ingestor/compact mount
  `/etc/kubernetes/pki` for `ca.crt`; switch to the `kube-root-ca.crt`
  ConfigMap (pattern already used in `immich/cluster.immich.yaml`) and drop
  the hostPath. Also converge store/receive securityContext to the compact
  baseline (runAsNonRoot, seccomp RuntimeDefault, drop ALL).
- **Chart-emitted VPAs**: kube-prometheus (`prometheusOperator.
  verticalPodAutoscaler.enabled`) and blackbox-exporter values render VPAs in
  Recreate/Auto mode — inert without an updater, but set their
  `updatePolicy.updateMode: "Off"` to match the fleet before any updater
  ever lands.
- **Working-tree cleanup**: `gluetun-poc.yaml` (keys revoked; sanitize to
  ExternalSecret pattern or delete) and `qds.yaml` (debug pod with rw
  hostPath `/`) are still untracked in the repo root; `storageclasses.yaml`
  is a committed empty file.

## 8. Smaller conventions/cleanups

- Converge older manifests off CPU limits (newer ones are memory-limit-only);
  use the now-flowing VPA recommendations (`kubectl get vpa -A`) as the
  sizing source when touching requests.
- Exercise a volsync restore once (`ReplicationDestination` into a scratch
  PVC) — backups exist for radarr/sonarr/prowlarr/sabnzbd/jellyfin/mumble/
  immich but we have never tested a restore. (2026-08-15: exercised a
  barman restore for the immich cluster instead — see
  `docs/immich-pg18-major-upgrade-2026-08-15.md`; the volsync path itself
  remains untested.)
- Deleted the pg17 barman archive for immich on 2026-08-16, ahead of the
  suggested 90 d window and at the owner's request: a second restore drill
  first proved the pg18 chain restorable (`immich-pg18` server dir — 18.4,
  9,818 assets, vchord 1.1.1), then removed the `s3://cnpg-immich/immich/`
  prefix (6,712 objects, 10.6 GiB) along with the ad-hoc upgrade Backup
  CRs. PITR now reaches back only into the pg18 chain. From the 2026-08-15
  pg18 upgrade (`docs/immich-pg18-major-upgrade-2026-08-15.md`).
- Re-run `immich-admin schema-check` after the next immich upgrade: v3.1.0
  flags `user_delete_audit` as missing even though the function and trigger
  are present and correct (benign checker false positive; details in
  `docs/immich-pg18-major-upgrade-2026-08-15.md`). Report upstream if it
  persists.
- Standardize `proxy_<service>.yaml` naming (three files carry a
  `_somemissing_info` suffix).
- Consider a GitHub ruleset requiring PRs for `main` — mechanical guarantee
  that nothing lands unreviewed on a self-applying GitOps repo, and it
  branch-contains any leaked push credential.
- Woodpecker secret-extension (signed HTTP endpoint, supported by the running
  version) could co-host with the item-3 service and replace DB-stored CI
  secrets (`vendir_push_ssh_key`) with Bitwarden-backed ones.

## 9. hyperdx MongoDB: operator now on MCK; mongod version pinned by the kernel check (from the 2026-08-14 image-age review)

The operator migration landed 2026-08-15: PR #422 repointed the app to MCK
(`mongodb/mongodb-kubernetes` 1.10.0), which reconciles the same
`MongoDBCommunity` CR on mongod 8.0.4. All verification gates passed;
`docs/mongodb-mck-migration-runbook.md` records the executed procedure,
including two corrections to the original plan (the operator Deployment
needed a delete-and-recreate for its immutable selector, and the child app
needed a manual sync after its automated retries ran out).

What stays open is the version decision, now under a hard constraint: mongod
releases past 8.0.4 refuse to start on Linux kernel >=6.19 (the
SERVER-121912 fatal check). Renovate PR #420 demonstrated this with 8.0.29 on
the kernel-7.0.0 workers (`hyperdx-1` crash-looped until PR #425 reverted the
bump), and `renovate.json` now pins `mongodb/mongodb-community-server` to
exactly 8.0.4.

- Confirm whether the 8.2/8.3 image lines start on kernel 7.0 before any
  bump; we have not verified where in the 8.0.x stream the check first
  appears (we have only observed 8.0.29 failing and 8.0.4 working). The
  same answer decides whether the `docker.io/mongodb` ubi8 repo pin should
  move to quay.io's ubi9 line.
- Give the workload a standing backup: no volsync `ReplicationSource` and no
  VolumeSnapshotClass cover it, so the only restore point is a manual dump.
  The runbook's gate-1 command (`--db=hyperdx`, with the count check) is the
  tested procedure; either schedule it or add a `ReplicationSource`.

## 10. kubernetes-event-exporter endgame (from the 2026-08-14 image-age review)

`ghcr.io/resmoio/kubernetes-event-exporter:v1.7` (2024-02-23) is the newest
image of that lineage: the repo now redirects to
`mustafaakin/kubernetes-event-exporter`, dormant ~2y but with a revival in
flight (PRs #251/#252, June 2026: Go/k8s bumps, CVE sweep, fixes the
recurring-events-exported-once bug). Not archived; no forced move today.

- Watch for a v1.8/2.x release (may publish under a new ghcr namespace given
  the module rename) — natural upgrade point.
- Preferred consolidation when touched next: drop the standalone exporter and
  ship events via a one-replica Fluent Bit `kubernetes_events` input (watch-
  based since 3.1) or Grafana Alloy `loki.source.kubernetes_events` — one
  fewer component. Vector's `kubernetes_events` source is still an open PR
  (vectordotdev/vector#24448), not an option yet.
- To keep the exporter's sink model with its bugs fixed now, the only active
  fork is `ownkube/kubernetes-events-exporter` — young (9 stars, no tagged
  releases); digest-pin and treat as a stopgap.

## 11. Teach the renovate regex manager version env vars (found closing item 1)

The `customManagers` regex in `renovate.json` matches image-style lines only
(`key: registry/repo:tag`), so the `# renovate:` annotations above
`PLUTO_VERSION`, `KUBECONFORM_VERSION`, and `VENDIR_VERSION` in
`.woodpecker.yaml` never yield updates and the pins rot quietly — pluto cuts
a release per Kubernetes minor, so a stale pin loses deprecation coverage
release by release. Add a matchString for `NAME: v1.2.3` env lines; a local
replay of the current patterns against `.woodpecker.yaml` finds only the
seven image references.

## 12. Cross-repo dependency caches (from the 2026-11-06 CI flakiness review)

The rustfs bucket `ci-cache` in namespace `woodpecker` now survives pipeline
runs (`woodpecker/rustfs.woodpecker.yaml`, design in
`docs/superpowers/specs/2026-11-06-ci-cache-rustfs-design.md`). Two sibling
repos reinstall dependencies from scratch on every pipeline because their
workspace PVC is ephemeral, and would benefit from the same bucket — out of
scope here, follow-up PRs in those repos:

- `nijave/python-envoy-authz`: each of lint/test/coverage recreates the venv and
  runs `poetry install` (p50 lint 45s). The `test -x .poetry-venv/bin/poetry ||`
  guard implies someone expected the venv to persist — it cannot, the workspace
  is deleted after the workflow. Cheapest fixes, in order: one install step whose
  venv the other steps reuse; dependencies baked into the image it already
  builds; `POETRY_CACHE_DIR` on a cache volume.
- `nijave/cukk`: `uv sync --frozen` in both lint and test with no `UV_CACHE_DIR`,
  so uv's cache lives in the ephemeral container.

## 13. Lint the CI shell: shellcheck (and maybe shfmt) (from the 2026-11-25 bespoke-CI-tooling review)

`.ci/` is 2,027 lines of POSIX sh and nothing lints it: no shellcheck or shfmt
step in `.woodpecker.yaml`, no hook in `.pre-commit-config.yaml`. The scripts
already carry `# shellcheck disable=` directives and the 2026-11-06 cache plan
required `shellcheck -s sh` to pass, so the tool is de facto in use — just not
enforced, which means the next agent-authored script gets no coverage at all.

A full run (`shellcheck -s sh .ci/*.sh .ci/lib/*.sh .ci/test/*.sh`) is already
clean apart from two findings, so this is wiring, not a cleanup:

- `SC3040` × 12 (one per script that sets it): `pipefail` is undefined in POSIX
  sh. A false positive here — every step runs in busybox ash (alpine/k8s, the
  regctl alpine image), which supports `pipefail`, and the local `sh` is bash.
  Exclude once with `exclude=SC3040` in a repo-root `.shellcheckrc` rather than
  12 directives.
- `SC2086` at `.ci/validate.sh:96` (`xargs $KUBECONFORM`): the word splitting
  is the point (that string carries the flags). Needs a targeted
  `# shellcheck disable=SC2086` with a one-line reason.

shfmt is a separate, optional decision: the scripts use 2-space indent while
shfmt defaults to tabs, so `shfmt -ln posix -i 2` will still produce a large
first diff. Size it with `shfmt -ln posix -i 2 -d .ci`; if it is noisy, land the
reformat as its own no-behavior-change commit and gate it after. Gating
shellcheck alone is the win; formatting is cosmetic.

- Wire as a `lint-shell` step with a path filter on `**/*.sh` and
  `.shellcheckrc`. Nothing `depends_on` it, so filtering it out is safe.
- shellcheck is GPL-3.0 (`koalaman/shellcheck`); fine for a CI tool. Use the
  image, or the `shellcheck-py` pre-commit hook. shfmt is BSD-3-Clause
  (`mvdan/sh`).
- Pin the step image with the usual `# renovate:` annotation, remembering item
  11 (the regex manager still cannot see env-var pins).

## 14. Lint `.woodpecker.yaml` with woodpecker-cli (from the 2026-11-25 bespoke-CI-tooling review)

The pipeline config is the one file whose mistakes fail *every* pipeline at
compile time, and no linter covers it — while the file's own comments record
three such failures found the hard way: a `from_secret` from a
pull_request-scoped secret evaluated on push events, a DAG edge to a step
filtered out by `when:`, and the PR-only deploy key. Woodpecker ships an
official linter for exactly this.

- Run `woodpecker-cli lint` over the repo root. Upstream runs it as a CI step
  with `WOODPECKER_LINT_STRICT: true`; mirror that.
- Known limit: cli lint does not resolve `${...}` the way the server does
  (woodpecker-ci/woodpecker#7533, fix in PR #7534), so it cannot see a
  secret-scope/event mismatch — the `from_secret` class of failure still needs a
  real push. It does catch schema errors, deprecated/unknown keys and bad habits
  the server complains about.
- Version the CLI to the running server (3.x). `woodpeckerci/woodpecker-cli`
  is the official image; pin it with `# renovate: datasource=docker` (item 11
  again) and add a `.woodpecker.yaml`-scoped pre-commit hook.

## 15. Replace the bespoke CI-script test harnesses with bats-core (from the 2026-11-25 bespoke-CI-tooling review)

`.ci/test/cache-test.sh` (99 lines) and `.ci/test/verify-images-test.sh` (290)
each reimplement the same mini-framework — `ok`, `fail`, `make_repo`,
`commit_at`, a `$TMP` dir and a `trap` — and run under `set -eu`, so the first
failing assertion aborts the file and a run reports one failure at a time.
Neither script is in `.woodpecker.yaml`: the only thing that runs them is a
pre-commit hook, so the `.ci` logic that *does* gate merges has no CI coverage
of its own.

- bats-core (MIT, active) gives `@test` granularity, `--filter`, TAP output,
  `setup`/`setup_file`/`teardown`, `run` + `assert_output`, and
  `BATS_TEST_TMPDIR` instead of the hand-rolled `mktemp -d`/`trap`. The
  assertions are already output-based (the scripts are invoked as programs,
  never sourced), so the translation is mechanical and ~90 lines of scaffolding
  go away.
- Keep the tests hermetic *and* keep the guard: the `unset GIT_DIR
  GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR` at the top of both files is
  load-bearing (a poisoned GIT_DIR once let `git init` mark the real checkout
  bare). In bats that belongs in `setup_file`, not at file scope — each `@test`
  runs in a subshell of the runner, so file-level state is not a reliable place
  for it.
- Add a `test-ci-scripts` step running `bats .ci/test/` so these tests are
  gated in CI, not just locally. Nothing depends on it, so path-filter on
  `.ci/**`.
- `shellspec` is the alternative if POSIX-sh purity of the *test* code matters
  (it runs on dash/busybox); it is far less active than bats. Either way the
  scripts under test stay `#!/bin/sh` — only the harness becomes bash.

## 16. Add pint to the Prometheus rules check (from the 2026-11-25 bespoke-CI-tooling review)

`.ci/validate-prom-rules.sh` already does the hard part — discovering every
PrometheusRule (Helm renders included, via the object list
`validate-prom-selectors` writes) and extracting `.spec` into
`<namespace>/<name>.yaml` — but then only runs `promtool check rules`, which
checks syntax, PromQL and templates. Two things in the script exist only because
promtool cannot do them:

- the `"lint error"` string match that downgrades a duplicate-rules warning to
  a pass (kube-prometheus-stack ships one in
  `kube-apiserver-availability.rules`), and
- the unit tests, which are promtool's and should stay.

Cloudflare pint (Apache-2.0, active, tracks Prometheus releases — v0.90.0 knows
v3.16.0, the version pinned in the pipeline) lints the same rule files and
covers `rule/duplicate`, `alerts/template` (Go template syntax in
annotations/labels, which promtool does not check), `promql/vector_matching`,
`promql/rate`, `rule/name` and more, configured in `pint.hcl`.

- Integration is one command: `pint lint "$RULES_DIR"` on the directory the
  script already builds (it accepts directory paths). Because those files are
  plain `.spec` bodies, no `parser { relaxed = ... }` is needed — that setting
  exists only for pint pointed at PrometheusRule CRs (cloudflare/pint#460).
- `rule/duplicate` lets the "lint error" tolerance hack go: the chart's
  duplicate becomes a pinned config entry (or a path-scoped ignore) instead of a
  substring match on promtool output.
- `pint ci` (diff-aware against the merge-base, the same idea as
  `.ci/lib/diff-base.sh`) is optional: the rule set is small (a few dozen
  objects), so whole-set `lint` is cheap and simpler.
- Do **not** wire `promql/series` yet. It queries a live Prometheus for metric
  existence — genuinely useful (it catches a rule referencing a renamed metric,
  which promtool cannot) but it needs read-only query access and a token, so it
  is a separate, non-blocking step if ever.
- Pin the binary in `.woodpecker.yaml` (`ghcr.io/cloudflare/pint`) with a
  `# renovate:` annotation (blocked on item 11) and add it to the pre-commit
  hook's tool list next to promtool.

## Skipped (deliberately, 2026-07-05)

- **Rendered-manifests pattern** (commit flat rendered YAML to a separate
  branch/repo): machinery outweighs benefit at this scale; the
  render-in-CI approach covers most of the value.
