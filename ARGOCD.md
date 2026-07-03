# ArgoCD Setup Review

## Architecture Summary

This is an **app-of-apps** pattern: `application.vmubtkube-a.yaml` is a self-referencing root app pointing at `./` in the repo. It auto-discovers and syncs ~35 child `application.*.yaml` files, each defining a child Application (Helm charts, kustomize dirs, or raw YAML). Some subdirectories (`woodpecker/`, `immich/`) contain nested Application resources, making the app-of-apps two levels deep in places.

ArgoCD manages itself via the argo-cd Helm chart (`application.argocd.yaml`). Dependencies like cert-manager, contour, and CNPG are vendored via vendir with kustomize overlays. Secrets come from Bitwarden Secrets Manager via ExternalSecrets. Renovate handles version bumps (no ArgoCD Image Updater).

---

## What's Done Well

1. **Consistent sync policies** — Nearly every app uses `automated: {prune: true, selfHeal: true}` with the same `syncOptions` triplet (`PruneLast`, `ServerSideApply`, `ApplyOutOfSyncOnly`). This consistency makes the system predictable.

2. **ServerSideApply everywhere** — Avoids annotation size limits and gives cleaner field ownership. This is the recommended approach.

3. **CRD protection** — The `crds` app disables pruning (`prune: false`) to prevent cascade-deleting all ExternalSecret instances if the CRD source changes.

4. **Self-managed ArgoCD with proper ignoreDifferences** — The `ignoreDifferences` on ConfigMap `.data`/`.metadata.labels` and Secret `.data`/`.stringData`/`.metadata.labels`/`.metadata.annotations`, combined with `RespectIgnoreDifferences=true`, prevents the known thrashing loop where ArgoCD fights itself over its own state.

5. **Secret management** — Deploy key via ExternalSecret, `createSecret: false` for ArgoCD's own secret, Bitwarden-backed ClusterSecretStore with mTLS to the SDK server. No secrets committed to git (the HyperDX API key is intentional and documented).

6. **Vendir + kustomize** — Clean separation: `base/` is machine-managed by vendir, `kustomization.yaml` in the parent allows overlays (contour has several patches). Renovate bumps tags in `vendir.yml` and runs `vendir sync` as a post-upgrade task.

7. **Monitoring coverage** — ServiceMonitors on all major components including ArgoCD itself, with consistent `release: prom` label for Prometheus selector matching. OTLP tracing configured.

8. **Retry on all apps** — Every Application has exponential backoff retry (5s base, factor 2, max 3m, limit 2) to handle transient sync failures without waiting for the next reconciliation loop.

9. **Webhook setup** — Contour HTTPProxy for GitHub webhooks with mittwald secret-generator auto-generated webhook secret, marked with `Prune=false` and `IgnoreExtraneous` so ArgoCD doesn't fight the generated value.

10. **Careful drift avoidance** — `ignoreDifferences` applied where needed: ArgoCD self-management, CRD `managedFields` for clickhouse-operator, ExternalSecret `conversionStrategy`, StatefulSet `volumeClaimTemplates` timestamps.

---

## Areas for Improvement

### High Impact

#### 1. Everything uses `project: default`

Every Application targets `project: default`, which has no restrictions on source repos, destination clusters, or namespaces. Best practice is to define AppProjects that scope what each group of apps can do. Even in a single-cluster setup, projects limit blast radius — e.g., a media-stack project that can only deploy to `immich`/`media` namespaces, an infra project for `monitoring`/`kube-system`/`calico-system`.

The `default` project also permits deploying cluster-scoped resources from any source, which means a compromised Helm chart repo could create ClusterRoles.

#### ~~2. No retry policies on child apps~~ (RESOLVED)

All Application resources now have retry with exponential backoff (5s, factor 2, max 3m, limit 2).

#### 3. No sync ordering between child apps

Only calico has a sync-wave annotation. The root app treats all ~35 child apps as unordered peers, but there are real dependencies:
- CRDs app → external-secrets operator → anything with ExternalSecrets
- cert-manager → anything with Certificates (otel-collector, external-secrets webhook)
- calico → everything else (networking)

Self-heal eventually resolves this on a fresh cluster, but the first boot would involve multiple failed syncs and retries before convergence. Sync waves on the root app's children would give deterministic ordering.

#### 4. No ArgoCD Notifications

No notification controller or config. Sync failures, health degradation, or out-of-sync drift could go unnoticed. For a production-like setup, ArgoCD Notifications (or at minimum a Prometheus alert on `argocd_app_info{sync_status!="Synced"}`) would catch issues early.

### Medium Impact

#### ~~5. Resource tracking method not configured~~ (RESOLVED)

`resource.trackingmethod: annotation` is already set in `application.argocd.yaml` under `configs.cm`. ArgoCD uses annotation-based tracking (`argocd.argoproj.io/tracking-id`) instead of the `app.kubernetes.io/instance` label, avoiding SSA field ownership conflicts.

#### ~~6. No custom health checks for CRDs~~ (RESOLVED)

Custom health checks are configured in `application.argocd.yaml` under `configs.cm` for CNPG `Cluster`, `ClickHouseInstallation`, `MongoDBCommunity`, and VolSync `ReplicationSource`. `ExternalSecret` and `Certificate` have built-in ArgoCD health support.

#### 7. Root app directory scope is broad

The root app points at `./` with only `renovate.json`, `vendir.yml`, and `vendir.lock.yml` excluded. Untracked files (e.g. `gluetun-poc.yaml`, `qds.yaml`, `vpa.yaml`) would be auto-synced if committed. Files like `.woodpecker.yaml` and `docs/` may also be picked up. A tighter include pattern or a dedicated subdirectory for root-level manifests would prevent accidental syncs.

#### ~~8. Bitnami image in HyperDX config render Job~~ (RESOLVED)

Replaced with `docker.io/alpine/k8s` (currently `1.36.2`), tracked by Renovate's kubernetes manager.

### Lower Impact

#### ~~9. No RBAC / auth beyond local admin~~ (N/A — single local admin)

#### ~~10. No network policies for ArgoCD namespace~~ (RESOLVED)

`networkpolicy.argocd.yaml` adds a default-deny ingress policy with targeted exceptions: argocd-server remains fully open (authenticated API, UI, webhooks), repo-server and redis only accept traffic from other ArgoCD components, and all components allow metrics scraping from the monitoring namespace.

---

## Application Inventory

| Application | Source Type | Chart/Path | Target Namespace |
|---|---|---|---|
| `vmubtkube-a` (root) | Git directory | `./` | (cluster-wide) |
| `argocd` | Helm | argo-cd 10.1.1 | argocd |
| `calico` | Helm | tigera-operator v3.32.1 | tigera-operator |
| `cert-manager` | Git (kustomize) | vendored/cert-manager | (cluster-wide) |
| `cert-manager-webhook-dnsimple` | Helm | cert-manager-webhook-dnsimple | cert-manager |
| `crds` | Git directory | vendored/external-secrets-crds/base | (cluster-wide) |
| `cnpg` | Git directory | vendored/cnpg/base | (cluster-wide) |
| `contour` | Git (kustomize) | vendored/contour | (cluster-wide) |
| `barman-cloud-plugin` | Git directory | vendored/barman-cloud-plugin/base | (cluster-wide) |
| `democratic-csi` | Helm | democratic-csi | kube-system |
| `descheduler` | Helm | descheduler | kube-system |
| `external-secrets` | Helm | external-secrets 2.7.0 | external-secrets |
| `fluentbit` | Git directory | fluentbit/ | monitoring |
| `hyperdx` | Helm | clickstack | hyperdx |
| `immich` | Git directory | immich/ | immich |
| `immich-app` | Helm (nested) | immich | immich |
| `intel-device-plugins-operator` | Helm | intel-device-plugins-operator | kube-system |
| `intel-device-plugins-gpu` | Helm | intel-device-plugins-gpu | kube-system |
| `kube-prometheus` | Helm | kube-prometheus-stack | monitoring |
| `kured` | Helm | kured | kube-system |
| `metacontroller` | Helm (OCI) | metacontroller-helm | operators |
| `node-feature-discovery` | Helm | node-feature-discovery | kube-system |
| `operators` | Git directory | operators/ | (cluster-wide) |
| `otel-collector` | Helm | opentelemetry-collector | monitoring |
| `otel-collector-contour` | Helm | opentelemetry-collector | projectcontour |
| `otel-logs-daemonset` | Helm | opentelemetry-collector | monitoring |
| `secret-generator` | Helm | kubernetes-secret-generator | operators |
| `snapshot-controller` | Helm | snapshot-controller | kube-system |
| `thanos` | Git directory | thanos/ | thanos |
| `thanos-bucket-memcached` | Helm (OCI) | memcached | thanos |
| `thanos-index-memcached` | Helm (OCI) | memcached | thanos |
| `volsync` | Helm | volsync | volsync-system |
| `woodpecker` | Git directory | woodpecker/ | woodpecker |
| `woodpecker-app` | Helm (OCI, nested) | woodpecker | woodpecker |
| `blackbox-exporter` | Helm | prometheus-blackbox-exporter | monitoring |
| `clickhouse-operator` | Helm | altinity-clickhouse-operator | operators |
| `kubelet-rubber-stamp` | Git (kustomize) | vendored/kubelet-rubber-stamp | (cluster-wide) |
| `metrics-server` | Git (kustomize) | vendored/metrics-server | (cluster-wide) |
| `mongodb-community-operator` | Helm | community-operator | operators |

---

## Summary

The setup is well-structured for a single-cluster homelab. The consistency of sync policies, proper self-management of ArgoCD, vendored-dependency pattern, and secret management are all strong. The highest-value remaining improvements would be: (1) defining AppProjects to constrain the `default` project, (2) setting up basic sync-failure alerting, and (3) adding sync waves for deterministic bootstrap ordering.
