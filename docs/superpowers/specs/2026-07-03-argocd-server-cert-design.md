# ArgoCD server certificate via Let's Encrypt (dnsimple DNS-01)

Date: 2026-07-03

## Problem

argocd-server serves a self-signed certificate that was silently regenerated
when `argocd-secret` was recreated during the Helm→ArgoCD migration
(2026-07-02). Direct access at `argocd.k8s.somemissing.info` (routable
ServiceIP, external-dns annotation already on the `argocd-server` Service)
gets a browser warning.

## Decision

One `Certificate` in the `argocd` namespace, matching the repo's established
pattern for browser-facing services (grafana, woodpecker, otel-collector):

- `secretName: argocd-server-tls` — ArgoCD's supported serving-cert override;
  argocd-server watches this secret and hot-reloads it, replacing the
  self-signed cert from `argocd-secret`. No restart, no Contour changes.
- `issuerRef: ClusterIssuer cert-manager-webhook-dnsimple-production` —
  Let's Encrypt via DNS-01.
- `dnsNames`: `argocd.k8s.somemissing.info` (direct/LAN access) and
  `argocd.apps.somemissing.info` (also valid if the public FQDN hits the pod
  directly). In-cluster `*.svc` names are omitted — a public CA can't issue
  them.

Lives in `proxy_argocd_webhook.yaml` next to the other ArgoCD TLS resources.

## Alternatives considered

- **Private `k8s` CA** (exists in `clusterissuer.yaml`): rejected — it serves
  as an internal service CA (only consumer: `python-envoy-authz`), and every
  other `*.k8s.somemissing.info` UI uses publicly-trusted certs; a private
  root would require trusting `k8s-ca` on every client device.
- **Wildcard cert at Contour**: rejected in favor of the serving-cert
  override; the webhook HTTPProxy keeps its existing edge cert.

## DNS zone conventions (documented in README)

- `*.apps.somemissing.info` — internet-facing services.
- `*.k8s.somemissing.info` — internal/LAN services (routable ServiceIPs via
  external-dns; not reachable from the internet).

Both zones get publicly-trusted Let's Encrypt certs through the
`cert-manager-webhook-dnsimple-production` ClusterIssuer (DNS-01 has no
reachability requirement, so internal-only hostnames work fine).

## Verification

- Certificate becomes Ready; secret `argocd-server-tls` created.
- `openssl s_client -connect argocd.k8s.somemissing.info:443` shows a Let's
  Encrypt issuer and both SANs.
- GitHub webhook delivery still returns 200; UI still reachable.
