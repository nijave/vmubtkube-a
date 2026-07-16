---
name: renovate-custom-version-api
description: Plan — custom version API (Renovate custom datasource) for private-registry images and compound VectorChord CNPG tags; not plain hostRules
metadata: 
  node_type: memory
  type: project
  originSessionId: 2c9444f7-85f4-4db4-9f5a-77b0cc5b1698
---

For tracking self-built images (cukk, python-envoy-authz, cpu-benchmark, etc. on [[private-registry-apps-nickv-me]]) and the immich CNPG VectorChord image, Nick wants a **custom version API** that Renovate queries as a `customDatasources` endpoint — not plain docker-datasource hostRules:

1. Private registry: API proxies registry.apps.nickv.me (v2 tag/digest list) → Renovate `releases` JSON; then remove images from `ignoreDeps` and pin the `:latest` tags.
2. VectorChord CNPG: tags encode multiple software versions (Postgres major + VectorChord + pgvectors). The API must parse compound tags, hold Postgres major constant, and return newest compatible versions — never auto-propose a Postgres major bump (CNPG upgrade semantics).

Decided 2026-07-04 during an IaC best-practices review; tasks tracked in that session's task list.
