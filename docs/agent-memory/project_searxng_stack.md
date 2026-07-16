---
name: searxng-stack
description: "SearXNG search stack layout — braveapi key via ExternalSecret, initContainer placeholder injection, MCP server on host"
metadata: 
  node_type: memory
  type: project
  originSessionId: 023f987f-5023-46b9-b392-bd99464fe25b
---

SearXNG (searxng.yaml) is the fallback web search for Claude Code when Z.ai's quota is exhausted. Key non-obvious facts:

- Engine API keys come from Bitwarden Secrets Manager via ExternalSecret `searxng-engine-keys` (ClusterSecretStore `default`); settings.yml can't expand env vars, so an initContainer sed-replaces `*_PLACEHOLDER` tokens into the rendered config. Extend that pattern for any new engine key.
- The MCP client lives outside the repo at `~/.local/lib/searxng-mcp/server.py` (bearer token from host keyring). Changes require a Claude Code restart.
- Google/Bing scraping stays disabled (home-IP CAPTCHA risk). Google PSE is not an option: whole-web search removed for new engines Jan 2026, Custom Search JSON API dies 2027-01-01. Startpage (weight 1.5) is the Google-index source; official Brave API (`braveapi`) is the paid-API engine.
- SearXNG dedupes results across engines, so per-result `engine` attribution understates braveapi's contribution — judge engines by the Prometheus per-engine metrics, not result labels. See [[gluetun-fork]] for the shelved VPN-egress idea to re-enable Google scraping.
- prometheus-operator silently rejects a whole ServiceMonitor if `basicAuth` lacks a `username` secret ref (`resource name may not be empty` in operator logs; target never appears). A metrics endpoint that ignores the username still needs a dummy one in the Secret. Check `serviceMonitor/<ns>/<name>` exists in active scrape pools, not just that curl works.
