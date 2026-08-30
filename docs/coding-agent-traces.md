# Coding-agent traces (`agents-otel.k8s.somemissing.info`)

`otel-agent-trace-connector.yaml` deploys
[nijave/otel-agent-trace-connector](https://github.com/nijave/otel-agent-trace-connector),
a custom OCB-built Collector distribution carrying the `coding_agent` connector.
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
  vocabulary.

The collector forwards raw vendor telemetry **in parallel, unmodified**, so
the original Codex logs and Claude Code spans stay queryable in HyperDX
alongside the canonical traces.

## Where it sits

```text
Codex / Claude Code
  └─ agents-otel.k8s.somemissing.info:4317 (gRPC) / :4318 (HTTP)   [this service]
       ├─ logs + traces
       │    └─ otel-collector.k8s.somemissing.info:4317            [monitoring]
       │         └─ hyperdx-otel-collector.hyperdx:4317 → ClickHouse
       └─ metrics
            └─ thanos-receive-router.thanos.svc:19291 (remote write) → Thanos
```

The second hop is the same collector `projectcontour`'s `otel-collector`
forwards to.

## Pointing an agent at it

TLS is a public Let's Encrypt cert (DNS-01), so no CA needs trusting. The
hostname is LAN-only — see "DNS zones and TLS" in the [README](../README.md).

> **This collector accepts all three signals.** Logs and traces go to the
> downstream `otel-collector`; metrics take a separate path into Thanos
> Receive via remote write (the downstream collector still sets
> `metrics: null`, which preserves that contract). A generic
> `OTEL_EXPORTER_OTLP_ENDPOINT` now works for every signal; the
> signal-specific variables below are the more explicit option.

Claude Code — native trace export is still beta and off by default:

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://agents-otel.k8s.somemissing.info:4318/v1/metrics
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://agents-otel.k8s.somemissing.info:4318/v1/traces
```

Claude Code's *logs* carry prompt/tool content when you enable the
`OTEL_LOG_*` content gates; leave them unset. Its traces are what the
connector normalizes.

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

`trace_exporter` is optional here. Codex's native spans are not normalized (the
Claude edge drops any resource that has no `claude_code.`-prefixed span, so
there is no duplication), but pointing it at this collector still gets those
spans the 100% sampling exemption.

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

- **Single replica, `strategy: Recreate`** — deliberate. Codex turn correlation
  is in-memory; two replicas would split one turn's log records into two
  incomplete traces. The state does not survive a restart, so a roll or a crash
  drops in-flight turns. Completed traces survive both.
- `max_active_turns: 500` bounds that state. Turns close on a quiet
  `reorder_window` (30s) after `response.completed`, or at `turn_timeout` (10m).
- The connector is at **development stability** upstream; span names and
  attributes may change between releases.
- Renovate tracks the pinned image tag. Tagging the upstream repo cuts each
  release and publishes `ghcr.io/nijave/otel-agent-trace-connector`.
