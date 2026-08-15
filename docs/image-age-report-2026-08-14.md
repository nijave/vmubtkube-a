# Running image age report — 2026-08-14

All unique container images (containers and init containers) running across
the cluster on 2026-08-14, sorted oldest first. Ages are relative to the
generation date.

Dates are the **image build date** from each image's registry config blob
(fetched live via `skopeo inspect`), not pod or container creation times.
Workloads are the owning controller resolved from pod `ownerReferences`
(ReplicaSet → Deployment, Job → CronJob). IaC files are the repo files that
provision the workload; for Helm-sourced workloads the cited
`application.*.yaml` is the ArgoCD Application whose inline values (or
upstream chart) define the images.

| Image | Built | Age | Workload(s) | IaC file(s) |
|---|---|---|---|---|
| `ghcr.io/resmoio/kubernetes-event-exporter:v1.7` | 2024-02-23 | 2y 5m 22d | `monitoring/Deployment:event-exporter` | `kubernetes-event-exporter.yaml` |
| `quay.io/mittwald/kubernetes-secret-generator:v3.4.1` | 2025-02-04 | 1y 6m 10d | `operators/Deployment:kubernetes-secret-generator` | `application.secret-generator.yaml` |
| `quay.io/mongodb/mongodb-kubernetes-operator-version-upgrade-post-start-hook:1.0.10` | 2025-04-11 | 1y 4m 3d | `hyperdx/StatefulSet:hyperdx` | `hyperdx-mongo.yaml` |
| `quay.io/mongodb/mongodb-kubernetes-readinessprobe:1.0.23` | 2025-04-11 | 1y 4m 3d | `hyperdx/StatefulSet:hyperdx` | `hyperdx-mongo.yaml` |
| `quay.io/mongodb/mongodb-kubernetes-operator:0.13.0` | 2025-04-11 | 1y 4m 3d | `operators/Deployment:mongodb-kubernetes-operator` | `operators/mongodb-community-operator.yaml` |
| `docker.io/prom/snmp-exporter:v0.29.0` | 2025-04-23 | 1y 3m 21d | `monitoring/Deployment:snmp-exporter` | `snmp-exporter.yaml` |
| `ghcr.io/tensorchord/cloudnative-vectorchord:17-0.4.3` | 2025-06-20 | 1y 1m 24d | `immich/Cluster:immich` | `immich/cluster.immich.yaml` |
| `docker.io/mongodb/mongodb-community-server:8.0.4-ubi8` | 2025-07-11 | 1y 1m 3d | `hyperdx/StatefulSet:hyperdx` | `hyperdx-mongo.yaml` |
| `ghcr.io/onedr0p/exportarr:v2.3.0` | 2025-08-12 | 1y 2d | `media/Deployment:prowlarr`<br>`media/Deployment:radarr`<br>`media/Deployment:sonarr` | `prowlarr.yaml`, `radarr.yaml`, `sonarr.yaml` |
| `docker.io/minio/minio:latest` | 2025-09-07 | 11m 7d | `pg-repl/StatefulSet:minio` | not managed in this repo (pg-repl) |
| `registry.apps.nickv.me/democraticcsi/csi-grpc-proxy:v0.5.7` | 2025-10-30 | 9m 15d | `kube-system/DaemonSet:democratic-csi-node`<br>`kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `quay.io/mongodb/mongodb-agent-ubi:108.0.6.8796-1` | 2025-12-06 | 8m 8d | `hyperdx/StatefulSet:hyperdx` | `hyperdx-mongo.yaml` |
| `quay.io/prometheus/blackbox-exporter:v0.28.0` | 2025-12-06 | 8m 8d | `monitoring/Deployment:blackbox-exporter-prometheus-blackbox-exporter` | `application.blackbox-exporter.yaml` |
| `registry.apps.nickv.me/jellyfin:v10.11.5-nv-hdr-patch` | 2026-01-08 | 7m 6d | `media/Deployment:jellyfin` | `jellyfin.yaml` |
| `registry.k8s.io/autoscaling/vpa-recommender:1.6.0` | 2026-02-11 | 6m 3d | `kube-system/Deployment:vpa-recommender` | `application.vendored-vpa.yaml`, `vendored/vpa/base/recommender-deployment.yaml` |
| `registry.k8s.io/etcd:3.6.8-0` | 2026-02-13 | 6m 1d | `kube-system/static-pod:vmubtkube-a0*` | static pod manifest on nodes (not this repo) |
| `ghcr.io/external-secrets/bitwarden-sdk-server:v0.6.0` | 2026-02-20 | 5m 25d | `external-secrets/Deployment:bitwarden-sdk-server` | `application.external-secrets.yaml` |
| `registry.k8s.io/coredns/coredns:v1.14.2` | 2026-03-06 | 5m 8d | `kube-system/Deployment:coredns` | not managed in this repo (kube-system) |
| `registry.k8s.io/external-dns/external-dns:v0.21.0` | 2026-04-06 | 4m 10d | `external-dns/Deployment:external-dns` | `external-dns.yaml` |
| `registry.apps.nickv.me/library/busybox:1.38.0` | 2026-05-13 | 3m 1d | `default/Deployment:searxng`<br>`kube-system/DaemonSet:democratic-csi-node`<br>`kube-system/DaemonSet:iscsi-host-config` | `searxng.yaml`, `application.democratic-csi.yaml`, `iscsi-host-config.yaml` |
| `registry.k8s.io/descheduler/descheduler:v0.36.0` | 2026-05-19 | 2m 26d | `kube-system/CronJob:descheduler` | `descheduler.yaml` |
| `registry.k8s.io/sig-storage/csi-attacher:v4.12.0` | 2026-05-21 | 2m 24d | `kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.17.0` | 2026-05-25 | 2m 20d | `kube-system/DaemonSet:democratic-csi-node` | `application.democratic-csi.yaml` |
| `docker.io/intel/intel-gpu-plugin:0.36.0` | 2026-05-27 | 2m 18d | `kube-system/DaemonSet:intel-gpu-plugin-igpu` | `application.intel-device-plugins-gpu.yaml` |
| `docker.io/intel/intel-deviceplugin-operator:0.36.0` | 2026-05-27 | 2m 18d | `kube-system/Deployment:inteldeviceplugins-controller-manager` | `application.intel-device-plugins-operator.yaml` |
| `registry.k8s.io/sig-storage/snapshot-controller:v8.6.0` | 2026-05-28 | 2m 17d | `kube-system/Deployment:snapshot-controller` | `application.snapshot-controller.yaml` |
| `registry.k8s.io/sig-storage/csi-snapshotter:v8.6.0` | 2026-05-28 | 2m 17d | `kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `registry.k8s.io/sig-storage/csi-resizer:v2.2.0` | 2026-05-28 | 2m 17d | `kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `registry.apps.nickv.me/cpu-benchmark:latest` | 2026-05-30 | 2m 15d | `kube-system/DaemonSet:cpu-benchmark` | `cpu-benchmark.yaml` |
| `registry.k8s.io/sig-storage/csi-provisioner:v6.3.0` | 2026-06-04 | 2m 10d | `kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `docker.io/mikefarah/yq:4` | 2026-06-06 | 2m 8d | `monitoring/Deployment:snmp-exporter` | `snmp-exporter.yaml` |
| `quay.io/backube/volsync:0.16.0` | 2026-06-10 | 2m 4d | `volsync-system/Deployment:volsync` | `application.volsync.yaml` |
| `registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1` | 2026-06-12 | 2m 2d | `monitoring/Deployment:prom-kube-state-metrics` | `application.kube-prometheus.yaml` |
| `docker.io/alpine/k8s:1.36.2` | 2026-06-14 | 2m 0d | `hyperdx/Job:hyperdx-config-render` | `application.hyperdx.yaml` |
| `registry.apps.nickv.me/openresty/openresty:1.31.1.1-alpine` | 2026-06-14 | 2m 0d | `default/Deployment:searxng` | `searxng.yaml` |
| `registry.apps.nickv.me/nijave/cukk:latest` | 2026-06-14 | 2m 0d | `kube-system/Deployment:cukk`<br>`kube-system/Job:cukk-*-upgrade-*` | `cukk.yaml` |
| `ghcr.io/nijave/selfoss:20260601-7fa8a6d` | 2026-06-20 | 1m 24d | `default/Deployment:selfoss` | `selfoss.yaml` |
| `ecr-public.aws.com/docker/library/redis:8.6.4-alpine` | 2026-06-22 | 1m 22d | `argocd/Deployment:argocd-redis` | `application.argocd.yaml` |
| `quay.io/calico/apiserver:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:calico-apiserver` | `application.calico.yaml` |
| `quay.io/calico/cni:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/DaemonSet:calico-node` | `application.calico.yaml` |
| `quay.io/calico/goldmane:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:goldmane` | `application.calico.yaml` |
| `quay.io/calico/kube-controllers:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:calico-kube-controllers` | `application.calico.yaml` |
| `quay.io/calico/node:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/DaemonSet:calico-node` | `application.calico.yaml` |
| `quay.io/calico/pod2daemon-flexvol:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/DaemonSet:calico-node` | `application.calico.yaml` |
| `quay.io/calico/typha:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:calico-typha` | `application.calico.yaml` |
| `quay.io/calico/whisker:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:whisker` | `application.calico.yaml` |
| `quay.io/calico/whisker-backend:v3.32.1` | 2026-06-25 | 1m 19d | `calico-system/Deployment:whisker` | `application.calico.yaml` |
| `quay.io/tigera/operator:v1.42.3` | 2026-06-26 | 1m 18d | `tigera-operator/Deployment:tigera-operator` | `application.calico.yaml` |
| `ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0` | 2026-06-29 | 1m 15d | `cnpg-system/Deployment:cnpg-controller-manager`<br>`default/Cluster:default`<br>`immich/Cluster:immich`<br>`woodpecker/Cluster:woodpecker` | `application.vendored-cnpg.yaml`, `vendored/cnpg/base/cnpg-1.30.0.yaml`, `cluster.default.yaml`, `immich/cluster.immich.yaml`, `woodpecker/cluster.woodpecker.yaml` |
| `ghcr.io/kubereboot/kured:1.23.0` | 2026-06-30 | 1m 14d | `kube-system/DaemonSet:kured` | `kured.yaml` |
| `ghcr.io/nijave/kubelet-rubber-stamp:0.4.0` | 2026-07-03 | 1m 11d | `kube-system/Deployment:kubelet-rubber-stamp` | `application.vendored-kubelet-rubber-stamp.yaml` |
| `registry.apps.nickv.me/searxng/searxng:2026.7.3-c5cd510d8` | 2026-07-03 | 1m 11d | `default/Deployment:searxng` | `searxng.yaml` |
| `quay.io/prometheus/alertmanager:v0.33.1` | 2026-07-04 | 1m 10d | `monitoring/StatefulSet:alertmanager-prom-kp-alertmanager` | `application.kube-prometheus.yaml` |
| `docker.io/library/haproxy:2.4` | 2026-07-06 | 1m 8d | `kube-system/static-pod:vmubtkube-a0*` | static pod manifest on nodes (not this repo) |
| `ghcr.io/puzzle/cert-manager-webhook-dnsimple:v0.1.14` | 2026-07-08 | 1m 6d | `cert-manager/Deployment:cert-manager-webhook-dnsimple` | `application.cert-manager-webhook-dnsimple.yaml` |
| `docker.io/moby/buildkit:v0.32.2-rootless` | 2026-07-09 | 1m 5d | `woodpecker/Deployment:buildkitd` | `woodpecker/buildkit.woodpecker.yaml` |
| `quay.io/prometheus/prometheus:v3.13.1` | 2026-07-10 | 1m 4d | `monitoring/StatefulSet:prometheus-ext` | `prometheus-ext.yaml` |
| `registry.k8s.io/nfd/node-feature-discovery:v0.19.0` | 2026-07-10 | 1m 4d | `kube-system/DaemonSet:node-feature-discovery-worker`<br>`kube-system/Deployment:node-feature-discovery-gc`<br>`kube-system/Deployment:node-feature-discovery-master` | `application.nfd.yaml` |
| `docker.io/library/memcached:1.6-alpine` | 2026-07-10 | 1m 4d | `thanos/Deployment:caching-bucket-memcached`<br>`thanos/Deployment:index-cache-memcached` | `application.thanos-caching-bucket.yaml`, `application.thanos-index-cache.yaml` |
| `registry.k8s.io/metrics-server/metrics-server:v0.9.0` | 2026-07-13 | 1m 1d | `kube-system/Deployment:metrics-server` | `application.metrics-server.yaml` |
| `quay.io/prometheus/node-exporter:v1.12.1-distroless` | 2026-07-14 | 1m 0d | `monitoring/DaemonSet:prom-prometheus-node-exporter` | `application.kube-prometheus.yaml` |
| `registry.apps.nickv.me/envoyproxy/envoy:v1.39.0` | 2026-07-14 | 1m 0d | `projectcontour/DaemonSet:envoy` | `application.vendored-contour.yaml`, `vendored/contour/patch-envoy-daemonset.yaml` |
| `docker.io/valkey/valkey@sha256:ee91f7a174ac4d6a6b0685b3a60e321f0a9dbbb691f9b0e285be2ba1d1be8328` | 2026-07-22 | 23d | `immich/Deployment:immich-valkey` | `immich/application.immich.yaml` |
| `registry.k8s.io/kube-proxy:v1.36.3` | 2026-07-22 | 23d | `kube-system/DaemonSet:kube-proxy` | not managed in this repo (kube-system) |
| `registry.k8s.io/kube-scheduler:v1.36.3` | 2026-07-22 | 23d | `kube-system/static-pod:vmubtkube-a0*` | static pod manifest on nodes (not this repo) |
| `registry.k8s.io/kube-controller-manager:v1.36.3` | 2026-07-22 | 23d | `kube-system/static-pod:vmubtkube-a0*` | static pod manifest on nodes (not this repo) |
| `registry.k8s.io/kube-apiserver:v1.36.3` | 2026-07-22 | 23d | `kube-system/static-pod:vmubtkube-a0*` | static pod manifest on nodes (not this repo) |
| `ghcr.io/nijave/otel-agent-trace-connector:v0.1.0` | 2026-07-26 | 19d | `monitoring/Deployment:otel-agent-trace-connector` | `otel-agent-trace-connector.yaml` |
| `docker.io/mumblevoip/mumble-server:v1.6.870` | 2026-07-27 | 18d | `default/Deployment:mumble` | `mumble.yaml` |
| `docker.hyperdx.io/hyperdx/hyperdx:2.32.0` | 2026-07-27 | 18d | `hyperdx/Deployment:hyperdx-clickstack-app` | `application.hyperdx.yaml` |
| `docker.clickhouse.com/clickhouse/clickstack-otel-collector:2.32.0` | 2026-07-27 | 18d | `hyperdx/Deployment:hyperdx-otel-collector` | `application.hyperdx.yaml` |
| `ghcr.io/immich-app/immich-machine-learning:v3.1.0-openvino` | 2026-07-27 | 18d | `immich/Deployment:immich-machine-learning` | `immich/application.immich.yaml` |
| `quay.io/prometheus-operator/prometheus-operator:v0.93.0` | 2026-07-28 | 17d | `monitoring/Deployment:prom-kp-operator` | `application.kube-prometheus.yaml` |
| `quay.io/prometheus-operator/prometheus-config-reloader:v0.93.0` | 2026-07-28 | 17d | `monitoring/StatefulSet:alertmanager-prom-kp-alertmanager`<br>`monitoring/StatefulSet:prometheus-ext`<br>`monitoring/StatefulSet:prometheus-prom-kp-prometheus` | `application.kube-prometheus.yaml`, `prometheus-ext.yaml` |
| `ghcr.io/cloudnative-pg/plugin-barman-cloud:v0.14.0` | 2026-07-29 | 16d | `cnpg-system/Deployment:barman-cloud` | `application.vendored-barman-cloud-plugin.yaml`, `vendored/barman-cloud-plugin/base/manifest.yaml` |
| `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar:v0.14.0` | 2026-07-29 | 16d | `default/Cluster:default`<br>`immich/Cluster:immich`<br>`woodpecker/Cluster:woodpecker` | `cluster.default.yaml`, `immich/cluster.immich.yaml`, `woodpecker/cluster.woodpecker.yaml` |
| `quay.io/jetstack/cert-manager-webhook:v1.21.1` | 2026-07-29 | 16d | `cert-manager/Deployment:cert-manager-webhook` | `application.vendored-cert-manager.yaml` |
| `quay.io/jetstack/cert-manager-cainjector:v1.21.1` | 2026-07-29 | 16d | `cert-manager/Deployment:cert-manager-cainjector` | `application.vendored-cert-manager.yaml` |
| `quay.io/jetstack/cert-manager-controller:v1.21.1` | 2026-07-29 | 16d | `cert-manager/Deployment:cert-manager` | `application.vendored-cert-manager.yaml` |
| `ghcr.io/immich-app/immich-server:v3.1.0` | 2026-07-29 | 16d | `immich/Deployment:immich-server` | `immich/application.immich.yaml` |
| `quay.io/prometheus/prometheus:v3.13.2-distroless` | 2026-07-30 | 15d | `monitoring/StatefulSet:prometheus-prom-kp-prometheus` | `application.kube-prometheus.yaml` |
| `registry.apps.nickv.me/thanos/thanos:v0.42.4` | 2026-07-30 | 15d | `thanos/Deployment:thanos-query`<br>`thanos/Deployment:thanos-receive-router`<br>`thanos/StatefulSet:thanos-compact`<br>`thanos/StatefulSet:thanos-receive-ingestor-default`<br>`thanos/StatefulSet:thanos-store` | `thanos/thanos-query-deployment.yaml`, `thanos/thanos-receive-router-deployment.yaml`, `thanos/thanos-compact-statefulSet.yaml`, `thanos/thanos-receive-ingestor-default-statefulSet.yaml`, `thanos/thanos-store-statefulSet.yaml` |
| `docker.io/percona/mongodb_exporter:0.52.0` | 2026-07-30 | 15d | `hyperdx/StatefulSet:hyperdx` | `hyperdx-mongo.yaml` |
| `docker.io/woodpeckerci/woodpecker-agent:v3.17.0` | 2026-07-31 | 14d | `woodpecker/StatefulSet:woodpecker-agent` | `woodpecker/application.woodpecker.yaml` |
| `docker.io/woodpeckerci/woodpecker-server:v3.17.0` | 2026-07-31 | 14d | `woodpecker/StatefulSet:woodpecker-server` | `woodpecker/application.woodpecker.yaml` |
| `registry.apps.nickv.me/nijave/homelab-pki:0.2.5` | 2026-08-02 | 12d | `homelab-pki/CronJob:pki-crl-refresh`<br>`homelab-pki/Job:pki-reconcile` | `homelab-pki.yaml` |
| `lscr.io/linuxserver/radarr@sha256:a45b5ab0f850f39edb4cc9c95bbd967b52ddc3d4574a4dfb45561177db6c88f4` | 2026-08-02 | 12d | `media/Deployment:radarr` | `radarr.yaml` |
| `quay.io/kiwigrid/k8s-sidecar:2.10.1` | 2026-08-04 | 10d | `monitoring/StatefulSet:prom-grafana` | `application.kube-prometheus.yaml` |
| `docker.io/clickhouse/clickhouse-server:26.5-alpine` | 2026-08-04 | 10d | `hyperdx/StatefulSet:chi-hyperdx-replicated-0-*` | `hyperdx-clickhouse.yaml` |
| `docker.io/clickhouse/clickhouse-keeper:26.5-alpine` | 2026-08-04 | 10d | `hyperdx/StatefulSet:chk-hyperdx-keeper-0-*` | `hyperdx-clickhouse.yaml` |
| `registry.apps.nickv.me/vikunja/vikunja:2.5.0` | 2026-08-04 | 10d | `default/Deployment:vikunja` | `application.vikunja.yaml` |
| `docker.io/otel/opentelemetry-collector-k8s:0.158.0` | 2026-08-04 | 10d | `monitoring/DaemonSet:otel-logs-opentelemetry-collector-agent`<br>`projectcontour/Deployment:otel-collector` | `application.otel-logs-daemonset.yaml`, `application.otel-collector-contour.yaml` |
| `docker.io/otel/opentelemetry-collector-contrib:0.158.0` | 2026-08-04 | 10d | `monitoring/Deployment:otel-collector-opentelemetry-collector` | `application.otel-collector.yaml` |
| `lscr.io/linuxserver/prowlarr@sha256:1295cff29d10b486c0d8324d1559a552140a5932bf8b3d87e398654414f63f92` | 2026-08-05 | 9d | `media/Deployment:prowlarr` | `prowlarr.yaml` |
| `cr.fluentbit.io/fluent/fluent-bit:5.1` | 2026-08-05 | 8d | `monitoring/DaemonSet:fluent-bit-journald` | `fluentbit/journald-daemonset.yaml`, `application.fluentbit.yaml` |
| `docker.io/clickhouse/clickhouse-server:26.7-alpine` | 2026-08-06 | 8d | `hyperdx/Job:clickhouse-schema-seed` | `hyperdx-clickhouse.yaml` |
| `docker.io/grafana/grafana:13.1.3` | 2026-08-07 | 7d | `monitoring/StatefulSet:prom-grafana` | `application.kube-prometheus.yaml` |
| `ghcr.io/stakater/reloader:v1.4.21` | 2026-08-07 | 7d | `default/Deployment:reloader-reloader` | `reloader.yaml` |
| `ghcr.io/external-secrets/external-secrets:v2.9.0` | 2026-08-07 | 7d | `external-secrets/Deployment:external-secrets`<br>`external-secrets/Deployment:external-secrets-webhook` | `application.external-secrets.yaml` |
| `lscr.io/linuxserver/sonarr@sha256:373159ba768e23a3a1c497d9f2b936addf8fd5b1fdce7dd6a14080ac928bfda0` | 2026-08-07 | 6d | `media/Deployment:sonarr` | `sonarr.yaml` |
| `registry.apps.nickv.me/democratic-csi/democratic-csi:390742a` | 2026-08-08 | 6d | `kube-system/DaemonSet:democratic-csi-node`<br>`kube-system/Deployment:democratic-csi-controller` | `application.democratic-csi.yaml` |
| `ghcr.io/oliver006/redis_exporter:v1.89.0` | 2026-08-09 | 5d | `argocd/Deployment:argocd-redis` | `application.argocd.yaml` |
| `registry.access.redhat.com/ubi8/ubi-minimal:latest` | 2026-08-10 | 4d | `hyperdx/StatefulSet:chi-hyperdx-replicated-0-*` | `hyperdx-clickhouse.yaml` |
| `lscr.io/linuxserver/sabnzbd@sha256:b0f9755d795913bd26ae3f3a12805668ab0681ab847a7624568559c573fc7cae` | 2026-08-10 | 4d | `media/Deployment:sabnzbd` | `sabnzbd.yaml` |
| `quay.io/prometheus-operator/prometheus-config-reloader:v0.93.1` | 2026-08-10 | 4d | `monitoring/Deployment:blackbox-exporter-prometheus-blackbox-exporter` | `application.blackbox-exporter.yaml` |
| `registry.apps.nickv.me/nijave/python-envoy-authz:latest` | 2026-08-10 | 4d | `projectcontour/Deployment:python-envoy-authz` | `python-envoy-authz.yaml` |
| `quay.io/observatorium/thanos-receive-controller:main-2026-08-11-d9455c0` | 2026-08-11 | 3d | `thanos/Deployment:thanos-receive-controller` | `thanos/thanos-receive-controller-deploy.yaml` |
| `docker.io/altinity/clickhouse-operator:0.27.3` | 2026-08-12 | 2d | `operators/Deployment:clickhouse-operator-altinity-clickhouse-operator` | `operators/clickhouse-operator.yaml` |
| `docker.io/altinity/metrics-exporter:0.27.3` | 2026-08-12 | 2d | `operators/Deployment:clickhouse-operator-altinity-clickhouse-operator` | `operators/clickhouse-operator.yaml` |
| `quay.io/argoproj/argocd:v3.5.1` | 2026-08-12 | 2d | `argocd/Deployment:argocd-notifications-controller`<br>`argocd/Deployment:argocd-repo-server`<br>`argocd/Deployment:argocd-server`<br>`argocd/StatefulSet:argocd-application-controller` | `application.argocd.yaml` |
| `ghcr.io/projectcontour/contour:v1.33.6` | 2026-08-12 | 2d | `projectcontour/DaemonSet:envoy`<br>`projectcontour/Deployment:contour` | `application.vendored-contour.yaml`, `vendored/contour/patch-envoy-daemonset.yaml`, `vendored/contour/patch-contour-deployment.yaml` |
| `ghcr.io/cloudnative-pg/postgresql:18.6` | 2026-08-13 | 1d | `default/Cluster:default`<br>`woodpecker/Cluster:woodpecker` | `cluster.default.yaml`, `woodpecker/cluster.woodpecker.yaml` |
| `docker.io/library/postgres:16` | 2026-08-13 | 1d | `pg-repl/StatefulSet:postgres` | not managed in this repo (pg-repl) |
| `ghcr.io/metacontroller/metacontroller:v4.17.2` | 2026-08-13 | 0d | `operators/StatefulSet:metacontroller-metacontroller-helm` | `application.metacontroller.yaml` |
| `registry.apps.nickv.me/cloudflare/cloudflared:2026.8.2` | 2026-08-14 | 0d | `default/Deployment:cloudflared-deployment` | `cloudflared.yaml` |
| `docker.io/prom/memcached-exporter:v0.17.0` | 2026-08-14 | 0d | `thanos/Deployment:caching-bucket-memcached`<br>`thanos/Deployment:index-cache-memcached` | `application.thanos-caching-bucket.yaml`, `application.thanos-index-cache.yaml` |

## Caveats

- `registry.k8s.io/external-dns/external-dns:v0.21.0`: the image config
  reports epoch (1970-01-01), a reproducible-build convention. This report
  substitutes the GitHub release date (2026-04-06).
- `quay.io/tigera/operator:v1.42.3`: uses quay's tag-push timestamp
  (2026-06-26) rather than the config build date.
- Rolling tags (`postgres:16`, `haproxy:2.4`, `memcached:1.6-alpine`,
  `clickhouse:*-alpine`, `yq:4`, `fluent-bit:5.1`, all `latest`, etc.) show
  the build behind the tag at report time; a redeploy would pull something
  newer.
- Digest-pinned entries (valkey, the lscr.io *arrs) show the build of the
  exact digest running.
- Static pods (`kube-apiserver`, `etcd`, `kube-controller-manager`,
  `kube-scheduler`, `haproxy`) plus `kube-proxy` and `coredns` are
  kubeadm/node-managed and have no manifest in this repo.
- The `pg-repl` namespace (postgres, minio StatefulSets) is not managed in
  this repo.
