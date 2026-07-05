# TODO

Follow-ups from the 2026-07-05 validation-tooling review and the 2026-07-04
IaC best-practices review. Context: this repo is largely updated by
LLMs/agents, so automated validation is high-value even with a single human
maintainer — it's the safety net and the fast feedback loop for agent-authored
changes.

## 1. Add pluto deprecated-API detection to manifest validation

Pipe the same rendered manifest streams from `.ci/validate.sh` and
`.ci/validate-helm.sh` through `pluto detect --target-versions
k8s=v<next-cluster-version> -` so deprecated-but-still-served APIs are flagged
a release before removal. kubeconform (now version-pinned) only catches APIs
already removed from the pinned release.

- Install the pluto binary in the Woodpecker validate steps; track its version
  with a `renovate: datasource=github-releases depName=FairwindsOps/pluto`
  comment like the existing `KUBECONFORM_VERSION` one.
- Note the extra binary requirement in the pre-commit section of README.md.

## 2. Explore policy/best-practice linting layer (conftest vs kube-linter)

Evaluate a policy/lint layer as guardrails for agent-authored changes — rules
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
- Outcome: adopt/skip decision; if adopt, wire into the CI validate steps and
  pre-commit like the kubeconform checks.

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

## 4. Custom Renovate version API for the VectorChord CNPG image

The immich CNPG `imageName` (`immich/cluster.immich.yaml`) uses compound tags
encoding multiple software versions (Postgres major + VectorChord +
pgvectors), which Renovate's docker datasource can't order.

- Second endpoint on the same service as item 3: parse the upstream tag list,
  hold the Postgres major constant, return newest compatible
  VectorChord/pgvectors versions as an ordered `releases` list — never
  auto-propose a Postgres major bump (CNPG major upgrades are a manual
  procedure).
- Wire via customDatasources + a customManagers regex with a `# renovate:`
  annotation on the `imageName` line.

## 5. Kubernetes recommended labels on all workloads

Apply `app.kubernetes.io/name|instance|component|part-of|managed-by`
consistently. Current state is mixed: arr apps/jellyfin/mumble use
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
  immich but a restore has never been tested.
- Standardize `proxy_<service>.yaml` naming (three files carry a
  `_somemissing_info` suffix).
- Consider a GitHub ruleset requiring PRs for `main` — mechanical guarantee
  that nothing lands unreviewed on a self-applying GitOps repo, and it
  branch-contains any leaked push credential.
- Woodpecker secret-extension (signed HTTP endpoint, supported by the running
  version) could co-host with the item-3 service and replace DB-stored CI
  secrets (`vendir_push_ssh_key`) with Bitwarden-backed ones.

## Skipped (deliberately, 2026-07-05)

- **Rendered-manifests pattern** (commit flat rendered YAML to a separate
  branch/repo): machinery outweighs benefit at this scale; the
  validate-the-render-in-CI approach covers most of the value.
