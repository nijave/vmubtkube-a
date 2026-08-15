# Image age follow-up — 2026-08-14

Outcome of investigating every image older than one year in
[`image-age-report-2026-08-14.md`](image-age-report-2026-08-14.md): which
have newer upstream releases, which Renovate could not see or order, and what
changed in this repo so the updatable ones start receiving PRs.

Status per image:

| Image | Newer upstream? | Outcome |
|---|---|---|
| `ghcr.io/resmoio/kubernetes-event-exporter:v1.7` | no | v1.7 is the newest tag of that lineage. The repo now redirects to `mustafaakin/kubernetes-event-exporter` (dormant ~2y, revival PRs #251/#252 open since June 2026). Renovate already tracks it; see item 10 in `TODO.md`. |
| `quay.io/mittwald/kubernetes-secret-generator:v3.4.1` | no | Chart 3.4.1 (2025-02-04) is the latest on `helm.mittwald.de`. Project dormant but not archived. Already tracked via the argocd manager. |
| `quay.io/mongodb/mongodb-kubernetes-operator:0.13.0` (+ readinessprobe 1.0.23, version-upgrade hook 1.0.10, agent) | no | Chart 0.13.0 was the community operator's final release; MongoDB deprecated it for MCK with best-effort support ending November 2025. See item 9 in `TODO.md`. |
| `docker.io/prom/snmp-exporter:v0.29.0` | yes — v0.30.1 (2026-01-06) | Tracking fixed. A YAML anchor (`image: &snmpExporterImage …`) sat between `image:` and the value, so neither the kubernetes manager nor the custom regex manager matched the line. Both lines now carry the literal image. v0.30.x has no breaking changes (one new optional SNMPv3 query param; the exporter now refuses to start on a config with no auths/modules). |
| `ghcr.io/tensorchord/cloudnative-vectorchord:17-0.4.3` | yes — `17-1.1.1` | Versioning fixed. Docker versioning treated the VectorChord semver after `17-` as a compatibility suffix and filtered every other tag, so no update was ever proposed. A `regex:` versioning rule now orders all four components (`PG-VCMAJOR.VCMINOR.VCPATCH`). Immich v3.x accepts VectorChord >=0.3,<2.0, so `17-1.1.1` is in range. A VectorChord-major or PG-major merge needs the documented `ALTER EXTENSION vchord UPDATE; REINDEX INDEX face_index; REINDEX INDEX clip_index;` follow-up — noted in the rule; do not automerge those. |
| `docker.io/mongodb/mongodb-community-server:8.0.4-ubi8` | yes — 8.0.29 (8.2/8.3 lines exist too) | Tracking added. `MongoDBCommunity.spec.version` now has a `# renovate:` annotation matched by a new `version:`-line matchString; `extractVersion` rewrites `8.0.29-ubi8` releases to the bare semver the operator expects (it appends `-ubi8` itself when building the image tag). `allowedVersions` pins to the 8.0.x line because the 8.2/8.3 image lines predate operator 0.13.0 — revisit after the MCK migration (item 9 in `TODO.md`). Patch bumps roll the replica set member-by-member with no FCV change. |
| `ghcr.io/onedr0p/exportarr:v2.3.0` | no | v2.3.0 is the newest release. Already tracked and grouped. |

Adjacent fix found while checking the same failure modes:

- `registry.apps.nickv.me/searxng/searxng:2026.7.3-c5cd510d8` — date-hash
  tags hit the same compatibility-suffix trap (stuck since the tag was
  pinned), and the inline `versioning=` annotation on the image line never
  matched any matchString (extra keys after `depName=` break the image
  pattern, and the kubernetes manager ignores annotations). Removed the dead
  annotation; a packageRule with `**/searxng/searxng` (the mirror depName
  keeps its registry prefix) now versions the date components. Renovate
  proposes `2026.8.14-094c33d40`.
- The regex versioning rule also retires item 4 in `TODO.md` (the planned
  custom Renovate version API for the VectorChord image).

## Verification

Two `renovate --platform=local` dry runs (in the `renovate/renovate`
container) against this tree confirm the proposed updates: snmp-exporter
`v0.29.0 → v0.30.1`, mongodb-community-server `8.0.4 → 8.0.29` (bare value),
vectorchord `17-0.4.3 → 17-1.1.1` (minor bucket) and `18-1.1.1` (major
bucket), searxng `2026.7.3-c5cd510d8 → 2026.8.14-094c33d40`; event-exporter
and exportarr stay current with nothing newer available. `.ci/validate.sh`
and the pre-commit hooks pass. Upstream facts came from live registry tag
listings (`skopeo list-tags`), the `helm.mittwald.de` and
`mongodb.github.io/helm-charts` indexes, and upstream release notes/docs.
