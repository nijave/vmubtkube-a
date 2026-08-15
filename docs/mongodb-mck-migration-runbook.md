# MongoDB community-operator to MCK migration runbook

Planned 2026-08-15 for the `hyperdx` MongoDB replica set. Companion PR:
"feat(mongodb): migrate community-operator app to MCK" (swaps
`operators/mongodb-kubernetes.yaml` to chart `mongodb-kubernetes` 1.10.0 and
pins `serviceAccountName` in `hyperdx-mongo.yaml`). This runbook covers the
preflight, the merge, verification, and rollback.

## Background

`operators/mongodb-community-operator.yaml` (now `operators/mongodb-kubernetes.yaml`)
pins chart `community-operator` 0.13.0, the final release of
mongodb/mongodb-kubernetes-operator. MongoDB deprecated that operator in favor
of MCK (mongodb/mongodb-kubernetes, the unified community+enterprise operator)
and ended best-effort support in November 2025. MCK 1.10.0 (2026-07-30) is
active and reconciles the same `MongoDBCommunity` CRs. Upstream migration
guide:
<https://github.com/mongodb/mongodb-kubernetes/blob/master/docs/migration/community-operator-migration.md>

## Transition design (read this first)

The PR repoints the existing `mongodb-community-operator` ArgoCD Application to
the new chart in place. It does not rename or delete the Application, so:

- No finalizer cascade runs, so nothing the old chart owns disappears
  unexpectedly. Rendered diff of the two charts (same values, namespace
  `operators`):
  - **Updated in place**: Deployment `mongodb-kubernetes-operator` (operator
    image 0.13.0 to 1.10.0, rolling update, no availability gap),
    ServiceAccount `mongodb-kubernetes-operator`, ClusterRole and
    ClusterRoleBinding `mongodb-kubernetes-operator`, CRD
    `mongodbcommunity.mongodbcommunity.mongodb.com`.
  - **Created**: seven new CRDs (`mongodb.mongodb.com`,
    `opsmanagers.mongodb.com`, `mongodbusers.mongodb.com`,
    `mongodbsearch.mongodb.com`, `mongodbmulticluster.mongodb.com`,
    `clustermongodbroles.mongodb.com`, `voyageais.ai.mongodb.com`) and the MCK
    RBAC additions (webhook, telemetry, PVC-resize, cluster-mongodb-role,
    `mongodb-kubernetes-appdb` objects in `operators`).
  - **Pruned**: ServiceAccount/Role/RoleBinding `mongodb-database` in the
    `operators` namespace (release-namespace copies that nothing uses; the
    copies this replica set runs on live in `hyperdx` and belong to the root
    app).
- Two Applications never coexist, so no two operators fight over the CR or the
  same-named Deployment.
- ArgoCD never deletes or prunes CRDs (it puts no tracking markers on them),
  and the live CRD also carries `helm.sh/resource-policy: keep` from chart
  0.13.0. CRD continuity holds by construction; the app-level
  `ignoreDifferences` in the manifest keeps that leftover annotation from
  holding the app OutOfSync.
- The CR pins `serviceAccountName: mongodb-database`, so pods keep the
  existing ServiceAccount/Role/RoleBinding in `hyperdx`. MCK would otherwise
  rename it to `mongodb-kubernetes-appdb`, which the chart only creates in the
  operator namespace.
- The chart values pin `community.mongodb.repo: docker.io/mongodb` because the
  MCK default (quay.io/mongodb) publishes no `8.0.4-ubi8` tag. The mongod
  image string stays `docker.io/mongodb/mongodb-community-server:8.0.4-ubi8`,
  byte-identical before and after the swap.

Expected workload churn: MCK's first reconcile rewrites the
`hyperdx` StatefulSet with a newer agent
(`quay.io/mongodb/mongodb-agent:108.0.25.9029-1`, from
`mongodb-agent-ubi:108.0.6.8796-1`) and readiness probe
(`mongodb-kubernetes-readinessprobe:1.0.24`, from 1.0.23). The StatefulSet
rolls one member at a time (highest ordinal first, each waits for Ready), so
the replica set keeps a quorum of two throughout. Expect roughly one to three
minutes per member. `spec.version` stays at 8.0.4; this migration does not
couple the operator swap with a MongoDB upgrade.

## Preflight — do not merge until every gate passes

### 0. Confirm nothing else races the merge

- Check that no Renovate PR bumps `operators/mongodb-kubernetes.yaml` or
  `hyperdx-mongo.yaml` at merge time.
- Merge order against open PRs: #415 adds a Renovate comment line above
  `spec.version` in `hyperdx-mongo.yaml` (different hunk than this PR's edit;
  either order merges cleanly). #416 touches only `TODO.md`. Neither blocks
  this migration.

### 1. Back up the data (the replica set has no other backup)

This workload has no volsync `ReplicationSource` and no VolumeSnapshotClass
exists on the cluster, so a mongodump taken now is the only restore point.
Take it from member 0 with a direct connection and save it off-cluster:

```sh
MONGO_PW=$(kubectl -n hyperdx get secret hyperdx-mongo-app-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl -n hyperdx exec hyperdx-0 -c mongod -- \
  mongodump --uri="mongodb://hyperdx:${MONGO_PW}@127.0.0.1:27017/?authSource=admin&directConnection=true" \
  --archive --gzip \
  > "hyperdx-mongo-$(date +%Y%m%d-%H%M).archive.gz"
unset MONGO_PW
```

Gate: the archive exists, is non-trivially sized (`ls -lh`), and `gzip -t`
passes. If the container lacks `mongodump`, fall back to the same image as a
pod with the secret mounted:

```sh
kubectl -n hyperdx run mongo-backup --rm -it --restart=Never \
  --image=docker.io/mongodb/mongodb-community-server:8.0.4-ubi8 \
  --overrides='{
    "spec": {
      "volumes": [{"name": "pw", "secret": {"secretName": "hyperdx-mongo-app-credentials"}}],
      "containers": [{
        "name": "mongo-backup", "stdin": true, "tty": true,
        "volumeMounts": [{"name": "pw", "mountPath": "/pw"}],
        "command": ["/bin/bash", "-c", "mongodump --uri=\"mongodb://hyperdx:$(cat /pw/password)@hyperdx-0.hyperdx-svc.hyperdx.svc.cluster.local:27017/?authSource=admin&directConnection=true\" --archive --gzip > /tmp/dump.gz && sleep 600"]
    }}'
kubectl -n hyperdx cp mongo-backup:/tmp/dump.gz "./hyperdx-mongo-$(date +%Y%m%d-%H%M).archive.gz"
kubectl -n hyperdx delete pod mongo-backup
```

Keep the archive until the migration has been stable for at least a week.

### 2. Confirm the CRD protection and replica set health

```sh
# Gate: prints "helm.sh/resource-policy: keep"
kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com \
  -o jsonpath='{.metadata.annotations.helm\.sh/resource-policy}'; echo

# Gate: phase Running, version 8.0.4
kubectl get mongodbcommunity hyperdx -n hyperdx

# Gate: 3/3 ready
kubectl get sts hyperdx -n hyperdx
kubectl get pods -n hyperdx -l app=hyperdx-svc
```

### 3. Confirm the images the swap will pull exist

Verified 2026-08-15; re-check on merge day if more than a few weeks passed:

```sh
curl -fsS 'https://quay.io/api/v1/repository/mongodb/mongodb-kubernetes/tag/?limit=10&filter_tag_name=like:1.10' | jq -r '.tags[].name' | head -2
curl -fsS 'https://quay.io/api/v1/repository/mongodb/mongodb-agent/tag/?limit=5&filter_tag_name=like:108.0.25' | jq -r '.tags[].name' | head -2
curl -fsS 'https://quay.io/api/v1/repository/mongodb/mongodb-kubernetes-readinessprobe/tag/?limit=5&filter_tag_name=like:1.0.2' | jq -r '.tags[].name' | head -3
curl -fsS 'https://hub.docker.com/v2/repositories/mongodb/mongodb-community-server/tags/8.0.4-ubi8' | jq -r .name
```

Gate: `1.10.0`, `108.0.25.9029-1`, `1.0.24`, and `8.0.4-ubi8` all appear.

## Merge and watch

1. Merge the PR. ArgoCD picks up the commit and syncs the `operators` parent
   app, then the child app re-renders from the new chart.
2. Watch the operator roll (expect a normal rolling update, no gap):

```sh
kubectl -n argocd get application mongodb-community-operator -w
kubectl -n operators rollout status deploy/mongodb-kubernetes-operator --watch
kubectl -n operators logs deploy/mongodb-kubernetes-operator -f
```

3. Expect the sync to prune `mongodb-database` SA/Role/RoleBinding in
   `operators` (only there, not in `hyperdx`) and to create the seven new
   CRDs. A brief OutOfSync flap during the chart swap resolves on the next
   refresh.

4. Watch the StatefulSet roll one member at a time:

```sh
kubectl -n hyperdx rollout status sts/hyperdx --watch
kubectl -n hyperdx get pods -l app=hyperdx-svc -w
kubectl -n hyperdx get mongodbcommunity hyperdx -w
```

The phase may briefly leave `Running` while MCK re-reconciles; the pods keep
serving during the roll. Total expected window: five to ten minutes.

## Verification gates (in order, after the roll finishes)

1. CRD intact and the CR survived:

```sh
kubectl get crd mongodbcommunity.mongodbcommunity.mongodb.com \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'; echo  # Established
kubectl get mongodbcommunity hyperdx -n hyperdx   # Running, 8.0.4
```

2. Operator logs show a clean reconcile of `hyperdx` (no RBAC or CRD errors):

```sh
kubectl -n operators logs deploy/mongodb-kubernetes-operator --tail=100
```

3. Replica set health from inside the cluster:

```sh
MONGO_PW=$(kubectl -n hyperdx get secret hyperdx-mongo-app-credentials \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl -n hyperdx run mck-verify --rm -it --restart=Never \
  --image=docker.io/mongodb/mongodb-community-server:8.0.4-ubi8 -- \
  mongosh --quiet \
  "mongodb://hyperdx:${MONGO_PW}@hyperdx-0.hyperdx-svc.hyperdx.svc.cluster.local:27017/?authSource=admin&replicaSet=hyperdx&directConnection=true" \
  --eval 'rs.status().members.map(m => ({name: m.name, state: m.stateStr, health: m.health}))'
unset MONGO_PW
```

Gate: one PRIMARY and two SECONDARY members, all `health: 1`.

4. HyperDX still works: open <http://hyperdx.k8s.somemissing.info>, log in,
   and load a search that spans both ClickHouse and Mongo data (saved views or
   alert rules). Also scan the app logs for Mongo connection errors:

```sh
kubectl -n hyperdx logs deploy/hyperdx --tail=100 | grep -i mongo
```

5. Exporter metrics flow (the percona sidecar and its ServiceMonitor are
   untouched, but confirm the pods' new generation still serves them):

```sh
kubectl -n hyperdx port-forward svc/hyperdx-mongo-metrics 9216:9216 &
curl -s http://localhost:9216/metrics | grep '^mongodb_up'
kill %1
```

Gate: `mongodb_up 1` for all three members.

6. ArgoCD converges: `mongodb-community-operator`, `operators`, and
   `vmubtkube-a` all Synced and Healthy. If the app shows a permanent diff on
   the CRD annotation, confirm the `ignoreDifferences` in
   `operators/mongodb-kubernetes.yaml` covers it before investigating
   further.

## Rollback

The migration writes no data and deletes nothing the replica set runs on, so
rollback is a git revert:

```sh
git revert <merge-sha> && git push
```

That repoints the Application back to chart `community-operator` 0.13.0, rolls
the operator back, and (on its next reconcile) restores the previous agent and
readiness-probe images with another one-at-a-time StatefulSet roll. Watch the
same gates as the forward merge.

Notes:

- ArgoCD never prunes CRDs, so the seven MCK-only CRDs stay on the cluster
  after a revert. No CRs of those kinds exist; delete them manually if the
  list bothers you (`kubectl delete crd mongodb.mongodb.com
  opsmanagers.mongodb.com mongodbusers.mongodb.com mongodbsearch.mongodb.com
  mongodbmulticluster.mongodb.com clustermongodbroles.mongodb.com
  voyageais.ai.mongodb.com`).
- If a member fails to rejoin (stuck `RECOVERING`/`ROLLBACK`, pods
  crash-looping): stop, do not delete PVCs or pods beyond what the operator
  does, and capture `kubectl -n hyperdx describe sts hyperdx` plus operator
  logs before reverting. The data volumes survive every step of this
  migration; the mongodump from preflight gate 1 restores the data into a
  fresh replica set as the last resort (`mongorestore --archive --gzip`).

## Deliberately out of scope

- The MongoDB 8.2/8.3 bump (`TODO.md` item 9 tracks it): this migration keeps
  `spec.version: 8.0.4` and the `docker.io/mongodb ... ubi8` repo pin so the
  operator swap stays reviewable on its own. Revisit both after MCK has been
  stable for a week or two; the 8.2/8.3 images also decide whether the repo
  pin should move to quay.io's ubi9 line.
- Closing `TODO.md` item 9: close it after this migration lands and you make
  the follow-up version decision, not in the migration PR.
- CI note: `.ci/validate-helm.sh` and its pre-commit twin only render
  `application.*.yaml` at the repo root, so `operators/*.yaml` chart apps
  (this one and the clickhouse operator) get no rendered-chart validation in
  CI. The MCK chart carries no `values.schema.json`, and its rendered CRs
  would need kubeconform schemas the repo does not mirror; this runbook's
  manual render check covers the gap for this migration.
