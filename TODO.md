# Follow-ups

Follow-ups from the 2026-07-05 validation-tooling review and the 2026-07-04
IaC best-practices review. Context: this repo is chiefly updated by
LLMs/agents, so automated validation is high-value even with a single human
maintainer — it's the safety net and the fast feedback loop for agent-authored
changes.

## 1. Add pluto deprecated-API detection to manifest validation

Pipe the same rendered manifest streams from `.ci/validate.sh` and
`.ci/validate-helm.sh` through `pluto detect --target-versions
k8s=v<next-cluster-version> -` so pluto flags deprecated-but-still-served
APIs a release before removal. kubeconform (now version-pinned) only catches
APIs already removed from the pinned release.

- Install the pluto binary in the Woodpecker validation steps; track its
  version with a `renovate: datasource=github-releases depName=FairwindsOps/pluto`
  comment like the existing `KUBECONFORM_VERSION` one.
- Note the extra binary in the pre-commit section of README.md.

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

## 3. Custom Renovate version API for private-registry images

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
  immich but we have never tested a restore.
- Standardize `proxy_<service>.yaml` naming (three files carry a
  `_somemissing_info` suffix).
- Consider a GitHub ruleset requiring PRs for `main` — mechanical guarantee
  that nothing lands unreviewed on a self-applying GitOps repo, and it
  branch-contains any leaked push credential.
- Woodpecker secret-extension (signed HTTP endpoint, supported by the running
  version) could co-host with the item-3 service and replace DB-stored CI
  secrets (`vendir_push_ssh_key`) with Bitwarden-backed ones.

## 9. Migrate hyperdx MongoDB off the EOL community operator (from the 2026-08-14 image-age review)

`operators/mongodb-community-operator.yaml` pins chart 0.13.0 — the final
release of `mongodb/mongodb-kubernetes-operator`, which MongoDB deprecated in
favor of **MCK** (`mongodb/mongodb-kubernetes`, unified community+enterprise
operator); best-effort support ended November 2025. That strand explains why
the operator/agent/readinessprobe/version-upgrade-hook images are all ~1y
stale, and `mongodb/mongodb-community-server` images stop at the 8.x lines
(8.0/8.2/8.3).

- MCK is active (1.10.0, 2026-07-30) and still reconciles `MongoDBCommunity`
  CRs; follow
  `docs/migration/community-operator-migration.md` in the new repo (Helm
  `keep` annotations on CRDs — already satisfied by chart >= 0.13.0 —
  uninstall old chart, install MCK; expect a rolling restart from
  service-account renames).
- After migrating, revisit the `mongodb/mongodb-community-server` packageRule
  `allowedVersions: /^8\.0\./` — 8.2/8.3 image lines exist but predate
  operator 0.13.0, so they were deliberately out of scope until the operator
  migration lands.

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

## Skipped (deliberately, 2026-07-05)

- **Rendered-manifests pattern** (commit flat rendered YAML to a separate
  branch/repo): machinery outweighs benefit at this scale; the
  render-in-CI approach covers most of the value.
