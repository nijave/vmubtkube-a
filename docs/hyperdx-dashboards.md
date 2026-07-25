# HyperDX dashboards: MCP tools and current state

Notes on the MCP (Model Context Protocol) server ClickStack ships for dashboard
management, and whether it's usable in this cluster today.

## Current state here

- Chart version: `clickstack` **3.0.2** (`application.hyperdx.yaml` `targetRevision`).
- `hyperdx.ingress.enabled: false` — the app is `ClusterIP` only, reachable at
  `hyperdx.k8s.somemissing.info` via the hand-rolled `hyperdx-app` Service +
  `external-dns` annotation in `application.hyperdx.yaml`.
- **The MCP server is not wired up.** No Personal API Access Key has been
  generated for it (this is separate from the ingestion `HYPERDX_API_KEY` — see
  `hyperdx-api-key.md`), and no MCP client config points at `/api/mcp`.
- Dashboards today are managed manually: import JSON via the UI
  (Dashboards → ⋮ → Import Dashboard, `DashboardTemplateSchema` v0.1.0). Raw-SQL
  tiles must use native ClickHouse param placeholders
  (`{startDateMilliseconds:Int64}` / `{endDateMilliseconds:Int64}`), **not** a
  `{timeFilter}` macro — that macro doesn't exist and the literal string breaks
  ClickHouse's parser (`Code: 62. SYNTAX_ERROR`).

## MCP tools relevant to dashboards

ClickStack's built-in MCP server (`@hyperdx/api`, shipped since 2026-04-01,
still self-reports `-beta`) exposes dashboard CRUD as MCP tools. Tool names were
renamed `hyperdx_*` → `clickstack_*` on 2026-06-01 (all 19 tools, including
these):

| Tool | Purpose |
| --- | --- |
| `clickstack_list_sources` / `clickstack_describe_source` | Discover source IDs and full column schema/attribute keys before building a tile — call before authoring any query. |
| `clickstack_save_dashboard` | Create or fully replace a dashboard (whole-document write). |
| `clickstack_patch_dashboard` | Update a dashboard's name/tags and/or replace a single tile by `tileId` in one call — unmentioned tiles/fields are preserved. Cheaper than `save_dashboard` for targeted edits. |
| `clickstack_get_dashboard` / `clickstack_get_dashboard_tile` | Read a whole dashboard, or a single tile without loading the rest. |
| `clickstack_search_dashboards` | Find dashboards by name (substring, case-insensitive) and/or tags. |
| `clickstack_delete_dashboard` | Delete a dashboard. |

If wired up, this would let an AI assistant author/patch dashboards directly
instead of hand-editing and re-importing the JSON template — useful for the
targeted "change one tile's query" edits that currently require resubmitting
the whole `DashboardTemplateSchema` document.

## Caveats before adopting this here

- **Beta.** The server's own MCP handshake reports `${CODE_VERSION}-beta`.
- **The `hyperdx_*` → `clickstack_*` rename shipped as a patch version bump**
  despite being a breaking change to every tool name — any pinned client config
  or agent prompt using the old names will get `Unknown tool` errors after an
  upgrade.
- **Tile schema validation gap** (flagged in the upstream PR review, unclear if
  fixed): the MCP tile schema is a `z.union` with no discriminator, so a tile
  mixing builder fields and raw-SQL fields can silently drop the SQL-only keys
  on save.
- **`patch_dashboard` has a documented lost-update risk**: it reads a tile,
  merges layout fields, then writes the whole tile element back — a concurrent
  UI edit to the same tile in between can be silently reverted (no
  optimistic-concurrency check).
- Would additionally require: generating a Personal API Access Key in HyperDX
  Team Settings, and either enabling ingress or port-forwarding to reach
  `/api/mcp` from wherever the MCP client runs.

## Recommendation

Not adopted yet. For ad hoc log/trace querying, direct ClickHouse access
(`kubectl exec` into the `clickhouse` pod) remains simpler and more capable
than the MCP query tools for this single-tenant cluster — see the
`querying-hyperdx-clickhouse` / `exporting-traces-from-clickhouse` skills.
Revisit wiring up the MCP server specifically if programmatic dashboard
authoring/patching (not querying) becomes a recurring need.
