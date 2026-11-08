# coding-agent usage insights (HyperDX dashboard)

Export and notes for the **`coding-agent usage insights`** dashboard in the
HyperDX/ClickStack instance in the `hyperdx` namespace. It covers cost, turns,
tools, prompt caching, reasoning, subagents, and repositories. Model latency
and token trends live on the sibling dashboards
[`coding-agent model metrics`](./coding-agent-model-metrics.md),
[`coding-agent model trends`](./coding-agent-model-trends.md), and
[`coding-agent agent token trends`](./coding-agent-agent-token-trends.md).

- **Live location:** MongoDB `hyperdx` database, `dashboards` collection.
- **Dashboard `_id`:** `6aefc65df403d377a532a03c`
- **Export snapshot:**
  [`coding-agent-usage-insights.json`](./coding-agent-usage-insights.json)
- **Data source:** canonical spans from the
  [otel-agent-trace-connector](../../otel-agent-trace-connector.yaml)
  (`ResourceAttributes['telemetry.source'] = 'coding-agent'`), plus two raw
  sources where the canonical spans lack the data. See the source notes below.
- **Filters:** none. The cost and subagent tiles use `UNION ALL` across
  tables, so one `$__filter` expression does not fit every tile.

## Tiles

| id | type | what it shows | source |
| --- | --- | --- | --- |
| `kpi-cost` | number | reported cost $ | pi chat spans + Claude Code `api_request` logs |
| `kpi-turns` | number | `invoke_agent` spans | canonical |
| `kpi-tools` | number | `execute_tool` spans | canonical |
| `kpi-tool-err` | number | tool error % | canonical (pi, codex only) |
| `kpi-cache-hit` | number | prompt cache hit % | canonical |
| `kpi-llm-err` | number | failed LLM requests | canonical |
| `ln-cost-day` | line | daily cost per agent | as `kpi-cost` |
| `tbl-cost-model` | table | cost and $/request per agent × model | as `kpi-cost` |
| `tbl-turns` | table | turns, conversations, turn p50/p95, LLM calls and tools per turn | canonical, grouped by `TraceId` |
| `tbl-tools` | table | top 50 tools: calls, error %, p50/p95, total time | canonical |
| `tbl-errors` | table | failed LLM requests by model, provider, `StatusMessage` | canonical |
| `ln-cache-hit` | line | hourly cache hit % per agent | canonical |
| `tbl-cache` | table | prompt, cache-read, cache-write tokens and ratios per model | canonical |
| `tbl-reasoning` | table | requests, output and reasoning tokens per model × reasoning level | canonical |
| `tbl-delegation` | table | main agent vs subagent requests and tokens | canonical + raw pi spans |
| `tbl-repo` | table | Claude Code requests, sessions, tokens, cost per repository | Claude Code `api_request` logs |

## Source notes

- **Cost.** Only two harnesses report cost. pi sets
  `coding_agent.usage.cost` on canonical chat spans. Claude Code reports
  `cost_usd` only on its `api_request` log events in `otel.otel_logs`. Codex
  reports no cost and does not appear in the cost tiles.
- **Prompt tokens and cache hit %.** Codex follows OpenAI usage:
  `gen_ai.usage.input_tokens` already includes cached tokens. claude_code
  and pi report input, cache read, and cache write separately. The tiles
  use `input` for codex and `input + cache_read + cache_write` for
  the others. Hit % is `cache_read / prompt`.
- **Tool errors.** pi and codex set `StatusCode = 'Error'` on failed
  `execute_tool` spans. The connector does not carry Claude Code's
  `success = false` from `claude_code.tool.execution` onto the canonical
  span, so claude_code tools show 0% errors. Fix this in the connector, not
  here.
- **Turns.** A turn is one canonical trace with an `invoke_agent` root. pi
  and codex chat or tool spans stay in the trace of their parent turn.
- **Reasoning.** codex and pi report
  `gen_ai.usage.reasoning.output_tokens`. claude_code reports the effort
  level but not reasoning tokens, so its reasoning columns are 0.
- **Subagents.** claude_code marks subagent requests with
  `gen_ai.agent.id` on the canonical chat span. pi's canonical spans have no
  such marker. The tile joins each canonical pi chat span to its raw
  pi-telemetry `llm-generation [main]` / `[subagent]` span on
  `gen_ai.response.id` = `responseId`. pi-delegate child runs started from a
  pi session appear as `[subagent]`.
- **Repository.** Only Claude Code reports `vcs.repository.name`. `(none)`
  means a session started outside a git repository.

## Applying / re-exporting

Same procedure as the sibling dashboards: see
[`coding-agent-model-trends.md`](./coding-agent-model-trends.md#applying--re-exporting),
including the BSON-type gotcha on insert.
