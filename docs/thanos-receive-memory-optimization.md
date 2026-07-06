# Thanos Receive memory optimization

Status as of 2026-07-06. Tracks the effort to reduce Thanos Receive ingestor
memory via metric cardinality reduction, plus researched-but-not-yet-applied
config levers. Written so a fresh agent can pick this up without re-deriving
the analysis.

## Architecture context

- Thanos v0.41.0 (forked image `registry.apps.nickv.me/thanos/thanos:v0.41.0`),
  router/ingestor split: 2+ routers (Deployment), **5 ingestors**
  (StatefulSet `thanos-receive-ingestor-default`), ketama hashring managed by
  thanos-receive-controller.
- **Replication factor 3** (router flag `--receive.replication-factor=3`).
  This is a hard requirement — do not trade it away.
- Two HA Prometheus pairs remote-write in: `prom-kp` (tenant `vmubtkube-a`,
  2 replicas) and `prometheus-ext` (tenant `ext`, 2 replicas), plus external
  tenant `docker01`. Each replica sends with its own `prometheus_replica`
  external label, so **every logical series is stored twice** (then ×3
  replication = 6 copies total). The label must stay: Thanos Query/Compactor
  dedupe on it (`--deduplication.replica-label=prometheus_replica`). See the
  thanos_replica-vs-prometheus_replica memory note: `thanos_replica` labels
  ingestors, `prometheus_replica` labels senders.
- Ingestor config is already lean: `--tsdb.retention=6h`,
  `--enable-auto-gomemlimit`, `--tsdb.memory-snapshot-on-shutdown`,
  `--tsdb.out-of-order.time-window=30m`, exemplars disabled.
- Remote-write filtering lives in `application.kube-prometheus.yaml` under
  `prometheusSpec.remoteWrite[0].writeRelabelConfigs`.

## Problem

- Ingestors ran ~2.6 GB steady / ~3.9 GB daily peak each, with excursions to
  **6.1 GB against a 6 Gi limit**. Two ingestors (`-2`, `-3`) were OOMKilled
  in the 30 days before 2026-07-05.
- VPA (installed 2026-07-04, `Off` mode) recommended raising the request to
  ~4.5 GB. Direction chosen instead: **reduce usage** — the fleet is large
  relative to the cluster (5 × 6 Gi limits).
- Root cause: head-series volume. TSDB head memory scales roughly linearly
  with series count. Pre-optimization totals (unique = stored ÷ 3
  replication; still includes the ×2 HA-sender duplication):

  | Tenant | Unique head series |
  |---|---|
  | vmubtkube-a | 727,424 |
  | ext | 85,901 |
  | docker01 | 1,768 |
  | **total** | **815,094** |

  Per ingestor: ~443k head series, ~30k samples/s appended.

## How to measure (important for reproducing)

- **Per-metric series counts**: TSDB stats API on each ingestor. It is served
  on the **remote-write port 19291**, not the HTTP port 10902 (10902 returns
  404). Requires the tenant header:

  ```
  kubectl port-forward -n thanos pod/thanos-receive-ingestor-default-N 19291:19291
  curl -H "THANOS-TENANT: vmubtkube-a" \
    "http://127.0.0.1:19291/api/v1/status/tsdb?limit=100"
  ```

  Sum `headStats.numSeries` / `seriesCountByMetricName` across all 5 pods and
  divide by 3 (replication) for unique counts. Without the header only the
  empty `default-tenant` is returned.
- **Do NOT run `count({__name__=~'.+'})` through thanos-query** — this
  OOMKilled a query replica (2 Gi limit) on 2026-07-05. Name-scoped matchers
  (`{__name__=~'kube_.*'}`) are fine.
- thanos-query is reachable from the workstation at the ClusterIP directly
  (service IPs are routable): `http://<thanos-query ClusterIP>:9090`.
- Raw metric retention in the bucket reached back only ~30–39 days at the
  time of analysis — long-range validation queries beyond that return empty.

## Solution: cardinality reduction via remote-write relabeling

Drops are applied in `writeRelabelConfigs` (remote-write time), **not at
scrape time**, deliberately: local Prometheus keeps 7d of everything, so all
alerts and recording rules — including apiserver SLO rules that consume
`_bucket` series — evaluate unaffected, and recording-rule outputs still
reach Thanos. The cost is losing >7d history for the dropped raw series.

Relabel regexes are RE2: **no negative lookahead**. Exceptions must be
enumerated (e.g. `kube_replicaset_(created|...)` instead of
`kube_replicaset_(?!owner).*`).

### The three passes

| PR | Scope | Logical series | Status |
|---|---|---|---|
| [#212](https://github.com/nijave/vmubtkube-a/pull/212) | 7 apiserver `_bucket` families, `etcd_request_duration_seconds_bucket`, `kubernetes_feature_enabled`, `kube_pod_tolerations`, `kube_pod_status_reason`, `grpc_server_handled_total` scoped to `job=kube-etcd` | ~89k | **merged 2026-07-06 00:55Z** |
| [#213](https://github.com/nijave/vmubtkube-a/pull/213) | `kube_pod_status_{ready,scheduled}` one-hot `condition="false"/"unknown"` (keep `true` — full signal), `workqueue_{queue,work}_duration_seconds_bucket` | ~5.7k | open |
| [#215](https://github.com/nijave/vmubtkube-a/pull/215) | Third pass informed by Grafana Cloud allow lists: ReplicaSet spec/status mirrors, ZFS ZIL detail, probe/CRI/CSI buckets, cadvisor internals, node_disk discard/flush/merged, QoS class, PV metadata, node-exporter self-telemetry | ~46.4k | open, stacked on #213 |

Multipliers: logical × 2 (HA senders) = unique; unique × 3 (replication) =
stored. Projected cumulative effect when all three are merged:
**815k → ~545k unique series (−33%)**.

Pass 3 was built by diffing stored metrics against Grafana Cloud Kubernetes
Monitoring's default allow lists
(`github.com/grafana/k8s-monitoring-helm`, `allowLists/*.yaml`) — their
curated "what standard dashboards actually use" sets.

### Keep-list — metrics that look droppable but are NOT

Grafana's lists drop several things this cluster deliberately keeps:

- `device_udev_link_info` — join/info series mapping udev identities so
  zpool/LVM/mdraid metrics join to physical devices (user-confirmed; also in
  agent memory).
- `kube_replicaset_owner` — the pod→Deployment join path.
- `node_disk_info` — device identity (model/serial) join.
- `kube_persistentvolume_{info,claim_ref,capacity_bytes}` — PV↔PVC joins.
- `container_pressure_*` (PSI) — saturation signal, actively used for
  resource investigations.
- `container_oom_events_total` — needed for OOM forensics (used twice during
  this very investigation).
- ZFS dataset basic I/O (`node_zfs_zpool_dataset_{nread,nwritten,reads,writes,nunlink*}`)
  — only the `..._zil_*` transaction detail is dropped.
- `prometheus_replica` label — required for query-time dedup (HA senders).
- `_sum`/`_count` siblings of every dropped `_bucket` family — averages
  survive long-term.

## Measured results (post-#212, 16 hours in)

| Metric (per ingestor unless noted) | Before | After | Δ |
|---|---|---|---|
| Head series | ~442k | ~325k | **−26%** |
| Samples appended (fleet total) | 152k/s | 119.5k/s | −22% |
| Memory working set, 12h avg | 2,566 Mi | 2,084 Mi | −18% |
| Memory working set, 12h max | 3,865 Mi | 2,923 Mi | −24% |
| CPU p95 (12h) | 445m | 342m | −23% |

Fleet-wide, steady state freed ≈ 2.3 GB so far. Peak headroom vs the 6 Gi
limit improved from 63% to 48% utilization. Memory falls slightly less than
series because of fixed overhead and lazy Go GC (GOMEMLIMIT = 0.9 × limit;
the heap balloons toward ~5.4 GB before GC gets aggressive).

Baseline 30d reference numbers (pre-optimization, from the VPA validation):
ingestor memory p99 5.9 GiB / max 6.1 GiB; ingestor CPU p95 ~1000m of a
1250m limit; OOMKills on ingestors -2 and -3.

## Researched but NOT yet applied (next levers, in order)

1. **1h head blocks**: hidden flags `--tsdb.min-block-duration=1h
   --tsdb.max-block-duration=1h` (must be equal; defaults 2h;
   `cmd/thanos/receive.go` ~line 1029). Head holds 1–2h instead of 2–3h of
   samples → ~30% less steady head memory, smaller 2h-cycle truncation
   spikes. Cost: 2× block count for the compactor — fix thanos-compact's
   limits first (it has restarted 13+ times; CPU p95 947m vs 1-CPU limit,
   memory max 758Mi vs 768Mi limit).
2. **Cap'n Proto replication**: `--receive.replication-protocol=capnproto`
   (experimental, v0.38+). Cuts protobuf (de)serialization GC pressure on the
   ×3 replication fan-out. Needs port 19391 exposed on the ingestor
   service/statefulset; peer address inferred from gRPC address.
3. **Router compression off**: `--receive.grpc-compression=none` on routers —
   snappy caused documented memory/CPU bloat (thanos issues #5751, #7075);
   in-cluster bandwidth is cheap.
4. **GC tuning after the above land**: keep the 6 Gi limit for
   churn-event headroom but add `GOGC=75` (env) or lower
   `--auto-gomemlimit.ratio` to hold RSS nearer live heap.
5. **Native histograms (structural, larger project)**: Prometheus already
   sends them (`sendNativeHistograms: true`) and v0.41 receive always ingests
   them (the enable flag is a deprecated no-op). Migrating apiserver/etcd
   scrapes to native histograms and dropping classic buckets would eliminate
   most remaining `_bucket` cardinality.

Rejected options: retention below 6h (blocks are mmap'd, savings marginal,
store-gateway gap risk); disabling the 30m OOO window (measured OOO ingest is
~0.001 samples/s — costs nothing, keeps insurance); changing ingestor count
(total = unique × RF regardless of pod count); dropping `prometheus_replica`
(breaks HA dedup).

## Current status / next steps

- [x] Pass 1 (#212) merged 2026-07-06, effect confirmed (table above).
- [ ] Merge #213, then #215 (stacked; GitHub retargets on merge).
- [ ] Re-measure ~24h after #215 lands: expect ~295k head series/pod,
      steady memory ~1.8 GB, peaks ~2.5 GB. Same method as above.
- [ ] Fix thanos-compact limits (prereq for 1h blocks): raise CPU limit
      ≥1500m, memory limit ≥1.5 Gi. Evidence: 30d CPU p95 947m throttling 5%,
      memory pinned at the 768Mi limit, 13 restarts.
- [ ] Then apply levers 1–3 in one PR (flags only), re-measure, then lever 4.
- [ ] VPA note: `vpa-prometheus` in monitoring targets the operator-owned
      StatefulSet and reports ConfigUnsupported — retarget it at the
      `Prometheus` CR (`monitoring.coreos.com/v1`, name `prom-kp`). VPA's
      ingestor recommendation (4.5 GB) is based on pre-optimization data with
      a ~24h decay half-life; ignore it until it re-converges.

## Related session memories

`~/.claude/projects/.../memory/`: `device_udev_link_info` join metric,
`thanos_replica` vs `prometheus_replica` semantics, ServiceIPs routable from
workstation, never blanket `git add` (untracked secrets in tree).
