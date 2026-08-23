# Coding-agent trace ingest: silent drop fix and performance baseline

Status as of 2026-08-23. Records the oversized-batch data-loss incident on the
coding-agent telemetry chain, what fixed it, and the before/after resource
numbers, written so a future agent can re-measure without re-deriving anything.

## Chain under discussion

```
coding agents (opencode, claude-code, codex, pi)
  → agents-otel.k8s.somemissing.info   (otel-agent-trace-connector, custom distro on collector v0.159.0)
  → otel-collector.k8s.somemissing.info (opentelemetry-collector chart 0.170.0, contrib v0.158.0)
  → hyperdx-otel-collector             (ClickStack chart 3.2.0, otelcol-hyperdx v0.155.0, OpAMP-managed)
  → ClickHouse otel.otel_traces / otel_logs
```

Every hop is gRPC with the default **4 MiB message-size ceiling**, and until
2026-08-23 every sender batched without a size cap.

## Problem

`ResourceExhausted` ("grpc: received message larger than max") is classified
by exporterhelper as permanent — the whole batch is discarded, no retry. The
failure was invisible to every health signal:

- `up == 1` everywhere; scrapes fine.
- `otelcol_receiver_refused_*` stays at zero on the receiving side: gRPC
  rejects an oversized message at the transport layer *before* the OTLP
  receiver's handler runs, so no receiver counter moves.
- Only `otelcol_exporter_send_failed_spans` on each sender and "Dropping
  data." log lines reveal it.

Observed loss (Prometheus `increase(otelcol_exporter_send_failed_spans[1h])`,
all senders summed):

| Window | Dropped spans/hour |
|---|---|
| Aug 22 evening peak | ~40–70k |
| Aug 23 01:30 UTC | ~72k |
| Aug 23 14:30–20:53 | ~37–72k per hour |
| Overnight quiet hours | 0 (no agent traffic) |

Roughly **half a million spans lost over two days**. Rejected message sizes
seen in pod logs: 5.0–5.4 MB at the connector hop, 6.3–7.4 MB at the
otel-collector → HyperDX hop, all against the 4 MiB limit. A 24h window
attributed **464k dropped spans to the middle collector alone** — it was both
victim (uncapped inbound from agents) and the biggest offender (its own
`send_batch_size: 1024`, no max).

## Fixes (in merge order)

| PR | Change |
|---|---|
| [#485](https://github.com/nijave/vmubtkube-a/pull/485) | connector `batch.send_batch_size` 1024 → 256 (first cut; insufficient alone — one fat OTLP request still exported whole without a max) |
| [#486](https://github.com/nijave/vmubtkube-a/pull/486) | connector `send_batch_size: 16`, `send_batch_max_size: 64` |
| [#487](https://github.com/nijave/vmubtkube-a/pull/487) | `otel-agent-trace-connector-alerts.yaml`: `AgentTraceConnectorExportDrops` (critical, `rate(otelcol_exporter_send_failed_spans[10m]) > 0`) and `AgentTraceConnectorIngestRejections` (warning, refused+failed receiver rates) |
| [#489](https://github.com/nijave/vmubtkube-a/pull/489) | chain-wide hardening: middle collector batch caps (`send_batch_size: 32`, `send_batch_max_size: 256`) + `max_recv_msg_size_mib: 32` and memory headroom on all three collectors |

Design direction: cap at the sender, stay generous at receivers, alert on any
residual failure.

## Field-name trap

All three collector versions here renamed the byte-based
`max_recv_msg_size` to:

```yaml
max_recv_msg_size_mib: 32   # integer MiB; old name fails strict validation
```

Verified in configgrpc source at v0.155.0, v0.158.0, v0.159.0. Using the old
name crash-loops a collector on startup — check the version before writing
receiver limits anywhere.

## HyperDX collector specifics (OpAMP)

Its static `/conf/relay.yaml` is a bootstrap; the real config arrives from the
HyperDX hub over OpAMP into `/etc/otel/supervisor-data/effective.yaml`. To
override receiver settings:

1. Set `global.otelCollector.customConfig` in `application.hyperdx.yaml`; the
   chart renders it into a ConfigMap and auto-wires
   `CUSTOM_OTELCOL_CONFIG_FILE`.
2. The supervisor merges local config files under the hub's remote config.
   The remote config defines `otlp/hyperdx` but sets no receive ceiling, so a
   locally added leaf survives the merge (confirmed live post-rollout).
3. Validation method before shipping: pull `effective.yaml` out of the running
   pod, add the leaf, run `otelcol validate --config` against the binary
   inside the container. Cheaper than gambling with the cluster-wide ingestor.
4. Its base config pins `memory_limiter limit_mib: 1500`; the pod previously
   had **no resource limits at all**. Now backed by requests 500m/1Gi,
   limits 2 cpu/4Gi.

## Measured results

Post-#489 rollout at 2026-08-23 20:53Z: zero failed exports at every hop from
rollout onward (previously ~22 spans/s on the connector during active use),
28k spans/10min landing in ClickHouse, alerts quiet.

Resources (window A = Aug 22 21:30 → Aug 23 20:53; window B = since rollout;
from `otelcol_process_memory_rss` and `rate(otelcol_process_cpu_seconds[10m])`
via prom-kp):

| Job | MEM A avg/max | MEM B avg/max | Limit | CPU A avg/max | CPU B |
|---|---|---|---|---|---|
| agent-trace-connector | 40 / 106 MiB | 58 / 58 MiB | 1 Gi (was 512Mi) | 4 / 15m | 7 / 13m |
| otel-collector | 288 / 356 MiB | 439 / 462 MiB | 2 Gi (was 512Mi) | 20 / 29m | 16 / 26m |
| hyperdx-otel-collector | 216 / 264 MiB | 305 / 354 MiB | 4 Gi (was none) | 37 / 42m | 19 / 26m |

Takeaways: capping batches costs no CPU; the middle collector's memory growth
is tail_sampling using its new headroom (still <25% of limit); the connector's
yesterday peak of 106 MiB would have been ~10% of its new limit.

## How to re-measure

```bash
kubectl -n monitoring port-forward svc/prom-kp-prometheus 9091:9090 &
# drops per hour, all senders
curl -sG 'http://localhost:9091/api/v1/query_range' \
  --data-urlencode 'query=sum(increase(otelcol_exporter_send_failed_spans[1h]))' \
  --data-urlencode "start=$(date -u -d '2 days ago' +%FT%TZ)" \
  --data-urlencode "end=$(date -u +%FT%TZ)" --data-urlencode 'step=1h'
```

Per-hop: group by `job` (`otel-agent-trace-connector`,
`otel-collector-opentelemetry-collector`, `hyperdx-otel-collector`). Live pod
config checks: ConfigMap for the first two; for HyperDX read
`/etc/otel/supervisor-data/effective.yaml` inside the container. Canonical
traces in ClickHouse: `SpanName LIKE 'invoke_agent%'` in `otel.otel_traces`.

## Open items

- [ ] No `otelcol_exporter_send_failed_log_records` metric exists upstream —
      a log-path export drop would be invisible to Prometheus (the
      receiver-side rule still catches front-door loss). Upstream gap.
- [ ] Watch `AgentTraceConnectorExportDrops` / memory for ~24h after rollout;
      revisit limits if the middle collector's RSS approaches 1 Gi.
