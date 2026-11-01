---
name: pod-logs-in-clickhouse
description: container logs for every pod, including deleted/restarted ones, are kept in HyperDX's ClickHouse (ns hyperdx) and queried with the querying-hyperdx-clickhouse skill
metadata:
  node_type: memory
  type: reference
---

`kubectl logs` only covers live pods (and `--previous` for one restart). Logs
from replaced or deleted pods — e.g. "was this warning there before the
rollout?" — are in ClickHouse table `otel.otel_logs` in namespace `hyperdx`.

Access (read-only, default user, no password):

```bash
kubectl -n hyperdx exec chi-hyperdx-replicated-0-0-0 -c clickhouse -- \
  clickhouse-client --query "SELECT ..."
```

Use the `querying-hyperdx-clickhouse` skill for schema and gotchas. Filter by
the materialized k8s columns and always bound time, for example:

```sql
SELECT toDate(TimestampTime) day, __hdx_materialized_k8s.pod.name pod, count() n
FROM otel.otel_logs
WHERE __hdx_materialized_k8s.namespace.name = 'immich'
  AND Body ILIKE '%schema drift%'
  AND TimestampTime > now() - INTERVAL 30 DAY
GROUP BY day, pod ORDER BY day
```

Retention covers at least 30 days (verified 2026-11-01).
