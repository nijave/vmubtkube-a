# coding-agent model metrics (HyperDX dashboard)

Export and notes for the **`coding-agent model metrics`** dashboard that lives
in the HyperDX/ClickStack instance in the `hyperdx` namespace.

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6a8b5d7bc0092c5adc32a03c`
- **Export snapshot:** [`coding-agent-model-metrics.json`](./coding-agent-model-metrics.json)
  (full dashboard document as stored in Mongo).
- **Data source:** ClickHouse `otel.otel_traces`, filtered to canonical spans
  from the [otel-agent-trace-connector](../../../otel-agent-trace-connector.yaml):
  `SpanName LIKE 'chat %'` and
  `ResourceAttributes['telemetry.source'] = 'coding-agent'`. The connector's
  `resource/coding_agent` processor tags everything it exports, so this filter
  selects its output; raw vendor traces forwarded alongside it keep their
  native span names (`claude_code.*`, `ai.*`, …) and never match.
- **Sibling of** [`claude-code model metrics`](./claude-code-model-metrics.md) —
  same tile layout, but scoped to all harnesses the connector normalizes
  (claude_code, codex, opencode, pi, …) instead of native Claude Code spans.

## Tiles

| id | type | what it shows |
| --- | --- | --- |
| `kpi-reqs` | number | total LLM requests |
| `kpi-err` | number | error rate % (spans with `StatusCode = 'Error'`) |
| `kpi-ttft` | number | TTFT p95 (ms; `gen_ai.response.time_to_first_chunk` × 1000) |
| `kpi-lat` | number | latency p95 (ms, from span `Duration`) |
| `tbl-models` | table | per-model × per-agent metrics |
| `tbl-agents` | table | per-agent totals |
| `tbl-daily` | table | daily trend per agent |

## Dimension and attribute notes

- **Agent column:** `if(SpanAttributes['coding_agent.client.name'] != '',
  SpanAttributes['coding_agent.client.name'],
  if(ServiceName LIKE 'codex%', 'codex', ServiceName))`. Codex canonical spans
  carry no `coding_agent.client.name`, so they fall back to a normalized
  ServiceName (`codex_cli_rs`/`codex_exec` → `codex`); every other harness
  sets it.
- **Model column:** `gen_ai.request.model` (present on every canonical chat
  span, unlike the harness-specific `model` attribute).
- **Latency columns use `Duration`** (nanoseconds, present on every span)
  rather than the `duration_ms` attribute — opencode/codex chat spans don't
  set `duration_ms`, so attribute-based latency would silently cover only
  claude_code.
- **Token sums read GenAI-semconv only:** `gen_ai.usage.input_tokens`,
  `gen_ai.usage.cache_read.input_tokens`,
  `gen_ai.usage.cache_write.input_tokens`, `gen_ai.usage.output_tokens`.
  The legacy family (`input_tokens`, `cache_read_tokens`, `output_tokens`)
  is no longer emitted by the connector and was dropped; the table tiles
  gained a `tok_cache_write` column next to `tok_cache`. opencode emits no
  token attributes (its rows show 0 tokens).
- **Error rate uses span `StatusCode = 'Error'`** — the connector no longer
  emits a `success` attribute.
- **`gen_toks` counts only the generation window:** it sums
  `gen_ai.usage.output_tokens` over spans where
  `gen_ai.response.time_to_first_chunk` is set and `Duration` exceeds it,
  divided by the summed `Duration - TTFC` (seconds); it returns 0 when no
  qualifying span contributes, so spans without TTFC don't skew it.
- **TTFT comes from `gen_ai.response.time_to_first_chunk`** (seconds, as a
  float string) — set by claude_code, pi, and most codex spans. Quantiles use
  `quantileIf` keyed on the attribute being non-empty so spans without it
  don't drag percentiles toward 0.
- **There is no retry dimension:** no harness emits an `attempt` attribute,
  so the retry KPI became an error-rate KPI (`kpi-err`) and `retry_pct`
  columns were removed.

## Applying / re-exporting

Same procedure as the claude-code dashboard: dashboards live in the Mongo
replica set backing HyperDX; connection string is in secret
`hyperdx-mongo-app-connection` (namespace `hyperdx`) — do not print it.

```sh
CONN=$(kubectl get secret -n hyperdx hyperdx-mongo-app-connection \
  -o jsonpath='{.data.connectionString\.standard}' | base64 -d)

# Export the live dashboard
kubectl exec -n hyperdx hyperdx-0 -c mongod -i -- \
  mongosh "$CONN" --quiet --eval \
  'JSON.stringify(db.getSiblingDB("hyperdx").dashboards.findOne({name:"coding-agent model metrics"}), null, 2)'
```

Edits go against the live document matched by `name`; the `_id` in the export
is informational. Changes are picked up by the HyperDX app without a restart.

## Possible follow-ups

- A `vcs.repository.name` repo dimension — canonical claude_code spans carry
  it (~40% of spans at creation time). Not added yet to avoid blank-heavy
  rows; gate on `ResourceAttributes['vcs.repository.name'] != ''` or wait for
  fuller rollout.
- If opencode starts emitting usage/latency attributes upstream, revisit the
  zero-token rows in `tbl-models`.
