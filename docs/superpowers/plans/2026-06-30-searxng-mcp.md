# SearXNG MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status: COMPLETED** — all four tasks implemented and merged to main in PR #177. The deployed version differs from the YAML/code embedded below in a few ways (plain HTTP on port 80 instead of TLS, initContainer-based metrics password injection, pinned private-registry images); `searxng.yaml` and `~/.local/lib/searxng-mcp/server.py` are the source of truth. See the design spec's "Implementation deviations" section.

## Follow-up: result-quality tuning (2026-07-03)

Applied after comparing result quality against Exa:

- **Server-side** (`searxng.yaml` settings ConfigMap): raised `outgoing.request_timeout` to 5.0s with `retries: 1` (slow engines were silently dropped at the 3.0s default); enabled Mojeek and Qwant (+news variants); weighted Startpage 1.5 and Mojeek 1.2; added `hostnames` plugin config to boost github.com/stackoverflow.com and demote SEO farms.
- **Client-side** (`server.py`): `search` gained `categories` (use `news` for current events), `time_range` (day/week/month/year), and `fetch_top` (inline extracted page text for the top N results, 8,000 chars each).

## Follow-up: Brave Search API engine (2026-07-03)

Added the official Brave Search API as a `braveapi` engine (weight 1.3, $5/mo free credit ≈ 1k queries). The key is stored in Bitwarden Secrets Manager as `searxng-braveapi-key`, synced into the cluster by an ExternalSecret (`searxng-engine-keys`, ClusterSecretStore `default`), and injected into settings.yml by the existing initContainer sed step. Google Programmable Search was rejected as a second API engine — Google removed whole-web search for new engines and is shutting down the Custom Search JSON API on 2027-01-01.

**Goal:** Deploy SearXNG on local k8s and expose it as a Claude Code MCP tool so web search works when Z.ai's search quota is exhausted.

**Architecture:** SearXNG runs in the `default` k8s namespace behind an OpenResty sidecar that terminates TLS and enforces a bearer token. A Python stdio MCP server on the host calls `https://searxng.k8s.somemissing.info` with the token from keyring and exposes `search` and `fetch` tools to Claude Code.

**Tech Stack:** Kubernetes (Calico routable ClusterIP, cert-manager, external-dns RFC2136, mittwald secret-generator), OpenResty (nginx + Lua), SearXNG, Python 3.12, `mcp`, `niquests`, `html2text`, `keyring`.

## Global Constraints

- Namespace: `default` (all app resources)
- Hostname: `searxng.k8s.somemissing.info`
- TLS issuer: `cert-manager-webhook-dnsimple-production` (ClusterIssuer)
- DNS: external-dns RFC2136, auto-creates records for annotated ClusterIP Services (`--publish-internal-services` is set)
- Secret generation: mittwald `secret-generator.v1.mittwald.de/*` annotations — see `mumble.yaml` for reference pattern
- Python: `/home/nick/.pyenv/versions/3.12.3/bin/python3` — use this interpreter in MCP config
- MCP server path: `/home/nick/.local/lib/searxng-mcp/server.py`
- `niquests` (v3.13.0) is already installed; prefer it over `httpx`
- Do NOT send the bearer token to arbitrary URLs in the `fetch` tool — use a plain session for fetching

---

## Task 1: Deploy SearXNG to Kubernetes

**Files:**
- Create: `searxng.yaml` (repo root, alongside `selfoss.yaml`)

**Interfaces:**
- Produces: `https://searxng.k8s.somemissing.info` — returns 401 without token, 200 with valid `Authorization: Bearer <token>` header

- [ ] **Step 1: Write searxng.yaml**

Create `/home/nick/Documents/workspace/infra/k8s-manifests/vmubtkube-a/searxng.yaml` with the following content:

```yaml
---
# Bearer token — mittwald auto-fills data.token with a 64-char hex string.
# With ServerSideApply the controller owns `data`, so ArgoCD self-heal won't clobber it.
apiVersion: v1
kind: Secret
metadata:
  name: searxng-bearer-token
  namespace: default
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: token
    secret-generator.v1.mittwald.de/encoding: hex
    secret-generator.v1.mittwald.de/length: "64"
type: Opaque
---
# Metrics password — used as HTTP Basic Auth password for /metrics endpoint.
# Also referenced by the ServiceMonitor's basicAuth config.
apiVersion: v1
kind: Secret
metadata:
  name: searxng-metrics-password
  namespace: default
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: password
    secret-generator.v1.mittwald.de/encoding: hex
    secret-generator.v1.mittwald.de/length: "32"
type: Opaque
---
# SearXNG settings — secret_key is non-sensitive here (JSON API only, no web sessions).
# Google and Bing disabled to avoid CAPTCHA risk on home IP.
apiVersion: v1
kind: ConfigMap
metadata:
  name: searxng-settings
  namespace: default
data:
  settings.yml: |
    use_default_settings: true

    general:
      debug: false
      instance_name: "searxng-private"
      enable_metrics: true
      open_metrics: "${SEARXNG_OPEN_METRICS}"

    server:
      limiter: false
      image_proxy: false
      secret_key: "j9k2m4n8p3q7r1s5t0u6v2w8x4y9z3a7b1c5d0e4f8g2h6"

    search:
      formats:
        - json

    engines:
      - name: google
        disabled: true
      - name: google images
        disabled: true
      - name: google news
        disabled: true
      - name: google videos
        disabled: true
      - name: google scholar
        disabled: true
      - name: google play apps
        disabled: true
      - name: google play movies
        disabled: true
      - name: bing
        disabled: true
      - name: bing images
        disabled: true
      - name: bing news
        disabled: true
      - name: bing videos
        disabled: true
---
# OpenResty config — TLS termination + Lua bearer token check.
# `env BEARER_TOKEN` must be in the main context so Lua's os.getenv() can read it.
apiVersion: v1
kind: ConfigMap
metadata:
  name: searxng-nginx-config
  namespace: default
data:
  nginx.conf: |
    env BEARER_TOKEN;

    events {
        worker_connections 1024;
    }

    http {
        server {
            listen 443 ssl;
            server_name searxng.k8s.somemissing.info;

            ssl_certificate /etc/ssl/certs/tls.crt;
            ssl_certificate_key /etc/ssl/certs/tls.key;
            ssl_protocols TLSv1.2 TLSv1.3;
            ssl_prefer_server_ciphers on;

            location / {
                access_by_lua_block {
                    local auth = ngx.req.get_headers()["Authorization"]
                    if not auth then
                        ngx.status = ngx.HTTP_UNAUTHORIZED
                        ngx.header.content_type = "application/json"
                        ngx.say('{"error":"missing Authorization header"}')
                        return ngx.exit(ngx.HTTP_UNAUTHORIZED)
                    end
                    local token = auth:match("^Bearer (.+)$")
                    if not token or token ~= os.getenv("BEARER_TOKEN") then
                        ngx.status = ngx.HTTP_UNAUTHORIZED
                        ngx.header.content_type = "application/json"
                        ngx.say('{"error":"invalid token"}')
                        return ngx.exit(ngx.HTTP_UNAUTHORIZED)
                    end
                }

                proxy_pass http://localhost:8080;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_read_timeout 30s;
            }
        }
    }
---
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
  commonName: &cn searxng.k8s.somemissing.info
  dnsNames:
    - *cn
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: searxng
  namespace: default
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: searxng
  annotations:
    reloader.stakater.com/auto: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: searxng
      app.kubernetes.io/component: searxng
  template:
    metadata:
      labels:
        app.kubernetes.io/name: searxng
        app.kubernetes.io/component: searxng
    spec:
      containers:
        - name: openresty
          image: openresty/openresty:alpine
          ports:
            - name: https
              containerPort: 443
              protocol: TCP
          env:
            - name: BEARER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: searxng-bearer-token
                  key: token
          volumeMounts:
            - name: nginx-config
              mountPath: /usr/local/openresty/nginx/conf/nginx.conf
              subPath: nginx.conf
              readOnly: true
            - name: tls
              mountPath: /etc/ssl/certs
              readOnly: true
          readinessProbe:
            tcpSocket:
              port: 443
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              cpu: 250m
              memory: 128Mi
        - name: searxng
          image: docker.io/searxng/searxng:latest
          ports:
            - name: metrics
              containerPort: 8080
              protocol: TCP
          env:
            - name: SEARXNG_OPEN_METRICS
              valueFrom:
                secretKeyRef:
                  name: searxng-metrics-password
                  key: password
          volumeMounts:
            - name: searxng-settings
              mountPath: /etc/searxng/settings.yml
              subPath: settings.yml
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: nginx-config
          configMap:
            name: searxng-nginx-config
        - name: tls
          secret:
            secretName: searxng-k8s-somemissing-info-tls
        - name: searxng-settings
          configMap:
            name: searxng-settings
---
apiVersion: v1
kind: Service
metadata:
  name: searxng
  namespace: default
  labels:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: searxng
  annotations:
    # external-dns creates the A record for searxng.k8s.somemissing.info → ClusterIP
    external-dns.alpha.kubernetes.io/hostname: searxng.k8s.somemissing.info
spec:
  type: ClusterIP
  ports:
    - name: https
      port: 443
      targetPort: 443
      protocol: TCP
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
  selector:
    app.kubernetes.io/name: searxng
    app.kubernetes.io/component: searxng
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: searxng
  namespace: default
  labels:
    release: prom
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: searxng
  endpoints:
    - port: metrics
      path: /metrics
      scheme: http
      basicAuth:
        password:
          name: searxng-metrics-password
          key: password
```

- [ ] **Step 2: Apply the manifest**

```bash
cd ~/Documents/workspace/infra/k8s-manifests/vmubtkube-a
kubectl apply -f searxng.yaml
```

Expected output: each resource shows `created` or `configured`.

- [ ] **Step 3: Wait for certificate to be issued**

```bash
kubectl wait certificate/searxng-k8s-somemissing-info-cert \
  --for=condition=Ready --timeout=120s -n default
```

Expected: `certificate.cert-manager.io/searxng-k8s-somemissing-info-cert condition met`

If it times out, check: `kubectl describe certificate searxng-k8s-somemissing-info-cert -n default`

- [ ] **Step 4: Wait for deployment to be ready**

```bash
kubectl rollout status deployment/searxng -n default --timeout=120s
```

Expected: `deployment "searxng" successfully rolled out`

If pods aren't starting, check: `kubectl logs -l app.kubernetes.io/name=searxng -n default --all-containers`

- [ ] **Step 5: Verify bearer auth works**

```bash
CLUSTER_IP=$(kubectl get svc searxng -n default -o jsonpath='{.spec.clusterIP}')
TOKEN=$(kubectl get secret searxng-bearer-token -n default -o jsonpath='{.data.token}' | base64 -d)

# Should return 401
curl -sk --resolve "searxng.k8s.somemissing.info:443:${CLUSTER_IP}" \
  https://searxng.k8s.somemissing.info/ -o /dev/null -w "Status (no token): %{http_code}\n"

# Should return 200
curl -sk --resolve "searxng.k8s.somemissing.info:443:${CLUSTER_IP}" \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://searxng.k8s.somemissing.info/search?q=test&format=json" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Results: {len(d[\"results\"])}')"
```

Expected:
```
Status (no token): 401
Results: 10
```

- [ ] **Step 6: Verify Prometheus metrics endpoint**

```bash
CLUSTER_IP=$(kubectl get svc searxng -n default -o jsonpath='{.spec.clusterIP}')
METRICS_PASS=$(kubectl get secret searxng-metrics-password -n default -o jsonpath='{.data.password}' | base64 -d)

# Should return OpenMetrics text output (after running at least one search)
curl -s --resolve "searxng.k8s.somemissing.info:8080:${CLUSTER_IP}" \
  -u "prometheus:${METRICS_PASS}" \
  "http://searxng.k8s.somemissing.info:8080/metrics" | head -20
```

Expected: Lines starting with `# HELP searxng_engines_` and `# TYPE searxng_engines_`.

Verify the ServiceMonitor is picked up by Prometheus:

```bash
kubectl get servicemonitor searxng -n default
```

Expected: resource exists and shows the `searxng` ServiceMonitor.

- [ ] **Step 7: Commit**

```bash
cd ~/Documents/workspace/infra/k8s-manifests/vmubtkube-a
git add searxng.yaml
git commit -m "feat: deploy SearXNG with OpenResty auth sidecar and Prometheus metrics"
```

---

## Task 2: Store Bearer Token in Keyring

**Interfaces:**
- Consumes: `searxng-bearer-token` Secret from Task 1
- Produces: `keyring.get_password("searxng", "bearer-token")` returns the token string

- [ ] **Step 1: Read token from cluster and store in keyring**

```bash
TOKEN=$(kubectl get secret searxng-bearer-token -n default \
  -o jsonpath='{.data.token}' | base64 -d)
keyring set searxng bearer-token "$TOKEN"
```

- [ ] **Step 2: Verify keyring roundtrip**

```bash
python3 -c "import keyring; t = keyring.get_password('searxng', 'bearer-token'); print('OK, length:', len(t)) if t else print('FAIL: token not found')"
```

Expected: `OK, length: 64`

---

## Task 3: Create Python MCP Server

**Files:**
- Create: `/home/nick/.local/lib/searxng-mcp/server.py`

**Interfaces:**
- Consumes: `keyring.get_password("searxng", "bearer-token")` from Task 2
- Produces: stdio MCP server exposing tools `search(query, max_results)` and `fetch(url)`

- [ ] **Step 1: Install missing dependencies**

```bash
/home/nick/.pyenv/versions/3.12.3/bin/pip install mcp html2text
```

Expected: both packages install without error. `niquests` and `keyring` are already present.

- [ ] **Step 2: Create the server directory and file**

```bash
mkdir -p /home/nick/.local/lib/searxng-mcp
```

Create `/home/nick/.local/lib/searxng-mcp/server.py`:

```python
#!/usr/bin/env python3
"""SearXNG MCP server — exposes search and fetch tools to Claude Code."""

import keyring
import html2text
import niquests
from mcp.server.fastmcp import FastMCP

SEARXNG_URL = "https://searxng.k8s.somemissing.info"
FETCH_MAX_CHARS = 50_000

mcp = FastMCP("searxng")


def _token() -> str:
    t = keyring.get_password("searxng", "bearer-token")
    if not t:
        raise RuntimeError(
            "Bearer token not found in keyring. "
            "Run: keyring set searxng bearer-token <token>"
        )
    return t


@mcp.tool()
def search(query: str, max_results: int = 10) -> list[dict]:
    """Search the web via SearXNG. Returns title, url, content snippet, and engine per result."""
    try:
        with niquests.Session() as s:
            s.headers["Authorization"] = f"Bearer {_token()}"
            r = s.get(
                f"{SEARXNG_URL}/search",
                params={"q": query, "format": "json"},
                timeout=15,
            )
        if r.status_code == 401:
            return [{"error": "Authentication failed — check bearer token in keyring"}]
        r.raise_for_status()
        results = [
            {
                "title": item.get("title", ""),
                "url": item.get("url", ""),
                "content": item.get("content", ""),
                "engine": item.get("engine", ""),
            }
            for item in r.json().get("results", [])
            if item.get("content")
        ]
        return results[:max_results]
    except (niquests.ConnectionError, niquests.Timeout):
        return [{"error": f"Could not reach {SEARXNG_URL} — is the cluster up?"}]
    except Exception as e:
        return [{"error": str(e)}]


@mcp.tool()
def fetch(url: str) -> str:
    """Fetch a URL and return its content as readable plain text (max 50 000 chars)."""
    try:
        with niquests.Session() as s:
            r = s.get(url, timeout=15)
        r.raise_for_status()
        content_type = r.headers.get("content-type", "")
        if "text/html" in content_type or not content_type:
            h = html2text.HTML2Text()
            h.ignore_links = False
            h.body_width = 0
            text = h.handle(r.text)
        else:
            text = r.text
        return text[:FETCH_MAX_CHARS]
    except (niquests.ConnectionError, niquests.Timeout):
        return f"Error: could not connect to {url}"
    except niquests.HTTPError:
        return f"Error: HTTP {r.status_code} from {url}"
    except Exception as e:
        return f"Error: {e}"


if __name__ == "__main__":
    mcp.run()
```

- [ ] **Step 3: Smoke-test search tool**

```bash
python3 -c "
import sys
sys.argv = ['server']
import keyring, niquests
token = keyring.get_password('searxng', 'bearer-token')
with niquests.Session() as s:
    s.headers['Authorization'] = f'Bearer {token}'
    r = s.get('https://searxng.k8s.somemissing.info/search', params={'q': 'python mcp server', 'format': 'json'}, timeout=15)
r.raise_for_status()
results = r.json().get('results', [])
print(f'Search OK — {len(results)} results')
print(f'First: {results[0][\"title\"][:80]}')
"
```

Expected:
```
Search OK — 10 results
First: <some title>
```

- [ ] **Step 4: Smoke-test fetch tool**

```bash
python3 -c "
import niquests, html2text
r = niquests.get('https://example.com', timeout=15)
h = html2text.HTML2Text()
h.body_width = 0
text = h.handle(r.text)
print(text[:300])
"
```

Expected: readable plain text output from example.com.

---

## Task 4: Wire into Claude Code and Verify End-to-End

**Files:**
- Modify: `/home/nick/.claude/settings.json` — add `mcpServers` block
- Modify: `/home/nick/.claude/settings.local.json` — add tool permissions

**Interfaces:**
- Consumes: `server.py` from Task 3
- Produces: `search` and `fetch` tools visible in Claude Code without permission prompts

- [ ] **Step 1: Add MCP server to settings.json**

Read `/home/nick/.claude/settings.json`, then add the `mcpServers` key. The complete addition (merge into existing JSON, do not replace other keys):

```json
"mcpServers": {
  "searxng": {
    "command": "/home/nick/.pyenv/versions/3.12.3/bin/python3",
    "args": ["/home/nick/.local/lib/searxng-mcp/server.py"]
  }
}
```

- [ ] **Step 2: Add tool permissions to settings.local.json**

Read `/home/nick/.claude/settings.local.json`, then add to the `permissions.allow` array:

```json
"mcp__searxng__search",
"mcp__searxng__fetch"
```

- [ ] **Step 3: Reload Claude Code**

Exit the current Claude Code session and relaunch with `zclaude` (or whichever launcher is in use). The MCP server spawns automatically at startup.

- [ ] **Step 4: Verify tools appear**

Run `/mcp` in Claude Code.

Expected: `searxng` listed as a connected MCP server with `search` and `fetch` tools shown.

If the server shows as failed, check: `~/.claude/` logs or run the server manually:

```bash
/home/nick/.pyenv/versions/3.12.3/bin/python3 /home/nick/.local/lib/searxng-mcp/server.py
```

It should start without error and wait on stdin.

- [ ] **Step 5: End-to-end search test**

In Claude Code, ask Claude to use the search tool:

> "Use the searxng search tool to search for 'SearXNG JSON API' and show me the first 3 results."

Expected: Claude calls `mcp__searxng__search`, returns 3 results with title, URL, and snippet.

- [ ] **Step 6: End-to-end fetch test**

> "Use the searxng fetch tool to fetch https://example.com and show me the page content."

Expected: Claude calls `mcp__searxng__fetch`, returns the plain-text content of example.com.

- [ ] **Step 7: Commit settings changes**

The Claude Code settings files are user-local (not in the infra repo). No commit needed.

Commit the plan doc alongside the spec:

```bash
cd ~/Documents/workspace/infra/k8s-manifests/vmubtkube-a
git add docs/superpowers/plans/2026-06-30-searxng-mcp.md
git commit -m "docs: add SearXNG MCP implementation plan"
```
