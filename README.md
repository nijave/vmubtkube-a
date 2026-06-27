# vmubtkube-a

ArgoCD root app for the `vmubtkube-a` cluster. Everything in this repo is
applied by the `vmubtkube-a` Application (`application.vmubtkube-a.yaml`),
which prunes and self-heals via ServerSideApply.

## Secret management

Two mechanisms are available; pick by **where the secret originates**, not by
what kind of thing it is:

### 1. In-cluster generation (preferred for in-cluster-only credentials)

Credentials that exist solely to satisfy an in-cluster service — database
passwords, app admin passwords, inter-service tokens that nothing outside the
cluster ever needs — should be **auto-generated in the cluster** by the
[mittwald kubernetes-secret-generator](https://github.com/mittwald/kubernetes-secret-generator)
(installed in `operators`, see `application.secret-generator.yaml`).

Declare the Secret empty in git with the trigger annotation; the controller
fills `data.password` with a random string on first sync:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: example-password
  namespace: default
  annotations:
    secret-generator.mittwald.de/secret-type: password
    secret-generator.mittwald.de/password-length: "32"
type: Opaque
```

Why prefer this:

- Nothing to pre-create or rotate by hand — the value is generated once and
  persisted in-cluster.
- No secret material in git, and no dependency on the external store for
  bootstrapping.
- Under ServerSideApply the controller owns the `data` field, so ArgoCD
  self-heal won't clobber it. (Rotate by deleting/regenerating the Secret; the
  consuming workload restarts via Reloader.)

See `mumble.yaml` for a working example.

### 2. Bitwarden + ExternalSecrets (for off-platform-originated secrets)

[External Secrets Operator](https://external-secrets.io) (installed via
`application.external-secrets.yaml`) syncing from the Bitwarden-backed
`ClusterSecretStore` named `default` is primarily for secrets whose value is
**defined off-platform** — third-party API tokens, upstream service
credentials, pre-existing accounts whose password can't be invented here. The
source of truth is Bitwarden, and the cluster reflects it.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: example-config
  namespace: default
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    name: example-config
  data:
  - secretKey: api-token
    remoteRef:
      key: example-api-token
```

See `selfoss.yaml` for a working example.

### When a literal value is committed

Occasionally a secret is intentionally checked into git because there is no
sensible off-platform source and no in-cluster generator (e.g. an opaque key
the receiver doesn't even enforce). That should be rare and always accompanied
by a note in `docs/` explaining why — see `docs/hyperdx-api-key.md`.
