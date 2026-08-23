# claude-code model trends (HyperDX dashboard)

Export and notes for the **`claude-code model trends`** dashboard that lives in
the HyperDX/ClickStack instance in the `hyperdx` namespace.

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6a519951318e69d22b7658fd`'s sibling — this document is
  `6a8b5924aeb892a415c3446b`.
- **Export snapshot:** [`claude-code-model-trends.json`](./claude-code-model-trends.json)
  (full dashboard document as stored in Mongo).
- **Data source:** ClickHouse `otel.otel_traces`, filtered to
  `SpanName = 'claude_code.llm_request'` and `ServiceName = 'claude-code'`,
  same as [`claude-code-model-metrics.md`](./claude-code-model-metrics.md).
  Where that dashboard is table/KPI-oriented, this one is time-series only.

## Tiles

All six tiles are raw-SQL line charts (`displayType: "line"`,
`configType: "sql"`), paired hourly / 5-minute so the right granularity is
available at both day-scale and hour-scale zoom:

| id | granularity | what it shows |
| --- | --- | --- |
| `ln-err-hour` | hourly | error rate % by model (`success != 'true'`) |
| `ln-err-5m` | 5-minute | error rate % by model |
| `ln-tok-hour` | hourly | generation tok/sec by model |
| `ln-tok-5m` | 5-minute | generation tok/sec by model |
| `ln-lat-hour` | hourly | p50/p90/p99 latency (ms) per model × percentile |
| `ln-lat-5m` | 5-minute | p50/p90/p99 latency (ms) per model × percentile |

Line-chart SQL shape: each query returns a timestamp column (`ts`), a series
name column, and a value column, then `GROUP BY <series>, ts`. This matches the
contract ClickStack documents for raw-SQL line charts. The latency tile folds
model and percentile into one series name (`<model> · p90`) because the chart
renders a single group column; it uses
`arrayZip(['p50','p90','p99'], quantiles(0.5, 0.9, 0.99)(...))` expanded with
`ARRAY JOIN`. Generation tok/sec reuses the `gen_toks` formula from the model
metrics dashboard:
`sum(output_tokens) / greatest(sum(duration_ms - ttft_ms), 1) * 1000`.

## Dashboard filter dropdowns

Two variable-enabled dashboard filters render as dropdowns at the top of the
dashboard: **Model** and **Provider**. Each is a `QUERY_EXPRESSION` entry in
the doc's `filters` array with `isVariableEnabled: true`
(`isBroadcastEnabled: false` — filtering happens via explicit macros in the
tile SQL, not broadcast). Every tile's `sqlTemplate` consumes them via
`$__filter(<expression>, $<variable>)` macros, which expand to
`<expression> IN (<selected values>)` when values are picked and to `(1=1)`
when nothing is selected, so charts stay valid unfiltered.

| filter | variableName | expression | coverage note |
| --- | --- | --- | --- |
| Model | `$model` | `SpanAttributes['gen_ai.request.model']` | all spans |
| Provider | `$provider` | `SpanAttributes['provider.name']` | ~99.8% of spans; reports the API provider (e.g. z.ai), not `gen_ai.system` |

There is no harness dropdown — every span on this dashboard is Claude Code by
definition.

Expansion was verified with the deployed app's own `replaceMacros`
(`common-utils/dist/macros.js`) against all 12 stored templates in both empty
and selected states before applying.

Each filter also carries a `where` clause scoping its dropdown value query to
the relevant spans (`SpanName LIKE 'chat %' AND
ResourceAttributes['telemetry.source'] = 'coding-agent'` on the coding-agent
dashboards, `SpanName = 'claude_code.llm_request' AND ServiceName =
'claude-code'` on the claude-code one). Without it, the value lookup runs the
expression against every span in the database and non-connector rows fall
through to `ServiceName`, so a harness-style dropdown would list every service.

## Known limitations

- **No percentile filter.** The p50/p90/p99 split is baked into series
  construction, so it can't be a dropdown; isolate percentiles visually via
  the `<model> · pNN` legend entries.
- **Series count grows with models used.** Each new `gen_ai.request.model`
  value adds lines to all six tiles (×3 on the latency tiles).
- **Sparse buckets render as gaps.** Models used intermittently show broken
  lines rather than zero-filled ones.
- **Provider selection drops unattributed spans.** Spans without
  `provider.name` (~0.2%) are excluded whenever a provider is picked.

## Applying / re-exporting

Same procedure as the model metrics dashboard: dashboards live in the Mongo
replica set backing HyperDX; the connection string is in the
`hyperdx-mongo-app-connection` secret (namespace `hyperdx`); do not print it —
feed it straight into `mongosh` from inside a mongod pod.

```sh
CONN=$(kubectl get secret -n hyperdx hyperdx-mongo-app-connection \
  -o jsonpath='{.data.connectionString\.standard}' | base64 -d)

# Export the live dashboard
kubectl exec -n hyperdx hyperdx-0 -c mongod -i -- \
  mongosh "$CONN" --quiet --eval \
  'JSON.stringify(db.getSiblingDB("hyperdx").dashboards.findOne({name:"claude-code model trends"}), null, 2)'
```

Edits are made directly against the `dashboards` collection (e.g.
`replaceOne({name: ...}, doc, {upsert: true})` to recreate or update the whole
document). Changes are picked up by the HyperDX app without a restart. The
`_id` in the JSON export is informational — the live document is matched by
`name`.

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

## Project attribution

These spans carry no project/repo dimension by default. See
[`../claude-code-otel-project-attribution.md`](../claude-code-otel-project-attribution.md)
for the shell wrapper that adds `vcs.*` / `process.working_directory` resource
attributes. Once sessions emit `vcs.repository.name`, a repo dimension can be
added to these tiles the same way as described for the model metrics dashboard
— but note it multiplies the series count further (repo × model × percentile).
