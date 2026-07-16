---
name: democratic-csi-perf-findings
description: "democratic-csi slowness root causes — volsync Released-PV delete storm, 14s CreateVolume, no native OTEL"
metadata: 
  node_type: memory
  type: project
  originSessionId: a8c49880-7201-497c-9cc2-88ebf967daac
---

Perf investigation (2026-07-05, PR #214 adds sidecar metrics):

- ~253 Released PVs (volsync `*-src` Clone PVCs) stuck: DeleteVolume fails
  `filesystem has dependent snapshots` (controller-zfs/index.js throws when the
  zvol has a snapshot with inherited `democratic-csi:managed_resource=true`).
  ~3,000 failed retries/day, each an SSH round-trip to nas (172.16.1.118);
  occasional `(SSH) Channel open failure` = sshd MaxSessions saturation.
  NAS-side `zfs list -t snapshot` under `midline/k8s/pvs` needed to see which
  snapshots block deletion (agent SSH to NAS was permission-denied).
- CreateVolume avg ~14s / max 25s (from HyperDX log pairing) — volsync
  copyMethod: Clone churn ≈ 600 stage ops/day cluster-wide.
- NodeStage ~4.5s = ~2.2s iscsiadm discovery+login + ~2.2s settle/fsck/mount
  (`node.mount.checkFileSystem.enabled: true` adds fsck each stage).
- democratic-csi has NO OTEL/tracing/prometheus deps (v1.9.5 and master);
  controller-side latency only visible via CSI sidecar
  `csi_sidecar_operations_seconds` (enabled in PR #214) or kubelet
  `csi_operations_seconds` (node ops only, already in Thanos).
- Blocking snapshots are sanoid `autosnap_*` (syncoid replication) inheriting
  `democratic-csi:managed_resource=true`. Fix branch (opt-in
  `zfs.deleteVolumeIgnoreForeignSnapshots`, uses `zfs get -s local,received`):
  nijave/democratic-csi branch feat/delete-volume-ignore-foreign-snapshots
  (no PR opened yet; image build + manifest bump still pending).
- HyperDX ClickHouse: query BOTH replicas (chi-hyperdx-replicated-0-0-0 and
  -0-1-0) in parallel for throughput; always bound queries with TimestampTime
  and max_execution_time — unbounded map-key predicates run for minutes.
