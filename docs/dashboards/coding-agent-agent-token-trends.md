# coding-agent agent token trends (HyperDX dashboard)

Export and notes for the **`coding-agent agent token trends`** dashboard that
lives in the HyperDX/ClickStack instance in the `hyperdx` namespace.

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6a8b7c8daeb892a415c3446d`
- **Export snapshot:**
  [`coding-agent-agent-token-trends.json`](./coding-agent-agent-token-trends.json)
  (full dashboard document as stored in Mongo).
- **Data source:** same canonical connector spans as
  [`coding-agent model metrics`](./coding-agent-model-metrics.md) /
  [`coding-agent model trends`](./coding-agent-model-trends.md) —
  `SpanName LIKE 'chat %'`,
  `ResourceAttributes['telemetry.source'] = 'coding-agent'`.
- **Focus:** total token counts per **agent** (harness) over time — input,
  output, cache read, and cache write — instead of rates or latency.

## Tiles

Eight raw-SQL line charts (`displayType: "line"`, `configType: "sql"`), four
metrics × hourly / 5-minute pairs. Series dimension is the normalized agent;
line-chart result shape matches ClickStack's contract (timestamp column,
series-name column, value column).

| id | granularity | what it shows |
| --- | --- | --- |
| `ln-tok-in-hour` / `ln-tok-in-5m` | hourly / 5-min | input tokens by agent |
| `ln-tok-out-hour` / `ln-tok-out-5m` | hourly / 5-min | output tokens by agent |
| `ln-cache-read-hour` / `ln-cache-read-5m` | hourly / 5-min | cache read tokens by agent |
| `ln-cache-write-hour` / `ln-cache-write-5m` | hourly / 5-min | cache write (creation) tokens by agent |

## Formula notes

Token sums combine both attribute families, matching the sibling dashboards:

- **Input:** `sum(input_tokens) + sum(gen_ai.usage.input_tokens)`
- **Output:** `sum(output_tokens) + sum(gen_ai.usage.output_tokens)`
- **Cache read:** `sum(cache_read_tokens) +
  sum(gen_ai.usage.cache_read.input_tokens)`
- **Cache write:** `sum(cache_creation_tokens)` only — claude_code is the
  only harness that emits cache-creation counts; codex has no semconv
  equivalent and opencode emits no token attributes at all, so both render as
  flat zero on that tile.

Agent normalization is identical to the metrics dashboard:
`if(coding_agent.client.name != '', coding_agent.client.name,
if(ServiceName LIKE 'codex%', 'codex', ServiceName))`.

## Dashboard filter dropdowns

Same three variable-enabled filters as
[`coding-agent model trends`](./coding-agent-model-trends.md): **Model**
(`$model`), **Client / harness** (`$agent`), **Provider** (`$provider`) —
`QUERY_EXPRESSION` entries with `isVariableEnabled: true`,
`isBroadcastEnabled: false`, consumed by every tile via
`$__filter(<expression>, $<variable>)` macros (expand to `IN (...)` when
selected, `(1=1)` when empty). See that doc for details and caveats
(opencode spans carry no provider attribute and drop out when a provider is
selected).

## Known limitations

- **opencode rows are flat zero on all four tiles** — it emits no token
  attributes today; its request volume is visible on the model trends
  dashboards' error/latency tiles instead.
- **Cache write is claude_code-only** by data availability.
- Sparse buckets render as gaps, not zero-filled lines.

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
  'JSON.stringify(db.getSiblingDB("hyperdx").dashboards.findOne({name:"coding-agent agent token trends"}), null, 2)'
```

Edits go against the live document matched by `name`; the `_id` in the export
is informational. Changes are picked up by the HyperDX app without a restart.
Observe the BSON-type gotcha documented in
[`claude-code-model-trends.md`](./claude-code-model-trends.md) when inserting
from scripts, and validate tile SQL against ClickHouse directly (substituting
real epoch-milli values for the `{startDateMilliseconds:Int64}` /
`{endDateMilliseconds:Int64}` placeholders) before applying.
