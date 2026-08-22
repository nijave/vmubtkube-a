---
name: avoid Bitnami charts and images
description: Prefer upstream/community Helm charts and images over Bitnami due to post-Broadcom licensing and maintenance risk
type: feedback
originSessionId: 9ee08d0c-2669-4626-9801-b24ae1a3b98e
---
Avoid Bitnami Helm charts and Bitnami container images whenever an upstream or actively-maintained community alternative exists.

**Why:** Following Broadcom's acquisition of VMware (which owns Bitnami), the long-term licensing terms and maintenance cadence of the Bitnami catalog are uncertain. Several Bitnami images/charts have already been moved to "legacy" status or paywalled. Building infra on them creates a migration risk.

**How to apply:**
- When proposing or generating Helm Application manifests, default to the upstream project's chart (e.g. `kubereboot/charts` for kured, `kubernetes-sigs/descheduler` for descheduler, `prometheus-community/*` for the kube-prom stack, `bitnami-labs` forks only when nothing else exists).
- For container images, reach for the upstream image (e.g. `docker.io/library/postgres`, `docker.io/redis`) or distroless equivalents over `bitnami/<x>`.
- If only a Bitnami option exists, call it out explicitly so the user can weigh the trade-off rather than silently picking it.
- No Bitnami usage remains in this repo: the last one (`bitnamicharts/memcached` for the Thanos caches) was migrated to `registry-1.docker.io/cloudpirates/memcached` on 2026-08-22 (PR #474). CloudPirates' helm-charts is a vetted drop-in source for chart families without an upstream-maintained chart; keep release names stable so rendered service DNS stays unchanged.
