# Cluster Resources Not Managed by ArgoCD

Audit date: 2026-07-02

## 1. Monitoring — Partially Unmanaged

| Kind | Name |
|------|------|
| RoleBinding + Role | prometheus |

## 2. Secrets Not in Git

| Namespace | Secret | Notes |
|-----------|--------|-------|
| media | gluetun-airvpn | VPN secret, manually created |

## 3. Pending Bitwarden Entries

`thanos-objectstorage` ExternalSecret was added 2026-07-03 (`thanos/thanos-objectstorage-externalsecret.yaml`) but requires `thanos-objectstorage-{access,secret}-key` entries in Bitwarden Secrets Manager.

## 4. One-Off Resources to Clean Up

| Namespace | Kind | Name |
|-----------|------|------|
| immich | Backup | immich-pre-v3-upgrade |
