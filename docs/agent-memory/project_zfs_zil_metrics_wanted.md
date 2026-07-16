---
name: zfs-zil-metrics-wanted
description: node_zfs_zpool_dataset_zil_* metrics are wanted (NAS via prometheus-ext); k8s nodes run no ZFS
metadata: 
  node_type: memory
  type: project
  originSessionId: 06fdecb9-98c1-4d59-a54b-2b4de1762c72
---

`node_zfs_zpool_dataset_zil_*` (~8.8k series, ext tenant) must NOT be dropped: prometheus-ext scrapes the NAS, whose zpools have ZIL/SLOG devices worth observing. The k8s cluster nodes run no ZFS at all, so ZFS-metric relabel rules on the kube-prometheus remote write are dead config (a zil drop rule from PR #215 was reverted in #223 for this reason).

**Why:** ZIL detail looks like droppable per-dataset noise in cardinality audits (Grafana Cloud's allow lists drop all node_zfs_*), but it's the observability for NAS write-path/SLOG behavior.

**How to apply:** In Thanos/Prometheus cardinality cleanups, exclude all `node_zfs_*` from ext-tenant drop lists; don't add ZFS rules to kube-prometheus at all. Related: [[device-udev-link-info-join-metric]].
