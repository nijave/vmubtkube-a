# Claude Code telemetry: project / workspace attribution

Context and status for attributing Claude Code OpenTelemetry (traces, metrics,
events) to a **project / repository / working directory**. Related to the
[`claude-code model metrics`](./dashboards/claude-code-model-metrics.md)
dashboard, whose per-model table can only slice by user, org, session,
workflow, terminal, and model today.

## The problem

Claude Code emits spans under `ServiceName = claude-code` (scope
`com.anthropic.claude_code.tracing`) with span types `interaction`,
`llm_request`, `tool`, `tool.execution`, `tool.blocked_on_user`. None of the
span attributes nor the `ResourceAttributes` identify which project/repo the
session ran in — `ResourceAttributes` carries only `host.arch`, `os.type`,
`os.version`, `service.name`, `service.version`.

There is **no native project attribute** and **no per-span attribute hook**.
Span-level attributes are hardcoded in the CLI's `LogRecordProcessor.onEmit()`.
The only supported extension point is `OTEL_RESOURCE_ATTRIBUTES`
(comma-separated `key=value`), which is applied as **resource attributes** to
every span, metric, and event.

Formatting rules (W3C baggage): no spaces, commas, semicolons, double quotes,
backslashes, or control chars in values; percent-encode anything else (Claude
Code decodes `%XX` on ingest).

## Our solution: shell wrapper

`~/.bashrc` (real path `workstation/dotfiles/.bashrc`) defines a `claude()`
wrapper that sets `OTEL_RESOURCE_ATTRIBUTES` from git + cwd before exec'ing the
real binary. Attributes are computed in exactly one place,
`_claude_otel_resource_attrs()` (with `_otel_enc()` for percent-encoding), and
`zclaude()` (z.ai backend) calls `claude`, so it flows through the same wrapper.

Emitted keys (frozen at launch — see caveats):

| Key | Source |
| --- | --- |
| `process.working_directory` | `$PWD` |
| `vcs.repository.name` | basename of `git rev-parse --show-toplevel` |
| `vcs.ref.head.name` | `git branch --show-current` |
| `vcs.ref.head.revision` | `git rev-parse --short HEAD` |
| `vcs.repository.url.full` | `git config --get remote.origin.url` |

Any pre-existing `OTEL_RESOURCE_ATTRIBUTES` is preserved and our keys appended.
Key names follow OTel VCS semantic conventions.

### Caveats

- **Static per session.** Resource attributes are captured at launch and do
  **not** update if you `cd` or switch branch mid-session (per the OTel spec,
  resources are immutable). This is the fundamental limitation of the
  resource-attribute approach; a dynamic per-record approach was requested in
  #31300 but not adopted.
- **Subprocess launchers bypass it.** Anything that spawns `claude` without a
  login shell (Conductor, Zed/ACP, JetBrains, cron) won't pick up the wrapper;
  set the env in that launcher, or in `~/.claude/settings.json` /
  `managed-settings.json` for a static value.
- **Metrics propagation historically buggy.** Resource attributes reliably
  reach events/spans; reaching metric datapoints has been flaky (#16537).

### Verifying

New sessions land the keys in ClickHouse `otel.otel_traces.ResourceAttributes`:

```sql
SELECT ResourceAttributes['vcs.repository.name'] AS repo, count()
FROM otel.otel_traces
WHERE ServiceName = 'claude-code' AND ResourceAttributes['vcs.repository.name'] != ''
GROUP BY repo ORDER BY count() DESC
```

Once data is flowing, a `repo` dimension/filter can be added to the dashboard
tiles. Only sessions started after the wrapper was in place carry the keys;
historical spans have none.

## Upstream issue tracking

All chased through their duplicate/closed/merged links. As of 2026-07-22 the
**only open issue** in the project-attribution / telemetry-attribute space is
**#42281** (native trace export, which our data shows already works in beta via
`CLAUDE_CODE_ENHANCED_TELEMETRY_BETA=1`). Every request for a native project /
repo / directory attribute has been closed (deduped → stale → not planned).

| Issue | Ask | Status | Resolution / chain |
| --- | --- | --- | --- |
| [#42281](https://github.com/anthropics/claude-code/issues/42281) | Native OTLP trace/span export | **OPEN** (👍12) | Only open one; our cluster already gets traces via the beta flag |
| [#29826](https://github.com/anthropics/claude-code/issues/29826) | Opt-in `OTEL_LOG_REPO_DETAILS` — send git org/repo | Closed | Stale; canonical target of the project-attr dupes. Workaround = this wrapper |
| [#31300](https://github.com/anthropics/claude-code/issues/31300) | Dynamic git branch/cwd/PR on **log records** (updates mid-session) | Closed | Duplicate → #29826 |
| [#31587](https://github.com/anthropics/claude-code/issues/31587) | `project`/`repository` label on metrics + logs | Closed | Duplicate → #31300 |
| [#36173](https://github.com/anthropics/claude-code/issues/36173) | Custom session title as resource attr (`session.name`) | Closed | Not planned; stale |
| [#27346](https://github.com/anthropics/claude-code/issues/27346) | Agent/subagent identity fields on team-spawn telemetry | Closed | Stale |
| [#52222](https://github.com/anthropics/claude-code/issues/52222) | `triggering_llm_request_id` on tool spans for cost attribution | Closed | Stale |
| [#35953](https://github.com/anthropics/claude-code/issues/35953) | Expose `tool_use_id` / W3C baggage as env in Bash tool | Closed | Not planned; stale |
| [#17188](https://github.com/anthropics/claude-code/issues/17188) | Expose session metadata (`CLAUDE_SESSION_ID`/name) to hooks | Closed | **Completed** (May 2026) — session, not project |
| [#16537](https://github.com/anthropics/claude-code/issues/16537) | `OTEL_RESOURCE_ATTRIBUTES` not applied to metrics | Closed | Completed |
| [#18259](https://github.com/anthropics/claude-code/issues/18259) | CLI crashes on `OTEL_*_EXPORTER=none` | Closed | Completed (fixed) |
| [#53954](https://github.com/anthropics/claude-code/issues/53954) | Streaming/SDK path only emits `llm_request` spans | Closed | Not planned; stale |
| [#10974](https://github.com/anthropics/claude-code/issues/10974) | Custom `OTEL_RESOURCE_ATTRIBUTES` not flowing | Closed | Auto-closed |
| [#4338](https://github.com/anthropics/claude-code/issues/4338) | `OTEL_RESOURCE_ATTRIBUTES` not applied to logs | Closed | Resolved (formatting/spaces user error) |

**Takeaway:** native project attribution is not coming soon; the shell wrapper
is the durable path. Watch #42281 for trace-export graduation out of beta.
