# claude-code model metrics (HyperDX dashboard)

Export and notes for the **`claude-code model metrics`** dashboard that lives in
the HyperDX/ClickStack instance in the `hyperdx` namespace.

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6a519951318e69d22b7658fd`
- **Export snapshot:** [`claude-code-model-metrics.json`](./claude-code-model-metrics.json)
  (full dashboard document as stored in Mongo).
- **Data source:** ClickHouse `otel.otel_traces`, filtered to
  `SpanName = 'claude_code.llm_request'` and `ServiceName = 'claude-code'`.
  Metrics come from `SpanAttributes` on those spans.

## Tiles

| id | type | what it shows |
| --- | --- | --- |
| `kpi-reqs` | number | total LLM requests |
| `kpi-retry` | number | retry rate % (`attempt` > 1) |
| `kpi-ttft` | number | TTFT p95 (ms) |
| `kpi-lat` | number | latency p95 (ms) |
| `tbl-models` | table | per-model metrics (one row per `gen_ai.request.model`) |
| `tbl-daily` | table | daily trend |

## Token columns (2026-07-22 change)

The per-model table (`tbl-models`) previously reported **average** tokens per
request under the column names `in_tok`, `cache_read`, `out_tok`. These were
renamed and switched from averages (`avg`) to **sums** (`sum`), so they now
report total tokens over the selected time window:

| old column | old aggregate | new column | new aggregate | attribute |
| --- | --- | --- | --- | --- |
| `in_tok` | `avg(...)` | `tok_in` | `sum(...)` | `input_tokens` |
| `cache_read` | `avg(...)` | `tok_cache` | `sum(...)` | `cache_read_tokens` |
| `out_tok` | `avg(...)` | `tok_out` | `sum(...)` | `output_tokens` |

Each remains wrapped in `round(..., 0)`. No other tiles or columns were changed;
`gen_toks` (generation tokens/sec) already used `sum(...)` and is unrelated.

## Applying / re-exporting

Dashboards are stored in the Mongo replica set backing HyperDX. The connection
string is in the `hyperdx-mongo-app-connection` secret (namespace `hyperdx`);
do not print it — feed it straight into `mongosh` from inside a mongod pod.

```sh
CONN=$(kubectl get secret -n hyperdx hyperdx-mongo-app-connection \
  -o jsonpath='{.data.connectionString\.standard}' | base64 -d)

# Export the live dashboard
kubectl exec -n hyperdx hyperdx-0 -c mongod -i -- \
  mongosh "$CONN" --quiet --eval \
  'JSON.stringify(db.getSiblingDB("hyperdx").dashboards.findOne({name:"claude-code model metrics"}), null, 2)'
```

Edits are made directly against the `dashboards` collection (e.g. `updateOne`
with an `arrayFilters` matching the tile `id`). Changes are picked up by the
HyperDX app without a restart. The `_id` in the JSON export is informational —
the live document is matched by `name`.

## Project attribution

These spans carry no project/repo dimension by default. See
[`../claude-code-otel-project-attribution.md`](../claude-code-otel-project-attribution.md)
for the shell wrapper that adds `vcs.*` / `process.working_directory` resource
attributes and the upstream issue status.

### TODO: add a repo/project dimension (blocked on client rollout)

Once sessions are emitting `ResourceAttributes['vcs.repository.name']` (from the
shell wrapper above), add a `repo` grouping/filter to this dashboard — e.g. a
`GROUP BY` column in `tbl-models` / `tbl-daily`, or a dashboard-level filter.

**This is dependent on client updates and cannot be done yet:**

- The attribute only exists on spans from sessions started *after* the wrapper
  is in place on each machine. This is per-client config, not a server change —
  every workstation that runs `claude`/`zclaude` must pick up the updated
  `.bashrc` (and non-login-shell launchers like Zed/ACP, JetBrains, and cron
  need the env set separately; they bypass the wrapper).
- Historical spans have no `vcs.*` attributes, so any repo-grouped tile will
  show blanks/`""` for pre-rollout data. Consider gating on
  `ResourceAttributes['vcs.repository.name'] != ''` or scoping the time range to
  after rollout.

Verify enough data is flowing before adding the tile:

```sql
SELECT ResourceAttributes['vcs.repository.name'] AS repo, count()
FROM otel.otel_traces
WHERE ServiceName = 'claude-code'
GROUP BY repo ORDER BY count() DESC
```
