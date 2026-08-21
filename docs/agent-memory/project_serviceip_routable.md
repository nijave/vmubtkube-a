---
name: ServiceIPs are routable outside the cluster
description: In vmubtkube-a, ClusterIPs are routable from outside; external-dns publishes a DNS record pointing at the ServiceIP, so no LoadBalancer/Ingress is required to expose a service externally
type: project
originSessionId: 270a1ef9-b123-461b-ac04-d744a7ea0d41
---
In this cluster, the Kubernetes Service network is routable from outside the cluster. Services are exposed externally by adding an `external-dns.alpha.kubernetes.io/hostname: <fqdn>` annotation to a plain `ClusterIP` Service — external-dns publishes a DNS record (typical zone: `k8s.somemissing.info`) pointing at the ServiceIP, and external clients hit it directly.

**Why:** The cluster's Service CIDR is routable on the surrounding network, so LoadBalancer/Ingress isn't needed for L4 exposure. Many existing services (e.g. `sonarr.yaml`, `prowlarr.yaml`, `application.otel-collector.yaml`) already use this pattern.

**How to apply:** When the user asks to "expose" a Service externally, default to ClusterIP + `external-dns.kubernetes.io/hostname` annotation. Do not propose LoadBalancer, NodePort, or Ingress/HTTPProxy unless the user specifically wants L7 features (TLS termination, host/path routing, auth) — and even then, ask first.

**Caveat (2026-08-20 incident, resolved 2026-08-21):** external-dns v0.22
switched its default annotation prefix to the GA `external-dns.kubernetes.io/`;
these services still used the alpha prefix, so the service source produced an
empty desired set and sync deleted every service-sourced record it owned
(~35 records; PRs #459/#460 recovered). All services now carry the GA
`external-dns.kubernetes.io/hostname` key, and the deployment pins
`--annotation-prefix=external-dns.kubernetes.io/` explicitly (migration: #461
staged the GA keys, #464 flipped the flag, this PR removed the alpha keys).
Annotate new Services with the GA key, and keep the flag explicit so a future
default change cannot silently empty the desired set again.
