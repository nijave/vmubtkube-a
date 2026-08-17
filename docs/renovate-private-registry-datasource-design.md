# Custom Renovate datasource for private-registry images: design

Design for item 3 in `TODO.md`: track the self-built images living in
`registry.apps.nickv.me` with Renovate, replacing the `ignoreDeps` entries,
and unblock the digest-pinning follow-up (`:latest` +
`imagePullPolicy: Always` → `:tag@sha256:...`). The 2026-07-04 decision
(build a small HTTP service that Renovate queries as a `customDatasources`
endpoint, not docker-datasource hostRules) stands; this doc specifies it.

Everything marked *verified* below passed a check on 2026-08-14/15 against
the live registry, the Renovate docs/source at 44.30.3, or a
`renovate --platform=local` dry run against a canned copy of the API.

## Goals and non-goals

Goals:

- Renovate proposes updates for every self-built image (`cukk`,
  `python-envoy-authz`, `cpu-benchmark`, `jellyfin` fork, `homelab-pki`,
  the forked `qdm12/gluetun` once its manifest lands in git) instead of
  ignoring them.
- Updates flow for images whose only moving part is `:latest` (the digest
  of what `latest` points at), which is the actual situation for four of
  the six.
- Renovate can pin and re-pin digests (`:tag@sha256:...`), which is the
  prerequisite for the blocked follow-up.
- The service is small, stateless, and deployed from this repo like any
  other workload.

Non-goals:

- VectorChord CNPG compound tags (item 4); the regex-versioning rule in
  `docs/image-age-followup-2026-08-14.md` retires them separately.
- Making the registry itself authenticated or publicly reachable.
- Self-hosting Renovate (evaluated below as the alternative, not chosen).
- Automatically moving manifests off `latest` onto commit tags: the
  mechanism cannot order hex tags (see "Version semantics"); that step
  stays manual.

## Why a custom datasource, not docker-datasource hostRules

- The registry is LAN-only by design (nothing on the internet needs to be
  able to pull from it), so Renovate's docker datasource cannot query it
  from a hosted runner.
- Half the images carry only `latest` or hex commit tags. The docker
  datasource cannot order those tags and cannot see "the image behind
  `latest` changed"; the selfoss/searxng compatibility-suffix trap is the
  same class of problem. A custom datasource controls what a "release" is:
  each tag with its digest and build timestamp.
- Digest pinning needs the release to carry a digest. The custom
  datasource schema has one; hostRules would still leave ordering broken.

## What the registry exposes (verified)

`registry.apps.nickv.me` is a plain `registry:2` on a LAN host
(`infra/k8s/registry/start.sh`). Listing is anonymous:
`.ci/mirror-images.sh` pushes to it with no credentials, and every probe
below ran unauthenticated. All data the service needs is available through
three calls:

| Purpose | Call |
|---|---|
| Tags | `GET /v2/<repo>/tags/list` (pagination: `n`/`last` params, RFC 5988 `Link` header; the official registry returns 100 per page when the caller omits `n`) |
| Digest per tag | `HEAD /v2/<repo>/manifests/<tag>` with `Accept` covering Docker v2 and OCI manifest/index types → `Docker-Content-Digest` header |
| Build timestamp | `GET` the manifest, then `GET /v2/<repo>/blobs/<config digest>` → `.created` in the config blob |

Actual tag state (2026-08-14), which drives the version semantics:

| Repository | Tags | Shape |
|---|---|---|
| `nijave/cukk` | `latest` + 4 × 8-hex commit tags | `latest` aliases `16d477cb` (identical digest `sha256:3157…5ead`, built 2026-06-14) |
| `nijave/python-envoy-authz` | `latest` + 32 commit tags | same scheme |
| `cpu-benchmark` | `latest` only | manual `podman build/push` (`cpu-benchmark.yaml` header comment) |
| `jellyfin` | 7 versioned fork tags | `v10.11.5-nv-hdr-patch` is current and newest |
| `nijave/homelab-pki` | semver + `tftest` | `0.2.5` current; `tftest` is junk to filter |
| `qdm12/gluetun` | `latest` only | forked upstream (see `docs/agent-memory/project_gluetun_fork.md`) |

## Where Renovate runs: the reachability constraint

The PRs come from `app/renovate`, the Mend-hosted GitHub App, which runs
from Mend's infrastructure. It cannot reach anything LAN-only (README
"DNS zones and TLS"), the registry host included. The `TODO.md` sketch
("internal-only, `*.k8s` zone") predates confirming this; the endpoint
Renovate queries must be reachable from the internet.

Decision: deploy the service in-cluster and expose it through the Contour
edge at `renovate-releases.apps.somemissing.info` for the hosted app,
with no internal name. The
endpoint serves reads only; it reveals nothing beyond tag names and
digests of images whose existence this private repo already records. The
alternative, self-hosting Renovate on the LAN to keep the endpoint
internal-only, buys little for a much larger footprint and remains a
future option; the Renovate wiring is identical either way (only the URL
changes).

## Service contract

One generic templated endpoint, not per-image paths. Renovate's
`defaultRegistryUrlTemplate` interpolates `{{packageName}}`, and the
existing regex manager passes the full mirror path as `packageName`
(`registry.apps.nickv.me/nijave/cukk`; the mirror depName keeps its
registry prefix). The service strips its configured registry host and
serves the rest.

```
GET /v1/releases/{repo-path}

{
  "homepage": "https://github.com/nijave/cukk",
  "releases": [
    {
      "version": "latest",
      "digest": "sha256:31573108…f675ead",
      "releaseTimestamp": "2026-06-14T23:06:03Z"
    }
  ],
  "tags": { "latest": "16d477cb" }
}
```

- The response is already in Renovate's schema: no `transformTemplates`
  anywhere. `format: "json"` only.
- Every release **must** carry `digest` (the manifest digest) and
  `releaseTimestamp` (the config blob's `created`). Both parts are
  verified requirements, not niceties: a missing digest makes Renovate
  drop the update outright, and the timestamp feeds
  `currentVersionAgeInDays`/`minimumReleaseAge` later.
- `tags.latest` names the commit tag whose digest matches `latest`; the
  service resolves it by digest comparison, since the registry offers no
  alias API.
- Which tags become releases is one global filter, not per-repo config:
  only `latest`, short (7-8 hex) or full (40-hex) git SHAs, semver
  (optional `v` and suffixes, the jellyfin shape), and pure integers
  qualify. Junk like `tftest` never matches, so it stays out of the
  payload and Renovate config stays dumb.
- Errors: `404` for an unknown repository (Renovate logs "Datasource
  404", yields no releases), `503` when the registry itself is
  unreachable. Every fetch failure ends as no releases (the "Silent
  freeze" behavior below); the distinct codes exist for humans,
  `/healthz`, and the blackbox probe, not for Renovate. The service must
  answer stable JSON on success; a malformed body fails zod parsing
  inside Renovate and looks the same as a 404.

## Version semantics: what `latest` means, per image

The dry run (below) answered what works and what does not:

| Policy | Repositories | Renovate wiring | Update flow |
|---|---|---|---|
| `latest`-tracked | `cukk`, `python-envoy-authz`, `cpu-benchmark`, `qdm12/gluetun` | `versioning: "regex:^(?<major>latest)$"`, `pinDigests: true` | First a `pinDigest` PR adds `@sha256:…` to `:latest`; afterwards every push that moves `latest` triggers a `digest` PR. The hex commit tags ride along as releases but never order, so they never win (the dry run also tried `followTag: "latest"` and could not order hex). |
| Versioned fork tags | `jellyfin` | `versioning: "regex:^v(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-\\S+$"` | Normal minor/major PRs across `v10.x.y-…` tags; the `^v` anchor filters the unprefixed junk tags. Do not capture the suffix as `(?<compatibility>…)`: that splits tag lines and suppresses updates (same trap as selfoss before its rule). |
| Semver | `homelab-pki` | `versioning: "semver"`; `tftest` never passes the tag filter | Normal version PRs. |

Per-image meaning of `latest`, explicitly:

- `cukk`, `python-envoy-authz`: newest CI build of the default branch; a
  new build overwrites the tag, so the digest is the only change signal.
- `cpu-benchmark`: the only tag; rebuilt by hand, rarely.
- `qdm12/gluetun`: the only tag the fork pushes.

Digest pinning follow-up (item 3's blocked tail): `pinDigests: true`
scoped to these package rules is the whole mechanism. Renovate proposes
`registry.apps.nickv.me/nijave/cukk:latest@sha256:…` and re-pins on every
later build, which satisfies "`:tag@sha256:...` form" with `tag=latest`.
Pair each pin with `imagePullPolicy: IfNotPresent`; `Always` plus a
digest reference makes kubelet re-check the registry on every pod start
for an immutable digest. Moving `cukk.yaml` onto immutable commit tags
remains a deliberate manual edit (then tracked by its own digest); if CI
later pushes an orderable scheme (say `20260814-a1b2c3d`, the selfoss
shape), the tag filter and versioning rule change and version updates
start flowing.

## Deployment sketch

One file, `renovate-datasource.yaml`, following the repo's flat
hand-written-workload convention (`reloader.yaml`, `searxng.yaml`, …):

- Namespace `default` (no new namespace for one pod; matches selfoss /
  reloader). Deployment, 1 replica, stateless.
  `reloader.stakater.com/auto: "true"` for config changes. Requests
  ~10m/64Mi, memory limit 128Mi: it proxies JSON lists.
- Implementation: a small single-binary service (Go or Python/uvicorn,
  ~150 lines: three registry calls + tag filter). The backend registry
  URL comes from an env var (`REGISTRY_URL=https://registry.apps.nickv.me`
  in the manifest), not from the code. Built by the existing Woodpecker
  `buildctl` path like `cukk`, pushed as
  `registry.apps.nickv.me/nijave/renovate-datasource:<sha>` + `latest`.
  Its own image stays in `ignoreDeps` permanently: the bootstrap paradox
  is fine for one image, and pinning its own digest manually in the
  manifest is a one-line chore per deploy.
- TLS: cert-manager `Certificate` from
  `cert-manager-webhook-dnsimple-production`. Let's Encrypt on the
  endpoint means Renovate needs no custom CA.
- Registry CA: the service mounts the same
  `registry.apps.nickv.me.crt` already embedded in the buildkitd
  ConfigMap (source of truth `infra/k8s/registry/registry.crt`); the
  manifest carries its own ConfigMap copy with the same keep-in-sync
  comment, since ConfigMaps can't share across namespaces cleanly here.
- Exposure: ClusterIP Service behind an HTTPProxy on the `apps` edge
  (see reachability).
- Health: `/healthz` performs a live `tags/list` against the registry and
  fails if it can't. A ServiceMonitor on it plus a PrometheusRule alert
  (down > 30m); see "Silent freeze" under risks.

## Renovate wiring: cukk first

```diff
--- a/renovate.json
+++ b/renovate.json
@@
+  "customDatasources": {
+    "private-registry": {
+      "defaultRegistryUrlTemplate": "https://renovate-releases.apps.somemissing.info/v1/releases/{{packageName}}",
+      "format": "json"
+    }
+  },
   "ignoreDeps": [
-    "registry.apps.nickv.me/nijave/cukk",
     "registry.apps.nickv.me/jellyfin",
     …
   ],
@@ packageRules
+    {
+      "description": "cukk: self-built; latest = newest CI build of the default branch, tracked by digest (docs/renovate-private-registry-datasource-design.md)",
+      "matchPackageNames": ["registry.apps.nickv.me/nijave/cukk"],
+      "pinDigests": true,
+      "versioning": "regex:^(?<major>latest)$"
+    }
```

```diff
--- a/cukk.yaml
+++ b/cukk.yaml
@@
         - name: operator
+          # renovate: datasource=custom.private-registry depName=registry.apps.nickv.me/nijave/cukk
           image: registry.apps.nickv.me/nijave/cukk:latest
```

Notes that apply per image:

- The annotation must carry exactly `datasource=… depName=…`; extra keys
  after `depName` break the regex manager's first matchString, and
  `versioning` belongs in the packageRule, not the comment.
- `renovate.json`'s `customManagers` regex block needs no changes; the
  existing matchStrings already capture `currentValue` and
  `currentDigest`.
- Two images are also scanned by the `kubernetes` manager
  (`jellyfin.yaml`, `python-envoy-authz.yaml` are in its
  `managerFilePatterns`). Removing their `ignoreDeps` entries exposes a
  second, broken dep: `registryAliases` maps the host to Docker Hub, where
  those repos don't exist. Add the same treatment as the existing thanos
  rule (`matchManagers: ["kubernetes"]`, `enabled: false` for the
  depName) in those PRs. `cukk.yaml`, `cpu-benchmark.yaml`, and
  `homelab-pki.yaml` are not in the manager's file patterns, so the
  annotation is their only wiring.
- One image per PR, in the `TODO.md` priority order (cukk →
  python-envoy-authz → cpu-benchmark → the rest), each with its own dry
  run. `ignoreDeps` shrinks one entry at a time; a revert is one PR.

Mirror-script interaction: `.ci/mirror-images.sh` uses `ignoreDeps` as its
skip list. Once cukk leaves it, a Renovate PR touching the cukk image line
makes the script probe `index.docker.io/nijave/cukk:latest`, find nothing
upstream, and log `skip (upstream not found)`, the no-op guard built for
exactly this. Accept the noise; if it gets tiresome, teach the script to
skip lines annotated `datasource=custom.`.

## Silent freeze, and the check that catches it

The custom datasource swallows every fetch error and returns "no
releases" (verified in the datasource source: the catch in `getReleases`
logs and returns null). A dead service does not fail CI or open an issue.
Renovate simply stops proposing updates for these images, which is the
same silence `ignoreDeps` produces today, now with an extra component
that can break. Mitigations, both cheap:

- The `/healthz` ServiceMonitor + alert above (liveness of service and
  registry path together).
- A blackbox probe of the real endpoint: the blackbox-exporter already
  deployed (`application.blackbox-exporter.yaml`) can GET
  `/v1/releases/nijave/cukk` and assert a 200 with a non-empty
  `releases` array, catching TLS/routing failures that `/healthz` can't
  see. Wire one probe per tracked image; alert if any fails twice in a
  row.

## Rollout and verification

Each stage is verifiable with the dry-run method proven in
`docs/image-age-followup-2026-08-14.md`: run Renovate from the
`renovate/renovate` image with `--platform=local` against a scratch git
tree, and read the `packageFiles with updates` debug blob.

1. Deploy the service and expose it through the Contour edge.
2. Dry-run against the deployed endpoint before touching `renovate.json`,
   from outside the LAN: copy the spike layout, a scratch repo whose
   `renovate.json` has the `customDatasources` block pointing at
   `https://renovate-releases.apps.somemissing.info` and one annotated
   image line. Expect: `pinDigest` on `:latest`, a `digest` update on a
   stale `:latest@sha256:…`.
3. PR per image per the wiring section. Dry-run the PR branch; merge; the
   hosted app should open the pin/digest PRs within its schedule. A repo
   debug log (`logLevelRemap` on `^Custom datasource`) or the dependency
   dashboard confirms the lookups resolve.
4. Digest-pin follow-ups land as Renovate PRs; flip each workload's
   `imagePullPolicy` to `IfNotPresent` in the same PRs.

The spike behind this section (canned API on localhost, real cukk digests)
confirmed each behavior: `pinDigest` on `:latest`, `digest` update on stale
`latest` digests, minor/major updates on versioned fork tags once digests
are present, the need for `regex:^(?<major>latest)$` (`loose` yields
nothing), the compatibility-capture trap, and `followTag`'s inability to
order hex tags.

## Risks and open questions

- **Reachability depends on the hosted app staying hosted.** The public
  edge is the one assumption the wiring rests on; if the endpoint must go
  internal-only later, Renovate has to move in-cluster first.
- **Unmatched tag shapes stay invisible**: the filter admits only
  `latest`, short/full git SHAs, semver, and integers, so a future
  tagging scheme outside those shapes surfaces as no releases until the
  filter learns the shape.
- **Commit-tag repos never get version updates**, only digest updates on
  `latest`. Accepted above; the escape hatch is an orderable CI tag
  scheme.
- **The service's own image stays untracked** (bootstrap paradox), a
  deliberately permanent `ignoreDeps` entry.
- **`registry:2` pagination edge**: with an unbounded tags/list and repos
  under 100 tags this never paginates today; the service still follows
  the `Link` header so python-envoy-authz (33 tags) and future growth
  can't silently truncate.
- Open: exact service language/build repo (Woodpecker pipeline in this
  repo vs. in the cukk-style source repo), decided at implementation.
- Open: whether `qdirstat-cache-writer`'s manifest (`qds.yaml`, still
  untracked) ever lands; the wiring is ready if it does.

## Implementation status (2026-08-16)

Deployed and wired; see `TODO.md` item 3 for the summary and PR trail.
How it landed, including deviations from the sketch above:

- **Service**: Go (standard library only) in
  github.com/nijave/renovate-release-api, Woodpecker-built via the shared
  buildkitd with a Dockerfile, pushed as
  `registry.apps.nickv.me/nijave/renovate-release-api` (not the sketch's
  `nijave/renovate-datasource` — the source repo's name won). Manifest:
  `renovate-release-api.yaml`. It fetches manifests by GET rather than
  HEAD — one round trip carries both `Docker-Content-Digest` and the
  config reference — and resolves `tags.latest` exactly as specified.
  Verified live against the real registry before rollout (the cukk
  payload reproduced the digests above byte-for-byte).
- **No bootstrap paradox**: the service's own image carries the
  `datasource=custom.private-registry` annotation and packageRule from
  day one — one hand-pinned digest at bootstrap, then Renovate queries
  the running service for its own updates. No `ignoreDeps` entry at all;
  the "permanently untracked" risk above did not survive contact.
- **Wiring granularity**: one PR for all images, not one-per-PR (the
  maintainer accepted the coarser revert granularity). Beyond the six images here,
  `democratic-csi/democratic-csi` joined the set: hex-only tags, so the
  bootstrap copied `146445b` to a `latest` tag and its CI must keep
  publishing `latest` for updates to flow.
- **customManagers**: the multiline `registry:`/`repository:`+`tag:`
  matchStrings gained an optional `@(?<currentDigest>sha256:…)` group so
  `pinDigests` round-trips in the valuesObject form (democratic-csi's
  shape); without it a pinned `tag: latest@sha256:…` would poison the
  dep on the next run.
- **Response shape**: the response omits `homepage` — the registry
  exposes no source for it and Renovate's schema does not require it.
- **Mirror script**: `.ci/mirror-images.sh` now skips refs whose dep is
  annotated `datasource=custom.`, replacing the emptied `ignoreDeps`
  skip list ("if it gets tiresome" — it never got tiresome, it just
  became necessary).
- **Blackbox probes**: `renovate_releases_2xx` module asserts a 200 with
  a non-empty `releases` array; one probe per tracked image at 60s
  (each probe walks the repo's full tag list, so not the 10s default),
  alert `RenovateReleasesEndpointFailing` at two consecutive failures.
- **Still open**: `qds.yaml` (qdirstat-cache-writer) and the forked
  `qdm12/gluetun` manifest; the wiring is ready when they land.
