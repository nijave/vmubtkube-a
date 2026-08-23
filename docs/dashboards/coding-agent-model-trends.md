# coding-agent model trends (HyperDX dashboard)

Export and notes for the **`coding-agent model trends`** dashboard that lives
in the HyperDX/ClickStack instance in the `hyperdx` namespace.

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6a8b6001aeb892a415c3446c`
- **Export snapshot:**
  [`coding-agent-model-trends.json`](./coding-agent-model-trends.json)
  (full dashboard document as stored in Mongo).
- **Data source:** identical criteria to
  [`coding-agent model metrics`](./coding-agent-model-metrics.md) — canonical
  connector spans (`SpanName LIKE 'chat %'`,
  `ResourceAttributes['telemetry.source'] = 'coding-agent'`). Where that
  dashboard is table/KPI-oriented, this one is time-series only.
- **Sibling of** [`claude-code model trends`](./claude-code-model-trends.md) —
  same six-tile line-chart layout, but scoped to all harnesses the
  [otel-agent-trace-connector](../../../otel-agent-trace-connector.yaml)
  normalizes instead of native Claude Code spans.

## Tiles

All six tiles are raw-SQL line charts (`displayType: "line"`,
`configType: "sql"`), paired hourly / 5-minute:

| id | granularity | what it shows |
| --- | --- | --- |
| `ln-err-hour` | hourly | error rate % by model |
| `ln-err-5m` | 5-minute | error rate % by model |
| `ln-tok-hour` | hourly | generation tok/sec by model |
| `ln-tok-5m` | 5-minute | generation tok/sec by model |
| `ln-lat-hour` | hourly | p50/p90/p99 latency (ms) per model × percentile |
| `ln-lat-5m` | 5-minute | p50/p90/p99 latency (ms) per model × percentile |

## Formula notes (deltas from the claude-code trends dashboard)

The tile SQL follows the coding-agent model metrics dashboard's conventions,
not the claude-code ones:

- **Error rate counts explicit failures only:** `success = 'false'`, not
  `!= 'true'` — sources that don't emit `success` would otherwise read as 100%
  errors.
- **Latency uses span `Duration`** (nanoseconds, present on every span):
  `quantiles(0.5, 0.9, 0.99)(Duration)` divided by `1e6`. The
  `duration_ms` attribute only exists on claude_code spans.
- **`gen_toks` is guarded** — it returns 0 unless
  `sum(duration_ms) - sum(ttft_ms) > 0`, so harnesses without TTFT attributes
  (codex, opencode) don't produce an inflated tokens/sec value; output tokens
  sum both attribute families (`output_tokens` +
  `gen_ai.usage.output_tokens`).
- **Model column:** `gen_ai.request.model`; series dimension is model only
  (no agent split — that would multiply the line count by harness).
- Line-chart result shape matches ClickStack's documented contract:
  timestamp column, series-name column, value column, `GROUP BY <series>, ts`.
  The latency tile emits one series per model×percentile named
  `<model> · pNN` via
  `arrayZip(['p50','p90','p99'], quantiles(...))` + `ARRAY JOIN`.

- **Known limitations:** no percentile dropdown (percentile is baked into the
  series construction); series count grows with models used (×3 on latency
  tiles); sparse buckets render as gaps, not zero-filled lines; gen_toks lines
  are flat-zero for models whose harnesses never set TTFT / `duration_ms`
  attributes (e.g. codex-only models).

## Dashboard filter dropdowns

Three variable-enabled dashboard filters render as dropdowns at the top of
the dashboard: **Model**, **Client / harness**, and **Provider**. Each is a
`QUERY_EXPRESSION` entry in the doc's `filters` array with
`isVariableEnabled: true` (`isBroadcastEnabled: false` — filtering happens via
explicit macros in the tile SQL, not broadcast). Every tile's `sqlTemplate`
consumes them via `$__filter(<expression>, $<variable>)` macros, which expand
to `<expression> IN (<selected values>)` when values are picked and to `(1=1)`
when nothing is selected, so charts stay valid unfiltered.

| filter | variableName | expression | coverage note |
| --- | --- | --- | --- |
| Model | `$model` | `SpanAttributes['gen_ai.request.model']` | all canonical spans |
| Client / harness | `$agent` | `if(SpanAttributes['coding_agent.client.name'] != '', …, if(ServiceName LIKE 'codex%', 'codex', ServiceName))` | same normalization as the metrics dashboard |
| Provider | `$provider` | `SpanAttributes['gen_ai.provider.name']` | claude_code + codex only — opencode emits no provider attribute, so opencode rows drop out when a provider is selected |

Notes:

- The macro argument parser is quote-aware and paren-counting, so the
  comma-heavy nested `if()` harness expression parses as a single argument.
- Expansion was verified with the deployed app's own `replaceMacros`
  (`common-utils/dist/macros.js`) against all 12 stored templates in both
  empty and selected states before applying.


## Applying / re-exporting

Same procedure as the sibling dashboards: dashboards live in the Mongo replica
set backing HyperDX; connection string is in secret
`hyperdx-mongo-app-connection` (namespace `hyperdx`) — do not print it.

```sh
CONN=$(kubectl get secret -n hyperdx hyperdx-mongo-app-connection \
  -o jsonpath='{.data.connectionString\.standard}' | base64 -d)

# Export the live dashboard
kubectl exec -n hyperdx hyperdx-0 -c mongod -i -- \
  mongosh "$CONN" --quiet --eval \
  'JSON.stringify(db.getSiblingDB("hyperdx").dashboards.findOne({name:"coding-agent model trends"}), null, 2)'
```

Edits go against the live document matched by `name`; the `_id` in the export
is informational. Changes are picked up by the HyperDX app without a restart.

### Gotcha: BSON types on insert

The JSON export is not insertable as-is via `mongosh`. The app stores and
queries several fields with specific BSON types; if they are inserted as plain
strings/ISO strings, **the dashboard silently disappears from the UI list**
(the list query filters `team` by ObjectId, so a string-typed `team` never
matches). When inserting/updating from a script, cast:

- `team`, `createdBy`, `updatedBy` → `ObjectId(...)`
- `createdAt`, `updatedAt` → `new Date("...")`
- include `__v: 0`

Symptom of getting this wrong: `findOne({name: ...})` still returns the doc,
but it never appears in the dashboards list.

Before applying tile SQL changes, validate them against ClickHouse directly by
substituting real epoch-milli values for the `{startDateMilliseconds:Int64}` /
`{endDateMilliseconds:Int64}` placeholders (see
[`../hyperdx-dashboards.md`](../hyperdx-dashboards.md) for why there is no
`{timeFilter}` macro in raw-SQL tiles).

## Filter value-query scope

Each filter also carries a `where` clause scoping its dropdown value query to
the relevant spans (`SpanName LIKE 'chat %' AND
ResourceAttributes['telemetry.source'] = 'coding-agent'` on the coding-agent
dashboards, `SpanName = 'claude_code.llm_request' AND ServiceName =
'claude-code'` on the claude-code one). Without it, the value lookup runs the
expression against every span in the database and non-connector rows fall
through to `ServiceName`, so the harness dropdown listed all services.
