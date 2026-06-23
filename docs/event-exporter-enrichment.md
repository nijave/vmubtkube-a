# Event Exporter: enrichment and scoping the ClusterRole

Notes on `kubernetes-event-exporter.yaml` and how to scope its ClusterRole
without losing the source-object enrichment feature.

## What enrichment actually does

For every `Event` the informer sees, the exporter takes `Event.InvolvedObject`
(an `ObjectReference`), resolves the GVR via the discovery API + RESTMapper, and
calls the **dynamic client** `Get()` on that object. From the result it copies
**only metadata fields** into an `EnhancedEvent`:

- `Labels`
- `Annotations`
- `OwnerReferences`
- `DeletionTimestamp` (exposed as `Deleted`)

These are then available in receiver templates as `.InvolvedObject.Labels.*`,
etc. (see `pkg/kube/event.go` for the `EnhancedEvent` / `EnhancedObjectReference`
structs, and `pkg/kube/objects.go` for the lookup).

Key code references (resmoio/kubernetes-event-exporter@v1.7):

| File | Role |
| --- | --- |
| `pkg/kube/objects.go` | `ObjectMetadataCache.GetObjectMetadata` — the dynamic-client lookup, LRU-ARC cached by `UID/ResourceVersion` |
| `pkg/kube/watcher.go`   | `onEvent` — gated by `omitLookup`; falls back to plain `ObjectReference` if lookup fails or is disabled |
| `main.go`              | Wires `cfg.OmitLookup` / `cfg.CacheSize` into the watcher |

Note that the exporter **only reads metadata** from these objects; it never
serializes `spec`, `status`, or `data`. The risk is purely the RBAC grant —
`get` on `secrets` lets a compromised SA read `secret.data`, even though the
exporter code itself would ignore `data`.

## Toggling / tuning enrichment

Enrichment is **on by default**. Knobs in the config ConfigMap:

```yaml
omitLookup: false   # set true to disable enrichment entirely (events only)
cacheSize: 1000     # LRU-ARC size; bump on large/busy clusters
```

`omitLookup: true` is the nuclear option: the dynamic client is never used and
the exporter only needs `events`. Useful for tight security contexts where you
don't need labels/annotations on the enriched events.

## Scoping the ClusterRole to what actually needs enriching

The wildcard rule:

```yaml
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["get", "watch", "list"]
```

is broader than enrichment requires. The exporter can only enrich against
**kinds that appear as `Event.InvolvedObject.Kind`** in your cluster. Discover
those, then enumerate them.

### Step 1 — inventory what kinds events reference in this cluster

Run this for a week or so (ideally across a few deployments, node reboots,
upgrades, PVC resizing, etc.):

```sh
kubectl get events -A -o json \
  | jq -r '.items[].involvedObject.kind' \
  | sort | uniq -c | sort -rn
```

For a typical cluster running the workloads in this repo you'll see something
like:

```
   1234 Pod
    318 Job
     97 Node
     42 CronJob
     35 PersistentVolumeClaim
     21 ReplicaSet
     12 Deployment
      8 StatefulSet
      6 DaemonSet
      4 Ingress
      3 Service
```

Anything outside that set doesn't need to be in the ClusterRole.

### Step 2 — write the scoped ClusterRole

Replace the wildcard rule with three explicit rules:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: event-exporter
rules:
# 1) Watch events (core function).
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "watch", "list"]

# 2) Leader election (unchanged from current).
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["*"]

# 3) Discovery — needed by RESTMapper to resolve GVR for the dynamic client.
#    This is what makes enrichment work; without it you'll see
#    "Failed to get object metadata" / "no matches for kind" errors.
- apiGroups: [""]
  resources: ["apiGroups", "apiVersions", "namespaces"]
  verbs: ["get", "list"]

# 4) Enrichment — read on the kinds events actually reference in THIS cluster.
#    Keep this list aligned with the inventory from step 1.
- apiGroups: [""]
  resources: ["pods", "nodes", "persistentvolumeclaims", "services"]
  verbs: ["get"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
  verbs: ["get"]
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get"]
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses"]
  verbs: ["get"]
```

Note the `verbs: ["get"]` (not `get,watch,list`) — enrichment does a single
point-`Get` per event; it does not watch or list involved objects.

### Step 3 — verify nothing broke

After applying, watch:

- exporter logs for `Failed to get object metadata` or `no matches for kind`
  (these indicate a kind events reference is missing from rule 4)
- the `event_exporter_kube_api_read_requests_total` counter — should keep
  incrementing normally
- the `event_exporter_kube_api_read_cache_hits_total` counter — cache hit rate
  tells you whether `cacheSize` is appropriate

### Step 4 — keep it in sync

The ClusterRole and the live event-kind inventory will drift over time (new
operators install new CRDs that emit events; you add a workload that produces
new kinds). Two options:

1. **Manual**: re-run the Step 1 inventory quarterly and prune/add kinds.
2. **Automated**: a small kube-prometheus alert on
   `rate(event_exporter_kube_api_read_requests_total{code!="403"}[5m]) == 0
    and rate(event_exporter_failed_lookups_total[5m]) > 0` (or whatever your
   log-based metric looks like) to flag when enrichment silently degrades.

## Notes on secrets/configmaps

Events rarely reference `secrets` or `configmaps` directly — those objects
don't emit events under normal operation. So the scoped ClusterRole above does
**not** grant `get` on them, and the exporter doesn't need it for enrichment.

If you ever see events referencing those kinds (custom controllers emitting
"Failed to sync secret X" events with `InvolvedObject.Kind: Secret`, for
example), prefer:

1. fixing the controller so its events reference its own CR / the dependent
   workload rather than the Secret, or
2. using `omitLookup: true` for the exporter

rather than adding `secrets: [get]` to the ClusterRole. The exporter code
only reads metadata, but granting RBAC `get` on `secrets` is an unnecessary
surface in this architecture.

## Why not just keep the wildcard?

The wildcard "works" and avoids the inventory step. The tradeoff:

| | Wildcard `["*"]` | Scoped list |
| --- | --- | --- |
| Maintenance | zero | quarterly inventory |
| Secret-read surface | entire cluster | none |
| Defense in depth if exporter image or dependency is compromised | full read of all `secrets`/`configmaps` | bounded to ~10 workload kinds |
| Works for unexpected CRDs emitting events | yes | needs an explicit line added |

For a single-tenant homelab cluster the wildcard is a defensible choice — the
trust boundary is already the whole cluster. For multi-tenant or
internet-adjacent clusters, the scoped form is worth the maintenance cost.
