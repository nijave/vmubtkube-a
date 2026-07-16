---
name: thanos_replica vs prometheus_replica semantics
description: Thanos Receive's thanos_replica labels ingestors, not upstream Prometheus replicas — Prometheus still needs its own replica external label for query-time dedup
type: feedback
originSessionId: 759ae1ed-d669-42e2-b247-717183ee9894
---
`thanos_replica` (added by Thanos Receive via `--label=thanos_replica=$(NAME)`) differentiates **Thanos Receive ingestors**, not the upstream Prometheus senders. So when there are multiple Prometheus replicas remote-writing to Thanos Receive, each Prometheus replica still needs its own replica external label (`replicaExternalLabelName`, default `prometheus_replica`) so Thanos Query can dedupe at read time.

**Why:** I incorrectly suggested clearing `replicaExternalLabelName` on the assumption that Thanos Receive's `thanos_replica` covered Prometheus-side dedup. The user corrected: those are different layers. Clearing Prometheus's replica label would make duplicate samples from the two Prometheus replicas indistinguishable to Thanos Query and break dedup.

**How to apply:** When working with Prometheus → Thanos Receive setups in this repo (or similar), assume each Prometheus replica must keep a unique `replicaExternalLabelName`. Don't recommend clearing it. Use Thanos Query's `--query.replica-label` flags to enumerate all replica label names that should be deduped (this repo's Thanos Query config already lists `prometheus_replica`, `rule_replica`, `replica`, `ingestor_replica`, `thanos_replica`).
