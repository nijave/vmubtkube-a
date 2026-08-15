---
name: democratic-csi-iscsi-convoy
description: "node-driver iscsiadm idbm-lock convoy wedges (Aug 2026), node-DB record lifecycle, fixes shipped in image f161853"
metadata:
  node_type: memory
  type: project
  originSessionId: c13d56ad-bf16-4228-befc-93c0791f1819
---

Investigation 2026-08-14/15 (PRs nijave/democratic-csi#30 #31 #32, deployed
as image `f161853` via vmubtkube-a PR #428).

## The wedge

Recurring total `NodeStageVolume` outage on the highest-churn node
(vmubtkube-a24 hosts most volsync churn, ~750-880 stage/unstage/day
clustered in the nightly ~01:00 window). Three events Aug 6-15:

- Aug 6-7: 21k stage requests / 111 responses, wedged 2 DAYS, fixed only by
  node reboot (pod restart). Errors: `ABORTED: operation locked due to in
  progress operation(s)` (per-volume op-lock Set in the bin/ gRPC wrapper —
  aborts kubelet retries while a handler hangs).
- Aug 14 23:58-00:56Z (58 min, self-cleared): triggered by the 2f1f691 image
  rollout coinciding with the volsync wave (~17 concurrent stages); errors
  `{"code":null,...,"timeout":true}` (driver exec timeout SIGTERMed children).

## Mechanism

- open-iscsi (2.1.9) serializes EVERY node-DB op (reads included) behind one
  exclusive fcntl lock, `/run/lock/iscsi/iscsi.lock`→`/run/lock/iscsi/lock`,
  waiters polling ~10ms with ~30s budget; critical section enumerates ALL
  records, so orphan count directly scales op latency.
- The driver's iscsiadm runs via the `docker/iscsiadm` wrapper
  (`chroot /host`), so it takes the HOST's lock and DB — contending with host
  iscsid too. Container-side iscsiadm reaches host iscsid through the
  abstract unix socket `@ISCSIADM_ABSTRACT_NAMESPACE` (works because the node
  pods are hostNetwork; also why in-container probes behave like host ones).
- Driver has no cross-volume serialization (only the per-volume op-lock), so
  N volumes x ~9 iscsiadm invocations convoy; driver timeout
  (`ISCSI_DEFAULT_TIMEOUT`, 30s) kills children exactly as waiters exhaust
  their budget; kubelet retries keep arrival >= service rate.

## Fixes (all in image f161853)

- #30: module-level async-mutex serializing ALL iscsiadm execs FIFO
  (src/utils/iscsi.js) — each op runs uncontended; a 17-volume wave drains
  serially in seconds. Also added the missing child `error` handler (an
  unsettled spawn used to hang the exec promise forever).
- #31: bounded retry on `timeout:true` only (`ISCSIADM_TIMEOUT_RETRIES`,
  default 1, 250ms backoff) — absorbs external-holder contention; non-timeout
  failures stay fail-fast (actionable stderr).
- #32: opt-in `node.iscsi.nodeDbSweeper` — one-shot startup sweep (60s delay)
  deleting node-DB records with no session for the target IQN; scoped by
  `targetBasename` ("iqn.2025-04.info.somemissing.homelab:ubthv01:").
  Enabled in the driver-config ExternalSecret in application.democratic-csi.yaml.

First sweep on rollout (2026-08-15): 54 orphans deleted (a20 19, a21 2,
a22 22, a23 8, a24 3). Verified safe: deleted records were PVs staged on
OTHER nodes (no local session); re-staging recreates records idempotently.

## Node-DB record lifecycle (reference)

- DB lives at `/etc/iscsi/nodes/<iqn>/<portal>,3260` (hostPath into pods;
  this open-iscsi build ignores `/var/lib/iscsi`). One record per (PV, node).
- Created at NodeStage: `-o new`, ~5x `-o update` (CHAP from node-stage
  secret + timeouts), `-l`; deleted at NodeUnstage: `-u`, `-o delete`, 2
  verify queries. Records persist across reboots (on-disk); without the
  sweeper nothing ever removes an orphaned record.
- Leak sources: driver-pod restart mid-unstage, reboot with volumes staged,
  unstages lost to wedges. a24 accumulated 189 (Apr-Aug) before the manual
  sweep; orphans lengthen every future critical section (feedback loop).

## Debugging tricks that worked

- Node pods run privileged with `/host` and hostNetwork: `chroot /host`
  gives host tools (strace, journalctl); host strace can ptrace the
  container's children (chroot does not change the pid namespace).
- `iscsiadm -m session` keeps working when DB ops hang (kernel netlink, no
  idbm lock) — quick discriminator: DB-lock wedge vs iscsid/iscsi problem.
- HyperDX (otel.otel_logs, `__hdx_materialized_k8s.node.name` +
  `pod.name LIKE 'democratic-csi-node%'`): count `new request`/`new response`
  per NodeStage/Unstage per day — req >> resp = wedge in progress. Only
  replica chi-hyperdx-replicated-0-0-0 is running as of 2026-08-15.
- Sweeper results: `rg 'node-db sweep'` in node driver logs.
