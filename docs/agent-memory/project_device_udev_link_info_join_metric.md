---
name: device-udev-link-info-join-metric
description: device_udev_link_info is a deliberate join/info metric — never flag it as droppable cardinality
metadata: 
  node_type: memory
  type: project
  originSessionId: 06fdecb9-98c1-4d59-a54b-2b4de1762c72
---

`device_udev_link_info` (~3.4k series, node-level) is an intentional info-style join series: it maps udev symlink identities so differently-shaped storage metrics (zpools, LVM, mdraid, etc.) can be joined via `group_left` to physical devices.

**Why:** In cardinality/series audits it looks like low-value per-device noise, but removing it breaks storage-metric joins.

**How to apply:** Exclude it from metric drop-list candidates in any Thanos/Prometheus cardinality cleanup (see [[project_searxng_stack]]-style stack audits and the 2026-07 remote-write drop PR #212).
