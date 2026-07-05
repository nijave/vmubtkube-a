# Cluster Resources Not Managed by ArgoCD

Audit date: 2026-07-02

## 1. Monitoring — Partially Unmanaged

| Kind | Name |
|------|------|
| Secret | minio-prom-additional-scrape-config, prom-kp-admission |
| ConfigMap | snmp-exporter-config |
| RoleBinding + Role | prometheus |

## 2. Unmanaged Namespaces

`external-secrets`, `monitoring`, `tigera-operator` — namespace objects themselves are not managed by ArgoCD.

## 3. Secrets Not in Git

| Namespace | Secret | Notes |
|-----------|--------|-------|
| media | gluetun-airvpn | VPN secret, manually created |

## 4. Pending Bitwarden Entries

`thanos-objectstorage` ExternalSecret was added 2026-07-03 (`thanos/thanos-objectstorage-externalsecret.yaml`) but requires `thanos-objectstorage-{access,secret}-key` entries in Bitwarden Secrets Manager.

## 5. One-Off Resources to Clean Up

| Namespace | Kind | Name |
|-----------|------|------|
| immich | Backup | immich-pre-v3-upgrade |
