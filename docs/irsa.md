# IRSA (IAM Roles for Service Accounts) — cluster conventions

AWS credentials for in-cluster workloads are granted through IRSA: IAM roles
federated via the OIDC provider `oidc-k8s.apps.somemissing.info` (registered by
IaC in the dnsimple tofu repo, `oidc.tf` / `irsa.tf`). No long-lived IAM access
keys are issued for workloads; no pod-identity webhook is installed.

## Why there is no pod-identity webhook

`amazon-eks-pod-identity-webhook` is the standard IRSA injection mechanism
outside EKS, but it was deliberately **not installed** (decision 2026-09-21):

- Only two workloads consume AWS credentials, and neither needs it (see below).
- This is a locally-run, mostly bare-metal cluster; no growth in AWS consumers
  is expected.
- The webhook brings a Deployment + MutatingWebhookConfiguration + TLS cert
  lifecycle for what amounts to two static env vars and a projected token.

If a third consumer needs ambient AWS credentials, revisit installing it
(chart `amazon-eks-pod-identity-webhook`, repo `https://aws.github.io/eks-charts`).

## Consumers

| workload | IAM role (tofu `irsa.tf`) | how credentials reach the pod |
|---|---|---|
| `external-dns/route53-ddns` CronJob | `k8s-external-dns` | pod sets `AWS_ROLE_ARN` + `AWS_WEB_IDENTITY_TOKEN_FILE` pointing at a projected ServiceAccount token volume (`audience: sts.amazonaws.com`); AWS CLI v2 credential chain does the `AssumeRoleWithWebIdentity` exchange |
| cert-manager | `k8s-cert-manager` | none — the Route53 solver uses cert-manager's "IAM Role with dedicated Kubernetes ServiceAccount" mode: dedicated un-annotated SA `k8s-cert-manager`, RBAC Role/RoleBinding for `serviceaccounts/token`, and `route53.role` + `auth.kubernetes.serviceAccountRef` on the ClusterIssuers |

## IAM side (owned by the dnsimple tofu repo)

- `aws_iam_openid_connect_provider.homelab_k8s` — the issuer (`oidc.tf`).
- `aws_iam_role.k8s_external_dns` / `aws_iam_role.k8s_cert_manager` — trust
  policies pin `sub` to `system:serviceaccount:<ns>:<sa>` and `aud` to
  `sts.amazonaws.com`; policies are **inline**, taken from the upstream
  reference docs:
  - external-dns: `docs/tutorials/aws.md` IAM policy (zone-scoped to nickv.me;
    add its `ListHostedZones`/`ListTagsForResources` statements if external-dns
    itself ever adopts the role)
  - cert-manager: route53 DNS01 page policy (TXT-only change condition,
    zone-scoped to the five domains)
- Zone ids referenced there must match `tofu output zone_ids` — update both if
  zones are ever recreated.

## Adding a new AWS consumer

1. Add (or extend) a role in the tofu repo `irsa.tf`, trusting the existing
   OIDC provider with `sub: system:serviceaccount:<ns>:<sa>`,
   `aud: sts.amazonaws.com`; inline policy per the consuming tool's official
   docs, scoped to the resources it needs.
2. In the pod spec (no webhook): set `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`,
   and mount a projected ServiceAccount token with `audience: sts.amazonaws.com`.
3. Verify with a one-off pod: `aws sts get-caller-identity` should return
   `role/<name>`.
