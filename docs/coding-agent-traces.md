# Coding-agent traces (`agents-otel.k8s.somemissing.info`)

`otel-agent-trace-connector.yaml` deploys
[nijave/otel-agent-trace-connector](https://github.com/nijave/otel-agent-trace-connector),
a custom OCB-built Collector distribution carrying the `coding_agent` connector,
behind a gateway in `otel-agent-gateway.yaml` (see [HA topology](#ha-topology)).
It gives Codex and Claude Code a **single comparable trace shape**:

```text
invoke_agent <agent>
├── chat <model>
└── execute_tool <tool>
```

- **Codex** emits structured `codex.*` OTLP **logs**, not traces. The connector
  correlates them in memory into one canonical trace per user turn.
- **Claude Code** already emits a native span tree
  (`claude_code.interaction` → `llm_request` / `tool`, see
  [project attribution](./claude-code-otel-project-attribution.md)). The
  connector preserves that hierarchy and renames spans/attributes into the same
  vocabulary. Chat spans are the exception: with `claude_code.chat_source:
  logs` the connector builds them from the `claude_code.api_request` /
  `api_error` log events and drops the native `llm_request` span. Only the
  logs carry per-request cost (`coding_agent.usage.cost`) and API failures.

The collector forwards raw vendor telemetry **in parallel, unmodified**, so
the original Codex logs and Claude Code spans stay queryable in HyperDX
alongside the canonical traces.

## Where it sits

```text
Codex / Claude Code
  └─ agents-otel.k8s.somemissing.info:4317 (gRPC) / :4318 (HTTP)   [Service otel-agent-trace-connector]
       └─ otel-agent-gateway × 2 (tier 1, stock contrib, TLS ends here)
            └─ otel-agent-trace-connector-headless:4317 (consistent hash)
                 └─ otel-agent-trace-connector × 2 (tier 2, coding_agent connector)
                      ├─ logs + traces
                      │    └─ otel-collector.k8s.somemissing.info:4317   [monitoring]
                      │         └─ hyperdx-otel-collector.hyperdx:4317 → ClickHouse
                      └─ metrics
                           └─ thanos-receive-router.thanos.svc:19291 (remote write) → Thanos
```

The second hop is the same collector `projectcontour`'s `otel-collector`
forwards to.

## HA topology

The connector holds each Codex turn in memory until the turn closes, so every
record of a turn must reach the same process. A plain Service in front of two
connector pods would split turns. The ingest has two tiers instead, after the
upstream [multi-instance HA analysis][ha] (option B) and its `examples/k8s-ha`:

- **Tier 1, `otel-agent-gateway.yaml`**: stock
  `otel/opentelemetry-collector-contrib`, 2 replicas, stateless. It owns the
  agent-facing Service, hostname, and certificate. A `routing` connector and
  `load_balancing` exporters hash each record onto one tier-2 pod:

  | Traffic | Hash key | Why |
  | --- | --- | --- |
  | Codex/Cursor logs (`conversation.id`, `cursor.conversation.id`) | the conversation | the turn state lives on one pod |
  | all other logs (Claude Code included) and all traces | trace ID | spreads load, keeps a trace whole |
  | metrics | stream identity (`streamID`) | `delta_to_cumulative` keeps a running total per series |

  The k8s resolver watches the EndpointSlices of the headless Service (the
  Role in the same file grants that) and drops pods that are not ready.

- **Tier 2, `otel-agent-trace-connector.yaml`**: the connector image with the
  same connector, batch, and export settings as the single replica had, 2
  replicas behind `otel-agent-trace-connector-headless`. It accepts plain
  gRPC from the gateway only; a NetworkPolicy closes it to everything else
  (Prometheus can still scrape `:8888`).

Claude Code does not need its trace and its `api_request`/`api_error` logs on
the same pod. Both Claude edges are stateless: the logs edge takes the chat
span's trace ID and parent from the log record, and the traces edge needs
nothing from the logs. `load_balancing` hashes a log's trace ID as its hex
string but a span's as raw bytes, so the two land on different pods about
half the time, and that is fine here.

Both tiers have a PodDisruptionBudget (`maxUnavailable: 1`), prefer separate
nodes, and roll on config change through Reloader.

Gateway resilience: each tier-2 pod gets 30s of retries; after that the batch
goes back to the exporter-level queue (in memory, 64 MiB per exporter), which
retries for up to 5 minutes and re-hashes against the current ring each time.
Data for a pod that left the ring thus moves to a live one. A graceful gateway
stop drains the queue (`terminationGracePeriodSeconds: 60`); a gateway crash
loses whatever the queue held.

[ha]: https://github.com/nijave/otel-agent-trace-connector/blob/main/docs/multi-instance-ha.md

## Pointing an agent at it

TLS is a public Let's Encrypt cert (DNS-01), so no CA needs trusting. The
hostname is LAN-only — see "DNS zones and TLS" in the [README](../README.md).

> **This collector accepts all three signals.** Logs and traces go to the
> downstream `otel-collector`; metrics take a separate path into Thanos
> Receive via remote write (the downstream collector still sets
> `metrics: null`, which preserves that contract). A generic
> `OTEL_EXPORTER_OTLP_ENDPOINT` now works for every signal; the
> signal-specific variables below are the more explicit option.

Claude Code — native trace export is still beta and off by default. Export
logs **and** traces: the canonical trace takes its interaction and tool spans
from the traces and its chat spans from the logs, so a session missing either
one is incomplete.

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://agents-otel.k8s.somemissing.info:4318/v1/metrics
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_LOGS_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://agents-otel.k8s.somemissing.info:4318/v1/logs
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://agents-otel.k8s.somemissing.info:4318/v1/traces
```

Claude Code's *logs* carry prompt/tool content when you enable the
`OTEL_LOG_*` content gates; leave them unset. The connector reads only the
`api_request` / `api_error` events and copies no content into canonical
spans, but it forwards the raw logs verbatim.

Both connector instances (`coding_agent` on the logs pipeline,
`coding_agent/claude` on the traces pipeline) share one config through a YAML
anchor. `claude_code.chat_source` must be the same on every instance that sees
Claude Code telemetry; a mismatch gives each request two chat spans or none.

Agent metrics are remote-written to Thanos. Claude Code exports delta
temporality, which the remote-write exporter drops, so the metrics pipeline
runs `delta_to_cumulative` first; the client needs no temporality setting. The
processor keeps per-series totals in memory; the gateway's `streamID` route
sends every point of a series to the same tier-2 pod. See
[Delta metrics across tier-2 changes](#delta-metrics-across-tier-2-changes)
for what happens when a series changes pod.

Codex reads **user-level** `~/.codex/config.toml` only — it ignores
project-local `[otel]` blocks (it warns and drops an `otel` key found in a
project `.codex/config.toml`).

```toml
[otel]
environment = "production"
log_user_prompt = false
exporter       = { otlp-grpc = { endpoint = "https://agents-otel.k8s.somemissing.info:4317" } }
trace_exporter = { otlp-grpc = { endpoint = "https://agents-otel.k8s.somemissing.info:4317" } }
metrics_exporter = { otlp-grpc = { endpoint = "https://agents-otel.k8s.somemissing.info:4317" } }
```

`otel.exporter` is the **logs** exporter and defaults to `"none"`. Codex emits
its `codex.*` events as OTLP *logs*, not traces, so **this is the one the
connector needs** — `trace_exporter` alone produces no canonical Codex traces.

`trace_exporter` is optional here. The connector sets `codex.signals: [logs]`,
so its Codex native-traces edge is not built and the native spans produce no
second canonical trace per turn. They are still forwarded raw (with the 100%
sampling exemption) and add what the logs lack, such as MCP identity and
per-turn token totals.

`metrics_exporter` defaults to Statsig rather than OTLP; set it like
`exporter` above to route Codex metrics through this collector into Thanos.

Keep `log_user_prompt = false`. The connector never copies prompt text, tool
arguments, or tool output into generated spans, but it forwards the **raw**
Codex logs verbatim, so anything Codex logs does reach ClickHouse.

## Sampling

These traces are exempt from the downstream 1% probabilistic tail sampling. The
collector tags everything it forwards with the resource attribute
`telemetry.source=coding-agent` (its `resource/coding_agent` processor), and the
`coding-agent` `tail_sampling` policy in `application.otel-collector.yaml`
always-samples on that tag. Both the raw and the canonical output carry it.

If you add another hop between here and HyperDX, it needs the same exemption.

## Operational limits

- Codex turn state lives in memory on one tier-2 pod and does not survive
  that pod. See [What a restart loses](#what-a-restart-loses).
- `codex.max_active_turns: 500` bounds that state per pod. Turns close on a quiet
  `reorder_window` (30s) after `response.completed`, or at `turn_timeout`
  (10m). The unused Cursor edge gets the same bounds in its `cursor:` block.
- The connector is at **development stability** upstream; span names and
  attributes may change between releases.
- Renovate tracks the pinned image tag. Tagging the upstream repo cuts each
  release and publishes `ghcr.io/nijave/otel-agent-trace-connector`.

## What a restart loses

Measured locally before the cutover with these configs (2 gateways, 2
connectors; a static resolver stood in for the k8s one, and gateway restarts
stood in for EndpointSlice updates). The replay sent 12 Codex turns, 16
Claude Code traces with their `api_request` logs, and 8 delta metric streams
through both gateways over 40s, then restarted one pod 15s in. A tier-2
"restart" followed the k8s order: the pod leaves the endpoint list, gets
SIGTERM, and a replacement with a new address joins.

- **Gateway (tier 1)**: nothing lost. Agents retried the refused connections
  (7 retries in the run) and every turn and trace arrived whole. A graceful
  stop drains the gateway queue; only a crash loses what the queue held.
- **Connector (tier 2)**: the pod flushes each in-flight Codex/Cursor turn
  at once as finish reason `shutdown` (self-metric
  `otelcol_coding_agent_turns_emitted{finish_reason="shutdown"}`), a root
  with only what it had seen. The rest of those turns then lands on another
  pod and becomes a second trace with a different trace ID. If the
  replacement pod joins the ring while the turn is still active, the turn
  can split a third time. In the run, 10 of 12 active turns hashed to the
  restarted pod: 4 became two traces and 6 became three. The raw Codex logs
  all arrived (64 of 64 per turn), so a turn can be rebuilt by replaying its
  raw logs through one connector. Turns on the other pod that the ring
  change moves split the same way. Completed turns are not affected.
- **Claude Code and other stateless traffic**: unaffected in either case.
  In a Claude-only replay of 48 traces across the same tier-2 restart, every
  `api_request` log produced exactly one chat span with the log's trace and
  parent, with no `llm_request` spans and no duplicates.
- **Delta metrics**: see the next section.

A tier-2 roll (config change, image bump, node drain) costs about
what a restart of the old single replica cost, twice: once per pod, plus the
remap when each replacement joins. Expect a few `shutdown` turns and split
traces per roll when agents are busy.

## Delta metrics across tier-2 changes

Each tier-2 pod adds `collector_replica=<pod name>` to every series it
remote-writes (`external_labels` on `prometheus_remote_write`, pod name from
the downward API). `delta_to_cumulative` keeps a running total per series
*per pod*, so the label gives each pod's totals their own series, and every
series stays monotonic. **Always sum the label away** in queries over these
metrics:

```promql
sum without (collector_replica) (increase(claude_code_token_usage_tokens_total[1h]))
sum by (model) (rate(claude_code_cost_usage_USD_total[5m]))
```

For a gauge, use `max without (collector_replica)` instead of `sum`: after a
stream moves, the old pod's last value stays visible for the 5m lookback.

Without the label, a stream that changes pod continues the *same* series
from a different total. A move to a fresh pod reads as a counter reset and
counts right, but a stream that returns within `max_stale` (5m) to a pod
that still holds its old total, or that two pods write at the same time,
corrupts `increase()`. Measured locally (8 delta streams, one point per 2s;
true total is the sum of the deltas sent; `increase()` over the whole run
from a real Prometheus 3.16 fed by the same remote write):

| Scenario | Without label | With `collector_replica` |
| --- | --- | --- |
| stream moves to a fresh pod (k8s-order tier-2 restart) | 1259.8 / 1260 | 1223.1 / 1224 |
| stream moves away and back to a pod with state | 1176.2 / 1188 (-1.0%; one earlier run over-counted one stream by 9 of 31) | 1149.5 / 1152 |
| two gateways send one stream to two pods | 498.9 / 720 (-31%) | 720.0 / 720 |

Without the label the error on a return has either sign: the step from the
other pod's last value to the old pod's resumed total counts as a reset
(over-count by the old total) or as a too-small increase (under-count). With
the label the remaining gap is `increase()` extrapolation at the window
edges, under 0.25% in these runs. A brand-new series does not lose its
first delta in practice: its first value is one interval's delta, and
`increase()` extrapolates a counter back to zero over about one interval.

A pod restart also starts new series, because the pod name changes. Old
series simply stop.

## Post-deploy checks

Run these after the cutover and after any tier-2 roll.

1. **Load spreads across both tier-2 pods.** Both pods accept data and the
   gateways see 2 backends:

   ```promql
   sum by (pod) (rate(otelcol_receiver_accepted_log_records{job="otel-agent-trace-connector"}[15m]))
   min by (pod) (otelcol_loadbalancer_num_backends{job="otel-agent-gateway"})
   ```

2. **One canonical trace per Codex turn.** Compare canonical roots against
   `codex.user_prompt` events per conversation. A few mismatches at the
   window edges are normal (the pre-cutover baseline had 3 in 3 days); more
   than that outside a roll means turns are splitting.

   ```sql
   SELECT conv, roots, prompts FROM (
     SELECT SpanAttributes['gen_ai.conversation.id'] AS conv, count() AS roots
     FROM otel.otel_traces
     WHERE SpanAttributes['gen_ai.operation.name'] = 'invoke_agent'
       AND SpanAttributes['coding_agent.client.name'] = 'codex'
       AND SpanAttributes['coding_agent.source'] = 'normalized'
       AND Timestamp > now() - INTERVAL 1 DAY GROUP BY conv) r
   LEFT JOIN (
     SELECT LogAttributes['conversation.id'] AS conv, count() AS prompts
     FROM otel.otel_logs
     WHERE LogAttributes['event.name'] = 'codex.user_prompt'
       AND TimestampTime > now() - INTERVAL 1 DAY GROUP BY conv) p USING conv
   WHERE roots != prompts
   ```

   `otelcol_coding_agent_turns_emitted{finish_reason="shutdown"}` should
   only move during a tier-2 roll.

3. **Claude chat spans join their trace.** The chat span and the rest of
   its trace often come from different tier-2 pods; expect 0 orphans:

   ```sql
   SELECT count() AS chat_spans,
          countIf((TraceId, ParentSpanId) NOT IN (
            SELECT TraceId, SpanId FROM otel.otel_traces
            WHERE Timestamp > now() - INTERVAL 26 HOUR)) AS orphans
   FROM otel.otel_traces
   WHERE SpanName LIKE 'chat %'
     AND SpanAttributes['coding_agent.client.name'] = 'claude_code'
     AND Timestamp > now() - INTERVAL 24 HOUR
   ```

4. **No metric translation failures.**
   `otelcol_exporter_prometheusremotewrite_failed_translations{job="otel-agent-trace-connector"}`
   stays flat and `AgentTraceConnectorMetricsTranslationFailures` stays
   silent; agent series (for example `claude_code_token_usage_tokens_total`)
   keep arriving in Thanos, each with a `collector_replica` label naming a
   current tier-2 pod.

5. **No gateway export failures.** These stay flat and the
   `otel-agent-gateway` alert group stays silent:

   ```promql
   sum by (exporter) (rate(otelcol_exporter_send_failed_log_records{job="otel-agent-gateway"}[15m]))
   sum by (exporter) (rate(otelcol_exporter_send_failed_spans{job="otel-agent-gateway"}[15m]))
   sum by (endpoint) (rate(otelcol_loadbalancer_backend_outcome{job="otel-agent-gateway", success="false"}[15m]))
   ```

## Dashboards

HyperDX dashboards built on the canonical traces:

- [coding-agent model metrics](./dashboards/coding-agent-model-metrics.md)
- [coding-agent model trends](./dashboards/coding-agent-model-trends.md)
- [coding-agent agent token trends](./dashboards/coding-agent-agent-token-trends.md)
- [coding-agent usage insights](./dashboards/coding-agent-usage-insights.md)
