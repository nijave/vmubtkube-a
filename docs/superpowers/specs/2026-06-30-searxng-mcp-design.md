# SearXNG MCP Server Design

**Date:** 2026-06-30  
**Status:** Approved

## Problem

Z.ai's GLM Coding Plan includes a monthly web search/reader/zread quota that exhausts independently of the 5-hour prompt quota. When it is exhausted, Claude Code has no fallback search capability. The goal is a client-side search tool that works when the Z.ai quota is gone, requires no external API signup, respects search engine ToS, and does not risk the home IP being blocked.

## Architecture

```
Claude Code (host)
  └─ spawns MCP server process (stdio, Python)
       └─ HTTPS + Bearer token → nginx sidecar :443
                                    └─ localhost → SearXNG :8888
                                                     └─ fan-out (DDG, Brave, Wikipedia, Startpage)
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

SearXNG configured with safe engines only. Google disabled to avoid CAPTCHA risk on home IP. Enabled engines:

- DuckDuckGo
- Brave Search
- Wikipedia
- Startpage

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
**Dependencies:** `mcp`, `httpx`, `html2text`, `keyring`

### Tools exposed

**`search(query: str, num_results: int = 10) -> list`**

Calls `https://searxng.k8s.somemissing.info/search?q=<query>&format=json&num_results=<n>`. Returns a list of results, each with `title`, `url`, `content` (snippet), and `engine`. Strips any results with empty snippets.

**`fetch(url: str) -> str`**

Fetches the given URL and returns readable plain text via `html2text`. Caps output at 50,000 characters to avoid flooding context. Follows redirects. Uses a 15-second timeout.

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
