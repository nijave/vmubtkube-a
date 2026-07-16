---
name: grafana-dashboard-delivery
description: "How Grafana dashboards get delivered in this repo, and why the sidecar reload-401 is harmless"
metadata: 
  node_type: memory
  type: project
  originSessionId: df434b1b-9a44-4fc4-9b2c-a2d00abf81db
---

Dashboards are plain ConfigMaps (label `grafana_dashboard: "1"`, annotation `grafana_dashboard_folder: <Folder>`) in the relevant namespace — **no** grafana-operator, no `GrafanaDashboard` CRD. The `prom-grafana` release's `grafana-sc-dashboard` sidecar (kiwigrid/k8s-sidecar) watches all namespaces, writes each dashboard JSON into the grafana pod's `/tmp/dashboards/`, and Grafana's provisioning is `sidecarProvider` with `type: file`, `path: /tmp/dashboards`, **`updateIntervalSeconds: 30`**.

That 30s **file poll** is the real delivery mechanism — Grafana re-scans the dir every 30s regardless of the sidecar's reload API, so dashboards arrive even when the sidecar's reload POST fails. The sidecar reloads via basic-auth (`REQ_USERNAME`/`REQ_PASSWORD` from `prom-grafana`) POSTed to `/api/admin/provisioning/{dashboards,datasources}/reload`; a **401 there** means the live Grafana admin password has drifted from the secret. Grafana only applies `GF_SECURITY_ADMIN_PASSWORD` on **first DB init**, so the env var never re-syncs after drift — reconcile with `grafana cli admin reset-admin-password "$GF_SECURITY_ADMIN_PASSWORD"` inside the `prom-grafana-0` pod (`-c grafana`). Caveats: Grafana 13 ships **no standalone `grafana-cli`** — use `/usr/share/grafana/bin/grafana cli`; the listener is **HTTPS on :3000** (TLS from `grafana-k8s-somemissing-info-tls`), so verify with `curl -ks --noproxy '*' https://127.0.0.1:3000/...`. Can recur if the secret ever changes (e.g. helm regenerates it); fix the same way. Did this on 2026-07-10 (401→200 on the reload endpoint).

**Why:** spent time treating the sidecar 401 as a harmless quirk before realizing it's plain DB/env password drift with a one-command fix.
**How to apply:** to add a dashboard, drop a labeled ConfigMap (example: `woodpecker/grafana-dashboard.woodpecker.yaml`, PR #246). Validate by checking the file landed in `/tmp/dashboards` and that panel queries return data. Selector gotcha: in-cluster metrics carry the full `job="<ns>/<release>-server"` label, so filter on `namespace="<ns>"` rather than `job="<name>"`. See [[feedback_no_workaround_at_data_loss]].
