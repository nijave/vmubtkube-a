# SearXNG MCP Server Design

**Date:** 2026-06-30  
**Status:** Implemented (merged in PR #177; result-quality tuning added 2026-07-03)

## Implementation deviations from original design

- ~~The sidecar serves plain HTTP on port 80 (no TLS/cert-manager)~~ Resolved 2026-07-03: with `*.k8s.somemissing.info` cert issuance fixed (PR #186), the sidecar now terminates TLS on 443 with a cert-manager Certificate as originally designed, and `SEARXNG_URL` is `https://`. Traffic stays on the LAN via routable ClusterIP.
- The metrics password is injected by an initContainer that `sed`-replaces a placeholder in the settings template (SearXNG does not expand env vars in `settings.yml`).
- Images are pulled through `registry.apps.nickv.me` rather than Docker Hub, and the SearXNG image is pinned (Renovate-managed) rather than `latest`.
- `secret_key` comes from a mittwald-generated Secret via the `SEARXNG_SECRET` env var.

## Problem

Z.ai's GLM Coding Plan includes a monthly web search/reader/zread quota that exhausts independently of the 5-hour prompt quota. When it is exhausted, Claude Code has no fallback search capability. The goal is a client-side search tool that works when the Z.ai quota is gone, requires no external API signup, respects search engine ToS, and does not risk the home IP being blocked.

## Architecture

```
Claude Code (host)
  └─ spawns MCP server process (stdio, Python)
       └─ HTTPS + Bearer token → nginx sidecar :443
                                    └─ localhost → SearXNG :8888
                                                     └─ fan-out (Brave API, Marginalia, Startpage, DDG, Brave, Mojeek, Qwant, Wikipedia, …)
```

Three components: a k8s deployment of SearXNG with an auth sidecar, a Python MCP server process, and Claude Code configuration wiring them together.

## Component 1: Kubernetes Manifests

**File:** `k8s-manifests/vmubtkube-a/searxng.yaml`  
**Namespace:** `default` (consistent with other apps)  
**Hostname:** `searxng.k8s.somemissing.info`

### Secrets (mittwald secret-generator)

Two auto-generated secrets via mittwald annotation:
- `searxng-secret-key` — SearXNG internal Flask session signing key (`secret_key` in `settings.yml`)
- `searxng-bearer-token` — static bearer token checked by nginx sidecar; used by MCP server to authenticate

### ConfigMap: SearXNG settings.yml

SearXNG configured with safe engines only. Google and Bing disabled to avoid CAPTCHA risk on home IP. Enabled engines:

- DuckDuckGo (proxies Bing's index)
- Startpage (proxies Google's index; weight 1.5 — best-quality results without scraping Google directly)
- Brave Search
- Brave Search API (`braveapi`, weight 1.3) — official API, independent index; key lives in Bitwarden Secrets Manager as `searxng-braveapi-key`, synced by an ExternalSecret into `searxng-engine-keys` and injected into settings.yml by the initContainer (added 2026-07-03). $5/mo free credit ≈ 1k queries.
- Mojeek (weight 1.2) and Qwant — independent indexes, scraping-tolerant (enabled 2026-07-03)
- Marginalia — independent index of non-commercial/text-heavy web, complements SEO-buried technical content; free non-commercial API key by emailing contact@marginalia-search.com per https://about.marginalia-search.com/article/api/, stored in Bitwarden Secrets Manager as `searxng-marginalia-key` (added 2026-07-03)
- Wikipedia, GitHub, StackOverflow, MDN (SearXNG defaults)

Google Programmable Search was evaluated as a second API engine and rejected: Google removed "Search the entire web" for new engines (Jan 2026) and is discontinuing the Custom Search JSON API on 2027-01-01.

Result-quality tuning (2026-07-03):

- `outgoing.request_timeout: 5.0` (default 3.0 silently dropped slow engines from responses), `max_request_timeout: 10.0`, `retries: 1`
- `hostnames` plugin config: boosts `github.com`/`stackoverflow.com`, demotes SEO farms (Pinterest, Quora, Softonic)

Conservative rate limiting. JSON API enabled. Web UI disabled (not needed, reduces attack surface). `secret_key` injected from Secret via env var.

### ConfigMap: nginx config

nginx sidecar configuration:
- Listens on port 443 (TLS)
- Terminates TLS using cert-manager-issued certificate
- Checks `Authorization: Bearer <token>` header; returns 401 if missing or wrong
- Proxies valid requests to `localhost:8888` (SearXNG)

### Certificate

```
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: searxng-k8s-somemissing-info-cert
  namespace: default
spec:
  secretName: searxng-k8s-somemissing-info-tls
  issuerRef:
    name: cert-manager-webhook-dnsimple-production
    kind: ClusterIssuer
  commonName: searxng.k8s.somemissing.info
  dnsNames:
    - searxng.k8s.somemissing.info
```

### Deployment

Single Deployment, two containers:

**nginx sidecar (OpenResty)**
- Image: `openresty/openresty:alpine` — drop-in nginx superset with Lua module for bearer token checking (`nginx:alpine` lacks native bearer auth support)
- Port 443
- Mounts: nginx ConfigMap, TLS certificate Secret
- Resources: small (10m CPU, 64Mi memory requests)

**searxng**
- Image: `docker.io/searxng/searxng:latest`
- Port 8888 (localhost only, not exposed on pod network)
- Mounts: settings.yml ConfigMap, secret_key Secret (env var)
- Resources: 50m CPU / 256Mi memory requests, 500m CPU / 512Mi limits
- No PVC — fully stateless, no persistence needed

### Service

ClusterIP on port 443, selector targets the Deployment. Routable from LAN/host via Calico.

## Component 2: MCP Server

**File:** `~/.local/lib/searxng-mcp/server.py`  
**Language:** Python  
**Transport:** stdio (spawned by Claude Code as a child process)  
**Dependencies:** `mcp`, `niquests`, `html2text`, `keyring`, `trafilatura`

### Tools exposed

**`search(query: str, max_results: int = 10, categories: str = "", time_range: str = "", fetch_top: int = 3) -> list`**

Calls `/search?q=<query>&format=json`, forwarding `categories` (general/news/it/images/videos/science/files/q&a) and `time_range` (day/week/month/year) when given — `categories=news` turns current-events queries from homepage links into dated articles. Returns a list of results, each with `title`, `url`, `content` (snippet), and `engine`. Strips any results with empty snippets. The top `fetch_top` pages (default 3) are fetched in parallel, body-extracted with trafilatura, and their most query-relevant passages returned as `highlights` (≤2,000 chars each) — mimicking Exa's search-with-contents in a single call. Docstring steers callers to keyword-style queries. (`categories`/`time_range` added 2026-07-03; highlights rework same day.)

**`fetch(url: str) -> str`**

Fetches the given URL and returns its main content as readable plain text — extracted with `trafilatura`, falling back to `html2text` for pages it can't parse. Caps output at 50,000 characters to avoid flooding context. Follows redirects. Uses a 15-second timeout.

### Auth

Bearer token read from system keyring (`keyring get searxng bearer-token`) once at startup. Passed as `Authorization: Bearer <token>` on every request. TLS verified against system CA (Let's Encrypt is publicly trusted, no custom CA needed).

### Error handling

- SearXNG unreachable (cluster down): returns a clear error string rather than crashing the MCP process
- 401 from nginx (token mismatch): surfaces as a clear auth error
- Fetch timeout or non-200: returns error string with status code

## Component 3: Claude Code Wiring

### ~/.claude/settings.json addition

```json
"mcpServers": {
  "searxng": {
    "command": "python",
    "args": ["/home/nick/.local/lib/searxng-mcp/server.py"]
  }
}
```

### ~/.claude/settings.local.json addition

```json
"mcp__searxng__search",
"mcp__searxng__fetch"
```

Added to the `permissions.allow` array so both tools run without a prompt.

## Bearer Token Setup (one-time)

After deployment, store the bearer token in keyring:

```bash
# Read generated token from cluster
TOKEN=$(kubectl get secret searxng-bearer-token -n default -o jsonpath='{.data.value}' | base64 -d)
keyring set searxng bearer-token "$TOKEN"
```

## Metrics / Monitoring

SearXNG has a built-in OpenMetrics endpoint at `/metrics`, gated by `general.open_metrics` in `settings.yml`. When set to a non-empty string, that string becomes the HTTP Basic Auth password for the endpoint (username is ignored by SearXNG).

### Enabling the endpoint

A mittwald-generated Secret (`searxng-metrics-password`) provides a random password. It is injected into the SearXNG container as `SEARXNG_OPEN_METRICS` and referenced in `settings.yml` via env var substitution:

```yaml
general:
  enable_metrics: true
  open_metrics: "${SEARXNG_OPEN_METRICS}"
```

### Scrape path

The `/metrics` endpoint is served by SearXNG on port 8080. The OpenResty sidecar does **not** need to proxy this — Prometheus scrapes port 8080 directly inside the cluster with basic auth. A second Service port (`metrics`, 8080) is exposed for this purpose.

### ServiceMonitor

A `ServiceMonitor` (label `release: prom`) selects on `app.kubernetes.io/name: searxng` and scrapes the `metrics` port with `basicAuth` referencing the `searxng-metrics-password` Secret. This follows the same pattern as other ServiceMonitors in the cluster (e.g. `thanos-receive-ingestor`, `snmp-exporter`, `arr`).

### Metrics exposed

All per-engine, labeled by `engine_name`:

| Metric | Type | Description |
|--------|------|-------------|
| `searxng_engines_response_time_total_seconds` | gauge | Average total response time |
| `searxng_engines_response_time_processing_seconds` | gauge | Average processing time |
| `searxng_engines_response_time_http_seconds` | gauge | Average HTTP response time |
| `searxng_engines_result_count_total` | counter | Total results returned |
| `searxng_engines_request_count_total` | counter | Total user requests |
| `searxng_engines_reliability_total` | counter | Overall engine reliability |

## Out of Scope

- Redis result caching (stateless is sufficient for this use case)
- Contour HTTPProxy / WAN exposure (LAN + ClusterIP is the access model)
- Web UI for SearXNG (JSON API only)
- Multiple SearXNG replicas (single replica is fine for personal use)
