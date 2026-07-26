# Vikunja mTLS→OAuth2 Federation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put Vikunja behind the Contour mTLS edge and turn on `python-envoy-authz`'s mTLS→OAuth2 federation, so a client certificate transparently authenticates a Vikunja user and nothing can reach Vikunja except through that gate.

**Architecture:** Contour terminates client-cert mTLS on `vikunja.apps.somemissing.info` and calls the existing `python-envoy-authz` ext_authz service, which derives a stable subject from the client cert, mints an OAuth2 auth code from its own in-process OP, POSTs it to Vikunja's OpenID callback, and injects the resulting `Authorization: Bearer` upstream. Vikunja redeems the code back against the OP over an in-cluster HTTPS Service using a cert from the private `k8s` ClusterIssuer. A Calico NetworkPolicy closes the current LAN-routable ClusterIP bypass so the mTLS gate cannot be sidestepped. Contour→Vikunja and authz→Vikunja stay plaintext on the pod network (Vikunja cannot terminate operator-supplied TLS, and the federator's HTTP client cannot verify a private CA — see Global Constraints).

**Tech Stack:** ArgoCD (auto-sync, prune, selfHeal, ServerSideApply) · Contour HTTPProxy + ExtensionService · cert-manager (`k8s` ClusterIssuer for internal, `cert-manager-webhook-dnsimple-production` for edge) · external-secrets (Bitwarden `ClusterSecretStore default` + kubernetes provider) · mittwald secret-generator · Calico (iptables dataplane) · `registry.apps.nickv.me/nijave/python-envoy-authz:latest`

## Global Constraints

- **Every change lands via PR to `main`.** ArgoCD `vmubtkube-a` has `automated.prune: true` and `selfHeal: true` — a manual `kubectl apply`/`edit` is reverted on the next sync. Verification happens *after* the merge syncs. Force a sync with `kubectl -n argocd annotate app vmubtkube-a argocd.argoproj.io/refresh=hard --overwrite`.
- **Pre-merge validation is `.ci/validate.sh`** (kubeconform strict) — the same check CI runs; `pre-commit` runs it per commit.
- **Prerequisite:** PR #309 (`feat/authz-otel-and-http-port`) must be merged first. It adds the container port 5001 and the Service `http` port that Task 1 builds on.
- **Federation is all-or-nothing and opt-in:** it activates only when `IDP_ISSUER`, `SECRET_KEY` **and** `PROVIDERS_FILE` are all set. Any one missing → the service logs `Federation disabled …` and runs as the mTLS + Frigate gate only.
- **`providers.yaml` comes from inside the image** at `/app/envoy_authz/providers.yaml`; every field is `${VAR}`-interpolated. No ConfigMap. `PROVIDERS_FILE=/app/envoy_authz/providers.yaml`.
- **In `providers.yaml` interpolation, unset *or empty* is fatal when there's no default.** `VIKUNJA_CLIENT_SECRET` has no default: an empty value crash-loops the pod, which also takes down the Frigate and Home Assistant mTLS paths. Never point it at a possibly-empty key.
- **`VIKUNJA_HOST` mismatches fail silently** — the request is allowed through with no header injected. A silent no-op, not an error.
- **The OP key Secret must be mounted `defaultMode: 0600`.** `keys.load_or_create_key` calls `os.chmod` on any file with group/other bits before reading; on a read-only Secret mount that raises `PermissionError` and the process exits before binding a listener. Mode `0600` skips the chmod entirely.
- **`SECRET_KEY` and the OP RSA key must be byte-identical across replicas and stable across restarts.** `kid` is the RFC 7638 thumbprint of the key, so per-pod keys make JWKS from replica A fail to verify a token signed by replica B.
- **Known accepted limitation (replicas: 2):** the OP's `TOKENS`/`REFRESH_TOKENS`, the single-use `_used_code_jtis` replay table, and the federator `SessionCache` are per-process dicts. Auth codes are stateless (signed with the shared `SECRET_KEY`) so redemption works on either replica; single-use enforcement and OP refresh-token rotation are per-pod. Vikunja manages its own user tokens, so this is acceptable — do not "fix" it by dropping to one replica (the PDB `minAvailable: 1` would then block node drains).
- **Vikunja cannot serve operator-supplied TLS.** Its only HTTPS option is automatic Let's Encrypt (`vikunja.io/docs/config-options/`), and the vendored chart has no TLS values. Hence plaintext upstream + NetworkPolicy.
- **The federator cannot verify a private CA when calling Vikunja.** `httpx.Client(base_url=provider.api_base, …)` is built with no `verify=`/custom CA, so `VIKUNJA_API_BASE` must stay `http://`. An HTTPS internal-CA base URL surfaces as `DownstreamError(retryable=True)` → Check denies 503.
- **Verified on this cluster (2026-07-26): a NetworkPolicy ingress rule does not break kubelet `httpGet` probes.** With a deny-all-ingress policy, a probed pod stayed `1/1 Ready` while cross-namespace pod-to-pod traffic to it timed out. `hostEndpoint.autoCreate: Disabled` (`application.calico.yaml:120-122`) is why host-originated traffic is unfiltered. No probe exemption rule is needed.
- **Do not add `optionalClientCertificate: true`** to the Vikunja HTTPProxy. The Frigate/HA proxies use it; here a client cert is mandatory.
- **Contour ext_authz fails closed** (`failOpen` unset → false). If `python-envoy-authz` is unavailable, Vikunja returns 503. That is intended.
- **Every mTLS client cert used against Vikunja must carry an `rfc822Name` (email) SAN.** Without it the federator raises before any HTTP call: `client certificate has no email (rfc822Name SAN); cannot provision a downstream user`.
- Preserve unrelated working-tree changes (`gluetun-poc.yaml`, `qds.yaml` are untracked and must stay untracked). Stage explicit paths; never blanket `git add`.

---

## Canonical values

Every task uses these exact strings. They must agree across `python-envoy-authz.yaml` and `application.vikunja.yaml` or code redemption fails.

| Thing | Value |
|---|---|
| Edge FQDN (Envoy request host) | `vikunja.apps.somemissing.info` |
| OP issuer (`IDP_ISSUER`, Vikunja `AUTHURL`) | `https://python-envoy-authz-op.projectcontour.svc.cluster.local` |
| OP Service | `python-envoy-authz-op` in `projectcontour`, port `443` → targetPort `5001` |
| `VIKUNJA_API_BASE` (federator → Vikunja) | `http://vikunja.default.svc.cluster.local` |
| `VIKUNJA_REDIRECT_URL` | `https://vikunja.apps.somemissing.info/auth/openid/broker` |
| `VIKUNJA_PROVIDER_KEY` / Vikunja provider id | `broker` |
| `VIKUNJA_CLIENT_ID` / Vikunja `CLIENTID` | `vikunja` (providers.yaml default; not set explicitly) |
| `CODE_TTL_SECONDS` | `30` (default 10 is too tight — see Task 5) |
| `OP_KEY_PATH` | `/var/lib/op-key/op_key.pem` |
| Vikunja `service.publicurl` | `https://vikunja.apps.somemissing.info` |

Verification commands throughout use `$CLIENT_CERT` / `$CLIENT_KEY`. Export them once to the existing homelab client certificate and key — the same pair already used against `ha.apps.somemissing.info` and `frigate.apps.somemissing.info`, signed by the CA in the `ca-ha.apps.somemissing.info` Bitwarden item. The cert **must** carry an `rfc822Name` (email) SAN; check with `openssl x509 -in "$CLIENT_CERT" -noout -text | rg -A1 "Subject Alternative Name"`.

Must-match pairs: `IDP_ISSUER` == Vikunja `..._BROKER_AUTHURL`; `VIKUNJA_CLIENT_SECRET` == Vikunja `..._BROKER_CLIENTSECRET`; `VIKUNJA_SESSION_SECRET` == Vikunja `VIKUNJA_SERVICE_SECRET`; `VIKUNJA_PROVIDER_KEY` == the `BROKER` segment of Vikunja's env names == the `/auth/openid/<key>` path segment in `VIKUNJA_REDIRECT_URL`.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `python-envoy-authz.yaml` (modify) | authz Deployment/Service/Certificate/ExtensionService/PDB; gains the OP Service, extra cert SANs, OP key + secret plumbing, federation env | 1, 2, 5, 7 |
| `proxy_vikunja_apps_somemissing_info.yaml` (create) | Vikunja edge: LE `Certificate` + `HTTPProxy` (mTLS clientValidation + ext_authz) + `NetworkPolicy` | 3, 4 |
| `application.vikunja.yaml` (modify) | Vikunja chart values: `publicurl`, OIDC provider env, CA-trust mount, drop the LAN external-dns annotation | 3, 4, 6 |
| `vikunja.yaml` (modify) | Vikunja-adjacent cluster objects in `default`: shared-secret ExternalSecrets + the `k8s-ca` copy (SecretStore/SA/RBAC) | 2 |
| `README.md` (modify) | Document the federation topology alongside the existing mTLS/DNS sections | 8 |

Placement rationale: this repo keeps one file per concern at the root, `proxy_*.yaml` per fronted service (`proxy_homeassistant.yaml`, `proxy_frigate_apps_somemissing_info.yaml`), and puts Vikunja-adjacent non-chart objects in `vikunja.yaml`. Renovate's `kubernetes` manager matches `python-envoy-authz.yaml` by name (`renovate.json:44`) and the image is in `ignoreDeps`, so no Renovate config change is needed. A new `proxy_*.yaml` needs no Renovate entry (no images).

---

### Task 1: OP listener Service and certificate SANs

Gives the OP a well-known-port in-cluster endpoint whose hostname is covered by the `k8s`-issued cert. No behavior change: federation is still off, so the OP router isn't mounted and only `/healthz` answers.

**Files:**
- Modify: `python-envoy-authz.yaml` (Certificate `dnsNames` ~line 151-165; add a second Service after the existing one ~line 138-148)

**Interfaces:**
- Consumes: the container port `5001` and Service `http` port added by PR #309.
- Produces: Service `python-envoy-authz-op.projectcontour:443` → 5001, with cert SAN `python-envoy-authz-op.projectcontour.svc.cluster.local`. Task 5 sets `IDP_ISSUER` to `https://python-envoy-authz-op.projectcontour.svc.cluster.local`; Task 6 points Vikunja's `AUTHURL` at the same string.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
kubectl -n projectcontour get svc python-envoy-authz-op
```

Expected now: `Error from server (NotFound): services "python-envoy-authz-op" not found`

- [ ] **Step 2: Add the OP Service**

In `python-envoy-authz.yaml`, directly after the existing `Service/python-envoy-authz` document, add:

```yaml
---
# Second Service so the OP is reachable on a well-known port: IDP_ISSUER needs
# no :port suffix, and every URL in the discovery document inherits it. The
# primary Service's 443 is taken by the ext_authz gRPC listener, and a Service
# port can only map to one targetPort, hence a separate object rather than
# another port on the existing one.
apiVersion: v1
kind: Service
metadata:
  name: python-envoy-authz-op
  namespace: projectcontour
spec:
  type: ClusterIP
  internalTrafficPolicy: Cluster
  ports:
    - name: https
      port: 443
      protocol: TCP
      targetPort: 5001
  selector:
    app: python-envoy-authz
```

- [ ] **Step 3: Add the OP hostnames to the certificate**

Both listeners share `TLS_CERT_PATH`/`TLS_KEY_PATH`, so this one cert must cover the gRPC name Envoy dials *and* the issuer hostname Vikunja dials. Replace the `dnsNames` list on the `Certificate/python-envoy-authz`:

```yaml
  dnsNames:
    - python-envoy-authz
    - python-envoy-authz.projectcontour
    - python-envoy-authz.projectcontour.svc.cluster.local.
    # OP listener names. IDP_ISSUER uses the no-trailing-dot FQDN, which is
    # listed verbatim so hostname verification cannot depend on how a client
    # normalizes the root label.
    - python-envoy-authz-op
    - python-envoy-authz-op.projectcontour
    - python-envoy-authz-op.projectcontour.svc.cluster.local
```

Do not touch `ExtensionService.validation.subjectName` — it stays `python-envoy-authz`, matching the first SAN.

- [ ] **Step 4: Validate locally**

```bash
.ci/validate.sh 2>&1 | tail -3
kubectl apply --server-side --dry-run=server --force-conflicts -f python-envoy-authz.yaml
```

Expected: `All manifests valid.` and 8 objects `serverside-applied (server dry run)`.

- [ ] **Step 5: Commit, PR, merge**

```bash
git add python-envoy-authz.yaml
git commit -m "feat(python-envoy-authz): add OP listener Service and certificate SANs"
```

- [ ] **Step 6: Verify after ArgoCD syncs**

```bash
kubectl -n projectcontour get svc python-envoy-authz-op
# cert-manager must reissue with the new SANs before the pods pick them up:
kubectl -n projectcontour get certificate python-envoy-authz -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
kubectl -n projectcontour get secret python-envoy-authz-tls-cert -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -text | rg -A1 "Subject Alternative Name"
```

Expected: the Service exists; Certificate `Ready=True`; the SAN list includes `DNS:python-envoy-authz-op.projectcontour.svc.cluster.local`.

If the SANs are missing, force reissue: `kubectl -n projectcontour delete secret python-envoy-authz-tls-cert` (cert-manager recreates it; `reloader` restarts the pods).

- [ ] **Step 7: Verify the endpoint answers over the new Service with a valid chain**

Verify the name resolves *and* the cert validates against the private CA — the same check Vikunja will perform in Task 6, so a SAN mistake surfaces here rather than at cutover:

```bash
kubectl -n cert-manager get secret k8s-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/k8s-ca.crt
kubectl -n projectcontour create configmap op-check-ca --from-file=ca.crt=/tmp/k8s-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n projectcontour run op-svc-check --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest \
  --overrides='{"spec":{"containers":[{"name":"op-svc-check","image":"registry.apps.nickv.me/nijave/python-envoy-authz:latest","command":["python","-c","import ssl,urllib.request\nctx=ssl.create_default_context(cafile=\"/ca/ca.crt\")\nu=\"https://python-envoy-authz-op.projectcontour.svc.cluster.local/healthz\"\nprint(\"verified fetch:\",urllib.request.urlopen(u,context=ctx).read())"],"volumeMounts":[{"name":"ca","mountPath":"/ca"}]}],"volumes":[{"name":"ca","configMap":{"name":"op-check-ca"}}]}}'
kubectl -n projectcontour delete configmap op-check-ca
rm -f /tmp/k8s-ca.crt
```

Expected: `verified fetch: b'{"status":"ok"}'` — name resolves, cert chains to the `k8s` CA, and the hostname matches a SAN. A `CERTIFICATE_VERIFY_FAILED` means the reissue in Step 6 hasn't happened; `Hostname mismatch` means the SAN list is wrong.

Expected: `reachable: b'{\"status\":\"ok\"}'`. Discovery (`/.well-known/openid-configuration`) still 404s — the OP mounts in Task 5.

---

### Task 2: Secrets plumbing

Creates every secret federation needs, in both namespaces, before anything consumes them. Still no behavior change.

**Files:**
- Modify: `python-envoy-authz.yaml` (prepend ExternalSecrets/Secret next to the two existing ExternalSecrets)
- Modify: `vikunja.yaml` (append the `default`-namespace secrets + `k8s-ca` copy machinery)

**Interfaces:**
- Produces, in `projectcontour`: Secret `python-envoy-authz-op-key` (key `op_key.pem`), Secret `python-envoy-authz-op-secret-key` (key `password`), Secret `vikunja-oidc-client-secret` (key `value`), Secret `vikunja-service-secret` (key `value`). In `default`: Secret `vikunja-oidc-client-secret` (key `value`), Secret `vikunja-service-secret` (key `value`), Secret `k8s-ca` (key `ca.crt`). Task 5 consumes the `projectcontour` set; Task 6 consumes the `default` set.

- [ ] **Step 1: Create the three Bitwarden entries (manual, outside git)**

The client secret and service secret must be *identical* across two namespaces, and the OP key must be stable across pods and restarts — so all three originate outside the cluster and arrive via the Bitwarden `ClusterSecretStore default`, the same mechanism `ca-ha.apps.somemissing.info` (also a PEM) already uses. `SECRET_KEY` is single-namespace and in-cluster-only, so it uses secret-generator instead (Step 3).

Generate locally, then store each as a Bitwarden item whose name is exactly the `remoteRef.key` below:

```bash
openssl genrsa -out /tmp/op_key.pem 2048   # → Bitwarden item: python-envoy-authz-op-key
openssl rand -base64 48                    # → Bitwarden item: vikunja-oidc-client-secret
openssl rand -base64 48                    # → Bitwarden item: vikunja-service-secret
shred -u /tmp/op_key.pem
```

The OP key must be an unencrypted PKCS#1/PKCS#8 RSA PEM — `load_pem_private_key(..., password=None)` raises on an encrypted key. Do not commit any of these values.

- [ ] **Step 2: Verify the store can see them, before wiring anything**

```bash
kubectl -n projectcontour get clustersecretstore default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
```

Expected: `True`. (Per-key existence is confirmed by the ExternalSecrets syncing in Step 6.)

- [ ] **Step 3: Add the `projectcontour` secrets to `python-envoy-authz.yaml`**

Insert these documents at the top of the file, before the existing `ca-ha-homelab-somemissing-info-tls` ExternalSecret:

```yaml
---
# OP RSA signing key. Shared by both replicas so the JWKS `kid` (an RFC 7638
# thumbprint of the key) is stable across pods and restarts — Vikunja caches
# the discovered JWKS, and a per-pod key would make ~half of all id_token
# verifications fail. Mounted 0600 (see the Deployment volume): the loader
# chmods any file with group/other bits and would die on a read-only mount.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: python-envoy-authz-op-key
  namespace: projectcontour
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  data:
  - secretKey: op_key.pem
    remoteRef:
      conversionStrategy: Default
      key: python-envoy-authz-op-key
      decodingStrategy: None
      metadataPolicy: None
---
# Signs the OP's stateless auth codes (itsdangerous). In-cluster-only and
# single-namespace, so it is generated in-cluster per the README's preference.
# Must be identical across replicas — one Secret consumed by both pods is
# exactly that. Rotating it invalidates in-flight auth codes only (TTL 30s).
apiVersion: v1
kind: Secret
metadata:
  name: python-envoy-authz-op-secret-key
  namespace: projectcontour
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: password
    secret-generator.v1.mittwald.de/length: "64"
type: Opaque
---
# Shared with Vikunja's OIDC client config in the `default` namespace (see
# vikunja.yaml). Both namespaces read the same Bitwarden item so the values
# cannot drift — a mismatch is a 401 invalid_client at /oauth/token.
# NOTE: providers.yaml gives this no default, and empty counts as unset, so an
# empty value here crash-loops the pod and takes the Frigate/HA paths with it.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vikunja-oidc-client-secret
  namespace: projectcontour
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  data:
  - secretKey: value
    remoteRef:
      conversionStrategy: Default
      key: vikunja-oidc-client-secret
      decodingStrategy: None
      metadataPolicy: None
---
# Vikunja's service.secret (HS256). Lets the federator verify an incoming
# client bearer locally (signature + exp + user binding) and allow it through
# untouched instead of re-federating. Must equal VIKUNJA_SERVICE_SECRET.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vikunja-service-secret
  namespace: projectcontour
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  data:
  - secretKey: value
    remoteRef:
      conversionStrategy: Default
      key: vikunja-service-secret
      decodingStrategy: None
      metadataPolicy: None
```

- [ ] **Step 4: Add the `default`-namespace secrets to `vikunja.yaml`**

Append to `vikunja.yaml`. The first two mirror Step 3 against the same Bitwarden items. The rest copy the private CA into `default` so Vikunja can verify the OP's cert: `k8s-ca` lives only in `cert-manager`, and its `TLSCertificateDelegation` covers Contour references, not pod volume mounts — so this uses the external-secrets kubernetes provider, the same k8s→k8s copy pattern as `clusterissuer.yaml:36-73`.

```yaml
---
# Same Bitwarden items as the projectcontour copies in python-envoy-authz.yaml.
# Vikunja's OIDC client secret must equal the federator's VIKUNJA_CLIENT_SECRET.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vikunja-oidc-client-secret
  namespace: default
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  data:
  - secretKey: value
    remoteRef:
      conversionStrategy: Default
      key: vikunja-oidc-client-secret
      decodingStrategy: None
      metadataPolicy: None
---
# Vikunja's service.secret. Previously unset, which meant Vikunja generated a
# random one at every startup and logged everyone out on each restart; pinning
# it is a fix in its own right, and the federator needs the same value.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vikunja-service-secret
  namespace: default
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  data:
  - secretKey: value
    remoteRef:
      conversionStrategy: Default
      key: vikunja-service-secret
      decodingStrategy: None
      metadataPolicy: None
---
# Vikunja must trust the private `k8s` CA to fetch OP discovery/JWKS over
# HTTPS. The CA cert exists only as `k8s-ca` in `cert-manager`; this SA reads
# it from there via the external-secrets kubernetes provider.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: k8s-ca-reader
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: k8s-ca-reader
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["k8s-ca"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: k8s-ca-reader
  namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: k8s-ca-reader
subjects:
  - kind: ServiceAccount
    name: k8s-ca-reader
    namespace: default
---
# The kubernetes provider validates its own access with a
# SelfSubjectRulesReview, which is cluster-scoped — hence a ClusterRole rather
# than folding this verb into the Role above.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: k8s-ca-reader-ssrr
rules:
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectrulesreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: k8s-ca-reader-ssrr
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: k8s-ca-reader-ssrr
subjects:
  - kind: ServiceAccount
    name: k8s-ca-reader
    namespace: default
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: k8s-ca
  namespace: default
spec:
  provider:
    kubernetes:
      remoteNamespace: cert-manager
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        serviceAccount:
          name: k8s-ca-reader
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: k8s-ca
  namespace: default
spec:
  refreshInterval: 1m
  secretStoreRef:
    kind: SecretStore
    name: k8s-ca
  target:
    name: k8s-ca
  data:
  - secretKey: ca.crt
    remoteRef:
      key: k8s-ca
      property: ca.crt
      conversionStrategy: Default
      decodingStrategy: None
      metadataPolicy: None
```

- [ ] **Step 5: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
kubectl apply --server-side --dry-run=server --force-conflicts -f python-envoy-authz.yaml -f vikunja.yaml
git add python-envoy-authz.yaml vikunja.yaml
git commit -m "feat(vikunja): add federation secrets and copy the k8s CA into default"
```

- [ ] **Step 6: Verify every secret materialized**

```bash
for ns in projectcontour default; do
  echo "--- $ns"
  kubectl -n $ns get externalsecret -o custom-columns=NAME:.metadata.name,READY:.status.conditions[0].reason
done
kubectl -n projectcontour get secret python-envoy-authz-op-key \
  -o jsonpath='{.data.op_key\.pem}' | base64 -d | head -1
kubectl -n projectcontour get secret python-envoy-authz-op-secret-key \
  -o jsonpath='{.data.password}' | base64 -d | wc -c
kubectl -n default get secret k8s-ca -o jsonpath='{.data.ca\.crt}' | base64 -d | head -1
# The two shared secrets must be byte-identical across namespaces:
diff <(kubectl -n projectcontour get secret vikunja-oidc-client-secret -o jsonpath='{.data.value}') \
     <(kubectl -n default        get secret vikunja-oidc-client-secret -o jsonpath='{.data.value}') \
  && echo "client secret matches across namespaces"
diff <(kubectl -n projectcontour get secret vikunja-service-secret -o jsonpath='{.data.value}') \
     <(kubectl -n default        get secret vikunja-service-secret -o jsonpath='{.data.value}') \
  && echo "service secret matches across namespaces"
```

Expected: every ExternalSecret `SecretSynced`; the OP key starts `-----BEGIN RSA PRIVATE KEY-----` or `-----BEGIN PRIVATE KEY-----`; the generated `SECRET_KEY` is non-empty and at least 32 bytes (the repo's working precedent, `cluster.default.yaml:12-23`, uses only the `autogenerate` annotation — if the operator ignores `/length` you get its default length, which is fine; do not block on the exact number); `k8s-ca` starts `-----BEGIN CERTIFICATE-----`; both `diff`s report a match.

If the `k8s-ca` ExternalSecret reports a permissions error, re-check that the `Role` is in `cert-manager` (not `default`) and that the `ClusterRole` for `selfsubjectrulesreviews` is bound.

---

### Task 3: Vikunja edge with required mTLS and ext_authz

Fronts Vikunja with Contour, requiring a client cert and consulting the existing authz service. Federation is still off, so this proves the *gate* independently: a cert-holder reaches Vikunja's normal login page, everyone else is refused.

**Files:**
- Create: `proxy_vikunja_apps_somemissing_info.yaml`
- Modify: `application.vikunja.yaml` (`config.yml` `publicurl`, lines 100-106)

**Interfaces:**
- Consumes: the existing `ExtensionService/python-envoy-authz` in `projectcontour` and the existing `ca-ha-homelab-somemissing-info-tls` Secret in `default` (created by `proxy_homeassistant.yaml:1-17`).
- Produces: HTTPProxy `vikunja-apps-somemissing-info` serving `vikunja.apps.somemissing.info`; `publicurl` = `https://vikunja.apps.somemissing.info`, which is the base of `VIKUNJA_REDIRECT_URL` in Tasks 5-6.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://vikunja.apps.somemissing.info/api/v1/info
```

Expected now: a DNS or TLS failure (no such host / no route), because external-dns has no record for this FQDN yet.

- [ ] **Step 2: Create the edge manifest**

```yaml
---
# Edge certificate. Public LE via DNS-01, matching every other *.apps host in
# this repo (proxy_homeassistant.yaml, proxy_frigate_apps_somemissing_info.yaml)
# so browsers need no private trust. The private `k8s` CA is only used for
# service-to-service certs.
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vikunja-apps-somemissing-info-cert
  namespace: default
spec:
  secretName: vikunja-apps-somemissing-info-tls
  issuerRef:
    name: cert-manager-webhook-dnsimple-production
    kind: ClusterIssuer
  commonName: &cn vikunja.apps.somemissing.info
  dnsNames:
    - *cn
---
# Vikunja behind the mTLS edge.
#
# Unlike the Frigate/HA proxies this deliberately omits
# `optionalClientCertificate`, so Envoy REQUIRES a client cert: the whole point
# is that no unauthenticated path to Vikunja remains. Combined with the
# NetworkPolicy, this is the only route in.
#
# ext_authz fails closed (failOpen defaults to false): if python-envoy-authz is
# down, Vikunja returns 503 rather than being served unauthenticated.
#
# Upstream is plain HTTP on the pod network. Vikunja cannot terminate an
# operator-supplied cert (its only HTTPS mode is automatic Let's Encrypt), and
# the federator's own callback to Vikunja cannot verify a private CA, so
# confidentiality on this hop is provided by the NetworkPolicy instead.
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: vikunja-apps-somemissing-info
  namespace: default
spec:
  virtualhost:
    fqdn: vikunja.apps.somemissing.info
    tls:
      secretName: vikunja-apps-somemissing-info-tls
      clientValidation:
        caSecret: ca-ha-homelab-somemissing-info-tls
    authorization:
      extensionRef:
        name: python-envoy-authz
        namespace: projectcontour
  routes:
    - conditions:
        - prefix: /
      services:
        - name: vikunja
          port: 80
```

- [ ] **Step 3: Point `publicurl` at the new edge URL**

Vikunja builds its frontend API base and OIDC redirect from `publicurl`, so it must be the edge URL, not the old LAN one. In `application.vikunja.yaml`, replace the `configMaps.config.data` block:

```yaml
          configMaps:
            config:
              enabled: true
              data:
                config.yml: |
                  # https://vikunja.io/docs/config-options/
                  service:
                    # The Contour mTLS edge (proxy_vikunja_apps_somemissing_info.yaml)
                    # is the only way in. This is also the base of the OIDC
                    # redirect URL the federator registers, so it must match
                    # VIKUNJA_REDIRECT_URL in python-envoy-authz.yaml exactly.
                    publicurl: https://vikunja.apps.somemissing.info
```

- [ ] **Step 4: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
kubectl apply --server-side --dry-run=server -f proxy_vikunja_apps_somemissing_info.yaml
git add proxy_vikunja_apps_somemissing_info.yaml application.vikunja.yaml
git commit -m "feat(vikunja): front with the Contour mTLS edge and ext_authz"
```

- [ ] **Step 5: Verify the proxy is valid and DNS resolves**

```bash
kubectl -n default get httpproxy vikunja-apps-somemissing-info \
  -o jsonpath='{.status.currentStatus} {.status.description}{"\n"}'
kubectl -n default get certificate vikunja-apps-somemissing-info-cert \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
dig +short vikunja.apps.somemissing.info
```

Expected: `valid Valid HTTPProxy`; certificate `True`; an A record (external-dns publishes it from the HTTPProxy — it runs with `--source=contour-httpproxy`).

- [ ] **Step 6: Verify the gate — no cert refused, cert allowed**

```bash
# No client certificate: Envoy must refuse the handshake.
curl -sS https://vikunja.apps.somemissing.info/api/v1/info ; echo "exit=$?"

# With a client certificate (same cert used for ha./frigate.):
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  https://vikunja.apps.somemissing.info/api/v1/info | head -c 200; echo
```

Expected: without a cert, a TLS alert (`sslv3 alert handshake failure` / `certificate required`, non-zero exit). With a cert, Vikunja's JSON info payload. Also confirm the authz pods logged the decision:

```bash
kubectl -n projectcontour logs -l app=python-envoy-authz --tail=20 | rg -i "vikunja|allow|deny" | head
```

Federation is still off, so no `Authorization` header is injected and the browser sees the normal login page. That is the expected intermediate state.

---

### Task 4: Close the LAN bypass with a Calico NetworkPolicy

Until this lands, anything on the LAN can still reach Vikunja's ClusterIP directly and skip mTLS entirely, making Task 3's gate decorative.

**Files:**
- Modify: `proxy_vikunja_apps_somemissing_info.yaml` (append the NetworkPolicy)
- Modify: `application.vikunja.yaml` (drop the external-dns annotation, lines 57-67)

**Interfaces:**
- Consumes: the live pod labels `app.kubernetes.io/name: vikunja` + `app.kubernetes.io/instance: vikunja`, and the Envoy pod label `app: envoy` / authz pod label `app: python-envoy-authz`, both in `projectcontour`.
- Produces: Vikunja reachable only from those two workloads. Task 5's federator callback depends on the `app: python-envoy-authz` rule existing.

- [ ] **Step 1: Write the verification and watch it fail (bypass currently open)**

```bash
kubectl -n kube-system run bypass-probe --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest --command -- python -c "
import socket
s=socket.create_connection(('vikunja.default.svc.cluster.local',80),5)
print('REACHABLE from an unrelated namespace (bypass open)'); s.close()"
```

Expected now: `REACHABLE from an unrelated namespace (bypass open)`.

- [ ] **Step 2: Append the NetworkPolicy**

```yaml
---
# Vikunja's ClusterIP is LAN-routable (Calico advertises the Service CIDR over
# BGP — see README "Why a bare ClusterIP is reachable from off-cluster"), so
# without this policy any host on the home network could talk to Vikunja
# directly and skip the mTLS + ext_authz edge entirely.
#
# Two ingress sources, both in projectcontour:
#   - app: envoy               — the Contour data plane proxying user traffic
#   - app: python-envoy-authz  — the federator's own callback to Vikunja's
#                                OpenID endpoint (POST /api/v1/auth/openid/...)
# Ports are the POD port (3456), not the Service port (80).
#
# Ingress only: Vikunja's egress to Postgres, SMTP and the OP is unrestricted.
# Verified on this cluster 2026-07-26: an ingress policy does NOT break the
# kubelet's httpGet probes (hostEndpoint.autoCreate is Disabled, so
# host-originated traffic is not subject to workload policy), while
# cross-namespace pod-to-pod traffic is correctly dropped.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vikunja
  namespace: default
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: vikunja
      app.kubernetes.io/instance: vikunja
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: projectcontour
          podSelector:
            matchLabels:
              app: envoy
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: projectcontour
          podSelector:
            matchLabels:
              app: python-envoy-authz
      ports:
        - protocol: TCP
          port: 3456
```

- [ ] **Step 3: Remove the now-dead LAN DNS record**

The `vikunja.k8s.somemissing.info` A record points at a ClusterIP nothing may talk to any more; leaving it is a trap for future debugging. In `application.vikunja.yaml`, replace the `service` block:

```yaml
          service:
            main:
              # No external-dns annotation: Vikunja is reached exclusively
              # through the Contour mTLS edge at vikunja.apps.somemissing.info
              # (proxy_vikunja_apps_somemissing_info.yaml), and the
              # NetworkPolicy there permits only Envoy + the authz federator.
              # Port 80 is kept so the federator's VIKUNJA_API_BASE needs no
              # port suffix.
              ports:
                http:
                  port: 80
                  targetPort: 3456
```

external-dns owns the record (`--registry=txt --txt-owner-id=k8s`), so removing the annotation deletes it.

- [ ] **Step 4: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
git add proxy_vikunja_apps_somemissing_info.yaml application.vikunja.yaml
git commit -m "feat(vikunja): restrict ingress to Contour and drop the LAN record"
```

- [ ] **Step 5: Verify the bypass is closed and the edge still works**

```bash
# Unrelated namespace: must now time out.
kubectl -n kube-system run bypass-probe --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest --command -- python -c "
import socket
try:
    socket.create_connection(('vikunja.default.svc.cluster.local',80),6)
    print('STILL REACHABLE - policy not enforced')
except Exception as e: print('blocked as expected:', type(e).__name__)"

# The edge must be unaffected.
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  -o /dev/null -w 'edge=%{http_code}\n' https://vikunja.apps.somemissing.info/api/v1/info

# Probes must still pass — no restarts, still Ready.
kubectl -n default get pod -l app.kubernetes.io/name=vikunja
dig +short vikunja.k8s.somemissing.info
```

Expected: `blocked as expected: TimeoutError`; `edge=200`; pod `1/1 Running` with unchanged `RESTARTS`; the old LAN record returns nothing.

---

### Task 5: Enable the OP and federator with the host allowlist parked

Turns federation on with `VIKUNJA_HOST` pointed at a host nobody uses. This is the ordering trick that makes the cutover safe: the OP becomes reachable and verifiable *before* Vikunja is told to trust it, and no request federates yet — so a misconfiguration cannot lock anyone out of Vikunja. Task 7 flips the host.

**Files:**
- Modify: `python-envoy-authz.yaml` (Deployment env, volumes, resources)

**Interfaces:**
- Consumes: Secrets from Task 2; the OP Service and SANs from Task 1.
- Produces: a live OP at `https://python-envoy-authz-op.projectcontour.svc.cluster.local` serving `/.well-known/openid-configuration`, `/jwks.json`, `/oauth/token`, `/oauth/userinfo`, with a stable `kid` shared by both replicas. Task 6 points Vikunja at it.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
kubectl -n projectcontour run op-check --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest --command -- python -c "
import ssl, urllib.request
ctx=ssl._create_unverified_context()
print(urllib.request.urlopen('https://python-envoy-authz-op.projectcontour.svc.cluster.local/.well-known/openid-configuration', context=ctx).read()[:120])"
```

Expected now: `HTTPError: 404 Not Found` — the OP router is not mounted while federation is disabled.

- [ ] **Step 2: Add the federation env to the Deployment**

Append to the container's `env:` list in `python-envoy-authz.yaml`, after the `OTEL_*` entries:

```yaml
          # --- federation (mTLS → OAuth2) ---
          # All three of IDP_ISSUER, SECRET_KEY and PROVIDERS_FILE must be set
          # for federation to activate; any one missing logs
          # "Federation disabled ..." and runs the mTLS + Frigate gate only.
          #
          # The issuer is the base of every URL in the discovery document, so it
          # must be what Vikunja can actually reach; it is a SAN on
          # python-envoy-authz-tls-cert (both listeners share that cert).
          - name: IDP_ISSUER
            value: "https://python-envoy-authz-op.projectcontour.svc.cluster.local"
          - name: SECRET_KEY
            valueFrom:
              secretKeyRef:
                name: python-envoy-authz-op-secret-key
                key: password
          # providers.yaml ships inside the image and interpolates ${VAR} from
          # the environment, so no ConfigMap is needed — only overrides below.
          - name: PROVIDERS_FILE
            value: "/app/envoy_authz/providers.yaml"
          # Redemption is a nested round trip: we POST the code to Vikunja, then
          # Vikunja fetches our discovery + JWKS and POSTs /oauth/token. The
          # 10s default can expire the code mid-flight on a cold JWKS fetch.
          - name: CODE_TTL_SECONDS
            value: "30"
          - name: OP_KEY_PATH
            value: "/var/lib/op-key/op_key.pem"
          # --- providers.yaml interpolation ---
          # PARKED: no request host matches this, so nothing federates yet. A
          # non-matching host is allowed through with no header injected, which
          # makes enabling the OP a no-op for live traffic. Task 7 flips it to
          # vikunja.apps.somemissing.info.
          - name: VIKUNJA_HOST
            value: "federation-parked.invalid"
          # Plain http:// is required: the federator's httpx client is built
          # with no custom CA, so an internal-CA https base URL would fail
          # verification and deny 503.
          - name: VIKUNJA_API_BASE
            value: "http://vikunja.default.svc.cluster.local"
          # Registered as the client's ONLY allowed redirect URI and echoed back
          # to Vikunja in the callback body, so it must match what Vikunja sends
          # to /oauth/token: {publicurl}/auth/openid/{provider_key}.
          - name: VIKUNJA_REDIRECT_URL
            value: "https://vikunja.apps.somemissing.info/auth/openid/broker"
          - name: VIKUNJA_PROVIDER_KEY
            value: "broker"
          - name: VIKUNJA_CLIENT_SECRET
            valueFrom:
              secretKeyRef:
                name: vikunja-oidc-client-secret
                key: value
          - name: VIKUNJA_SESSION_SECRET
            valueFrom:
              secretKeyRef:
                name: vikunja-service-secret
                key: value
```

- [ ] **Step 3: Mount the OP key 0600 and raise the memory ceiling**

Add to `volumeMounts:`:

```yaml
          - name: op-key
            mountPath: /var/lib/op-key
            readOnly: true
```

Add to `volumes:`:

```yaml
        - name: op-key
          secret:
            secretName: python-envoy-authz-op-key
            # 0600 is load-bearing: the key loader chmods any file with
            # group/other bits before reading it, and chmod on a read-only
            # Secret mount raises PermissionError, killing the process before
            # any listener binds. At 0600 the chmod is skipped entirely.
            defaultMode: 0600
```

Replace `resources:` — the OP pulls in authlib/joserfc and the federator adds an httpx pool on top of a ~62Mi baseline:

```yaml
        resources:
          requests:
            cpu: 10m
            memory: 128Mi
          limits:
            cpu: 250m
            memory: 384Mi
```

- [ ] **Step 4: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
kubectl apply --server-side --dry-run=server --force-conflicts -f python-envoy-authz.yaml
git add python-envoy-authz.yaml
git commit -m "feat(python-envoy-authz): enable the OP and federator, host allowlist parked"
```

- [ ] **Step 5: Verify the pods came up federated, not crash-looping**

```bash
kubectl -n projectcontour get pod -l app=python-envoy-authz
kubectl -n projectcontour logs -l app=python-envoy-authz --tail=30 | rg -i "federation|gRPC server started|Traceback|Error"
```

Expected: both pods `1/1 Running`, no restarts, and **no** `Federation disabled` line. A crash loop here is almost always one of: an empty `VIKUNJA_CLIENT_SECRET` (`unset or empty environment variable in providers config`), the OP key mounted without `defaultMode: 0600` (`PermissionError`), or an encrypted OP key PEM.

Confirm the mounted key really landed at mode `0600` — YAML parses `0600` as octal, but verify rather than assume, since a wrong mode is exactly the `PermissionError` crash above:

```bash
kubectl -n projectcontour exec deploy/python-envoy-authz -- python -c "
import os, stat
p='/var/lib/op-key/op_key.pem'
print('mode:', oct(os.stat(p).st_mode & 0o777)); print('readable:', os.access(p, os.R_OK))"
```

Expected: `mode: 0o600`. If it reports `0o644`, the `defaultMode` didn't apply — change it to the decimal equivalent `384` and re-merge.

- [ ] **Step 6: Verify the OP surface and that both replicas share one `kid`**

```bash
kubectl -n projectcontour run op-check --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest --command -- python -c "
import json, ssl, urllib.request
ctx=ssl._create_unverified_context()
base='https://python-envoy-authz-op.projectcontour.svc.cluster.local'
d=json.load(urllib.request.urlopen(base+'/.well-known/openid-configuration', context=ctx))
print('issuer:', d['issuer']); print('token_endpoint:', d['token_endpoint'])
kids={json.load(urllib.request.urlopen(base+'/jwks.json', context=ctx))['keys'][0]['kid'] for _ in range(8)}
print('distinct kids across 8 requests:', kids)"
```

Expected: `issuer` exactly `https://python-envoy-authz-op.projectcontour.svc.cluster.local`, and **exactly one** distinct `kid` — proof both replicas loaded the same shared key. More than one means the Secret isn't shared and Task 6 will half-fail.

- [ ] **Step 7: Verify nothing regressed and no traffic is federating**

```bash
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  -o /dev/null -w 'frigate=%{http_code}\n' https://frigate.apps.somemissing.info/
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  -o /dev/null -w 'ha=%{http_code}\n' https://ha.apps.somemissing.info/
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  -o /dev/null -w 'vikunja=%{http_code}\n' https://vikunja.apps.somemissing.info/api/v1/info
kubectl -n projectcontour top pod -l app=python-envoy-authz
```

Expected: all three succeed as before (Vikunja still unauthenticated — host is parked), and memory sits well under the new 384Mi ceiling.

---

### Task 6: Configure Vikunja's OpenID provider and CA trust

Tells Vikunja about the OP and lets it verify the OP's private-CA certificate. Still no federation (host parked), so a mistake here cannot lock anyone out.

**Files:**
- Modify: `application.vikunja.yaml` (`env` block lines 107-118; `persistence` block lines 68-89)

**Interfaces:**
- Consumes: the `default`-namespace Secrets from Task 2; the OP issuer URL from Task 5.
- Produces: a Vikunja `broker` OIDC provider whose `AUTHURL`/`CLIENTID`/`CLIENTSECRET` match the federator's, and a Vikunja process that trusts the `k8s` CA. Task 7 depends on both.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  https://vikunja.apps.somemissing.info/api/v1/info | python3 -m json.tool | rg -A5 openid
```

Expected now: `auth.openid.enabled` false / no `broker` provider listed.

- [ ] **Step 2: Mount the CA so Vikunja can verify the OP cert**

Vikunja is a Go binary in a `FROM scratch` image, so Go's `SSL_CERT_FILE` is the lever. Add a `k8sca` entry to `persistence`, mirroring the existing `pgca` mount:

```yaml
            # The private `k8s` CA, so Vikunja can verify the OP's HTTPS cert
            # when it fetches discovery/JWKS and redeems the auth code. Copied
            # into this namespace by the k8s-ca ExternalSecret in vikunja.yaml.
            k8sca:
              enabled: true
              type: secret
              name: k8s-ca
              mountPath: /etc/vikunja/k8sca
              readOnly: true
              items:
                - key: ca.crt
                  path: ca.crt
```

- [ ] **Step 3: Add the OIDC provider env**

Replace the `env:` block, keeping every existing database key:

```yaml
          env:
            VIKUNJA_DATABASE_TYPE: postgres
            VIKUNJA_DATABASE_HOST: default-rw.default.svc.cluster.local
            VIKUNJA_DATABASE_USER: vikunja
            VIKUNJA_DATABASE_NAME: vikunja
            VIKUNJA_DATABASE_SSLMODE: verify-full
            VIKUNJA_DATABASE_SSLROOTCERT: /etc/vikunja/pgca/ca.crt
            VIKUNJA_DATABASE_PASSWORD:
              valueFrom:
                secretKeyRef:
                  name: postgres-vikunja-user
                  key: password
            # Go reads SSL_CERT_FILE for its default root pool. Pointing it at
            # the private k8s CA is what lets Vikunja verify the OP's cert.
            # Postgres is unaffected: lib/pq uses VIKUNJA_DATABASE_SSLROOTCERT
            # explicitly rather than the default pool.
            SSL_CERT_FILE: /etc/vikunja/k8sca/ca.crt
            # Pinned (was previously unset, so Vikunja generated a random one
            # per startup and invalidated all sessions on restart). The
            # federator needs the same value as VIKUNJA_SESSION_SECRET to
            # verify an incoming bearer locally.
            VIKUNJA_SERVICE_SECRET:
              valueFrom:
                secretKeyRef:
                  name: vikunja-service-secret
                  key: value
            # OIDC provider pointing at python-envoy-authz's in-process OP. The
            # BROKER segment is the provider id and must equal the federator's
            # VIKUNJA_PROVIDER_KEY, because it forms both the callback path
            # (/api/v1/auth/openid/broker/callback) and the redirect URL.
            VIKUNJA_AUTH_OPENID_ENABLED: "true"
            VIKUNJA_AUTH_OPENID_PROVIDERS_BROKER_NAME: broker
            VIKUNJA_AUTH_OPENID_PROVIDERS_BROKER_AUTHURL: https://python-envoy-authz-op.projectcontour.svc.cluster.local
            VIKUNJA_AUTH_OPENID_PROVIDERS_BROKER_CLIENTID: vikunja
            VIKUNJA_AUTH_OPENID_PROVIDERS_BROKER_CLIENTSECRET:
              valueFrom:
                secretKeyRef:
                  name: vikunja-oidc-client-secret
                  key: value
            VIKUNJA_AUTH_OPENID_PROVIDERS_BROKER_SCOPE: "openid profile email"
```

Leave local login enabled (the chart default) as a break-glass.

- [ ] **Step 4: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
git add application.vikunja.yaml
git commit -m "feat(vikunja): configure the broker OIDC provider and trust the k8s CA"
```

- [ ] **Step 5: Verify Vikunja started and registered the provider**

```bash
kubectl -n default get pod -l app.kubernetes.io/name=vikunja
kubectl -n default logs -l app.kubernetes.io/name=vikunja --tail=40 | rg -i "panic|openid|error" | head
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  https://vikunja.apps.somemissing.info/api/v1/info | python3 -m json.tool | rg -A8 openid
```

Expected: pod `1/1 Running`; no panic; `/api/v1/info` lists the `broker` provider.

**If the pod panics with `interface conversion: interface {} is string, not map[string]interface {}`** (a known viper/env limitation with provider *lists*), apply Fallback A — declare the provider skeleton in `config.yml` and keep only the secret in env. Replace the `config.yml` block with:

```yaml
                config.yml: |
                  # https://vikunja.io/docs/config-options/
                  service:
                    publicurl: https://vikunja.apps.somemissing.info
                  auth:
                    openid:
                      enabled: true
                      providers:
                        broker:
                          name: broker
                          authurl: https://python-envoy-authz-op.projectcontour.svc.cluster.local
                          clientid: vikunja
                          scope: openid profile email
```

and delete the five `VIKUNJA_AUTH_OPENID_*` env entries except `..._BROKER_CLIENTSECRET`. Note `config.yml` is rendered into a ConfigMap in git, so the client secret must stay in env.

**If Fallback A starts but the provider still doesn't appear** (viper evaluates the provider list before env overrides), apply Fallback B — render the whole `config.yml` from a Secret so the secret never touches git. Add to `vikunja.yaml`:

```yaml
---
# config.yml rendered from Bitwarden so the OIDC client secret is not committed.
# Overrides the chart's ConfigMap mount at the same path.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: vikunja-config
  namespace: default
spec:
  refreshInterval: 300s
  secretStoreRef:
    name: default
    kind: ClusterSecretStore
  target:
    name: vikunja-config
    template:
      engineVersion: v2
      data:
        config.yml: |
          service:
            publicurl: https://vikunja.apps.somemissing.info
          auth:
            openid:
              enabled: true
              providers:
                broker:
                  name: broker
                  authurl: https://python-envoy-authz-op.projectcontour.svc.cluster.local
                  clientid: vikunja
                  clientsecret: "{{ .clientsecret }}"
                  scope: openid profile email
  data:
  - secretKey: clientsecret
    remoteRef:
      conversionStrategy: Default
      key: vikunja-oidc-client-secret
      decodingStrategy: None
      metadataPolicy: None
```

then in `application.vikunja.yaml` set `configMaps.config.enabled: false` and add a `persistence` entry mounting the Secret at the same path the chart used:

```yaml
            config:
              enabled: true
              type: secret
              name: vikunja-config
              mountPath: /etc/vikunja/config.yml
              subPath: config.yml
              readOnly: true
```

The bootstrap Job also mounts this ConfigMap (`application.vikunja.yaml:224-227`) — update its volume to the Secret in the same commit, or the Job fails config validation.

- [ ] **Step 6: Verify Vikunja can actually reach and trust the OP**

This is the step that catches a CA-trust or SAN mistake before it becomes a lockout.

```bash
POD=$(kubectl -n default get pod -l app.kubernetes.io/name=vikunja -o name | head -1)
kubectl -n default debug $POD --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest \
  --target=vikunja -it --quiet -- python -c "
import ssl, urllib.request
ctx=ssl.create_default_context(cafile='/etc/vikunja/k8sca/ca.crt')
u='https://python-envoy-authz-op.projectcontour.svc.cluster.local/.well-known/openid-configuration'
print('verified fetch OK:', urllib.request.urlopen(u, context=ctx).status)"
```

Expected: `verified fetch OK: 200`. A `CERTIFICATE_VERIFY_FAILED` means the SANs from Task 1 didn't take; `Hostname mismatch` means `IDP_ISSUER` and the SAN disagree. (`kubectl debug` shares the pod's network namespace; if the ephemeral-container path is unavailable, run the same check from any pod in `default` — the CA file can be read via `kubectl -n default get secret k8s-ca -o jsonpath='{.data.ca\.crt}' | base64 -d`.)

---

### Task 7: Flip the host allowlist — federation live

One-line cutover, with everything already verified independently.

**Files:**
- Modify: `python-envoy-authz.yaml` (the `VIKUNJA_HOST` value added in Task 5)

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: a client cert with an email SAN authenticates a Vikunja user end to end.

- [ ] **Step 1: Write the verification and watch it fail**

```bash
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  https://vikunja.apps.somemissing.info/api/v1/user | head -c 200; echo
```

Expected now: `missing, malformed, expired or otherwise invalid token provided` (or similar 401) — nothing is injected while the host is parked.

- [ ] **Step 2: Point the allowlist at the real host**

```yaml
          - name: VIKUNJA_HOST
            value: "vikunja.apps.somemissing.info"
```

Drop the `PARKED:` comment lines from Task 5 and replace them with:

```yaml
          # The federation allowlist: only this Envoy request host federates. A
          # host no provider claims is allowed through with no header injected,
          # so this is what scopes bearer injection to Vikunja alone.
```

- [ ] **Step 3: Validate and merge**

```bash
.ci/validate.sh 2>&1 | tail -3
git add python-envoy-authz.yaml
git commit -m "feat(python-envoy-authz): federate vikunja.apps.somemissing.info"
```

- [ ] **Step 4: Verify end-to-end federation**

```bash
curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
  https://vikunja.apps.somemissing.info/api/v1/user | python3 -m json.tool
```

Expected: a Vikunja user object (`username`, `email` matching the client cert's `rfc822Name` SAN) — proof the federator minted a code, Vikunja redeemed it against the OP, and the resulting bearer was injected.

- [ ] **Step 5: Verify the decision path in logs and traces**

```bash
kubectl -n projectcontour logs -l app=python-envoy-authz --tail=60 | rg -i "federat|bearer|sub=|deny" | head -20
```

Expected: a federation decision line carrying only the `sub` and branch — no bearer or cookie material (the service redacts `authorization`/`cookie`). Then confirm the second request takes the *cache* branch rather than re-federating, and that both replicas work:

```bash
for i in 1 2 3 4 5 6; do
  curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    -o /dev/null -w "req$i=%{http_code} " https://vikunja.apps.somemissing.info/api/v1/user
done; echo
kubectl -n projectcontour logs -l app=python-envoy-authz --tail=40 | rg -ci "federate"
```

Expected: all `200`; far fewer `federate` lines than requests (at most one per replica per identity), showing the session cache and per-identity locking are doing their job.

- [ ] **Step 6: Verify the failure modes behave**

```bash
# No client cert: still refused at the TLS layer.
curl -sS https://vikunja.apps.somemissing.info/api/v1/user; echo "exit=$?"
# Direct pod-network access: still blocked by the NetworkPolicy.
kubectl -n kube-system run bypass-probe --rm -i --restart=Never \
  --image=registry.apps.nickv.me/nijave/python-envoy-authz:latest --command -- python -c "
import socket
try:
    socket.create_connection(('vikunja.default.svc.cluster.local',80),6); print('REACHABLE - regression!')
except Exception as e: print('blocked as expected:', type(e).__name__)"
# Frigate and HA unaffected.
for h in frigate ha; do
  curl -sS --cert "$CLIENT_CERT" --key "$CLIENT_KEY" \
    -o /dev/null -w "$h=%{http_code}\n" https://$h.apps.somemissing.info/
done
kubectl -n projectcontour top pod -l app=python-envoy-authz
kubectl -n default get pod -l app.kubernetes.io/name=vikunja
```

Expected: TLS refusal without a cert; `blocked as expected`; Frigate/HA unchanged; memory under 384Mi; Vikunja not restarting.

---

### Task 8: Document the topology

**Files:**
- Modify: `README.md` (after the "DNS zones and TLS" section, which already references `python-envoy-authz`)

**Interfaces:**
- Consumes: the final state of Tasks 1-7.

- [ ] **Step 1: Add the section**

```markdown
## mTLS → OAuth2 federation (Vikunja)

`vikunja.apps.somemissing.info` is fronted by Contour with **required** client-cert
mTLS (`proxy_vikunja_apps_somemissing_info.yaml`) and authorized by the
`python-envoy-authz` ExtensionService. On each request the authz service derives a
stable subject from the client certificate, mints an auth code from its own
in-process OAuth2 provider, POSTs it to Vikunja's OpenID callback, and injects the
resulting `Authorization: Bearer` upstream — so a client certificate is the only
credential a user needs. Client certs must carry an `rfc822Name` (email) SAN;
without one federation fails by design.

The OP is exposed in-cluster only, as `python-envoy-authz-op.projectcontour` on
port 443 (→ container 5001), with a cert from the private `k8s` ClusterIssuer.
Vikunja trusts that CA via `SSL_CERT_FILE` pointed at a copy of `k8s-ca` in the
`default` namespace.

Two hops stay plaintext on the pod network — Contour→Vikunja and
authz→Vikunja — because Vikunja cannot terminate an operator-supplied cert (its
only HTTPS mode is automatic Let's Encrypt) and the federator's HTTP client
cannot verify a private CA. Confidentiality and access control on those hops
come from the `vikunja` NetworkPolicy, which permits ingress only from Contour's
Envoy pods and the authz pods. **That policy is what makes the mTLS gate real:**
the Service CIDR is LAN-routable via BGP, so without it any host on the network
could reach Vikunja's ClusterIP directly and skip mTLS entirely. There is
deliberately no `vikunja.k8s.somemissing.info` record.

Federation is opt-in in the app and activates only when `IDP_ISSUER`,
`SECRET_KEY` and `PROVIDERS_FILE` are all set; `providers.yaml` is the copy baked
into the image, with every field overridden through `VIKUNJA_*` env vars.

Known limitation: with `replicas: 2`, the OP's token records, its single-use
auth-code replay table, and the federator's session cache are per-pod. Auth codes
are stateless and signed with a shared `SECRET_KEY`, and the OP's RSA signing key
is a shared Secret (so the JWKS `kid` is stable), which is what makes two
replicas viable — but single-use code enforcement is per-pod.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: describe the Vikunja mTLS to OAuth2 federation topology"
```

---

## Rollback

Fastest safe rollback at any point after Task 5, without reverting manifests: set `VIKUNJA_HOST` back to `federation-parked.invalid` (one-line PR). Federation stops immediately; the mTLS gate, the NetworkPolicy and Vikunja's own login remain intact.

Full rollback order (reverse of application): Task 7 → 6 → 5 (federation off), then Task 4 (restore the external-dns annotation to bring back LAN access), then Task 3. Reverting Tasks 1-2 is optional — the extra Service, SANs and Secrets are inert with federation off.

If Vikunja becomes unreachable and the cause is unclear, the ordered suspects are: ext_authz failing closed (check `kubectl -n projectcontour get pod -l app=python-envoy-authz` first — a crash-looping authz pod 503s Vikunja, Frigate *and* HA), then the NetworkPolicy, then the OIDC config.

## Self-review notes

- **Deliberately not included:** `HA_CRL` wiring (Phase 7 of `docs/superpowers/plans/2026-07-22-homelab-mtls-pki.md`, independent of this work); any change to the Frigate/HA proxies; upstream TLS to Vikunja (ruled out — Vikunja cannot terminate a supplied cert); `replicas: 1` (rejected: the PDB would block node drains).
- **Upstream dependency:** Tasks 5-7 require `python-envoy-authz` PRs #13, #14 and #15 to be merged and built into `:latest` (they are stacked: #13→main, #14→#13, #15→#14). Before starting Task 5, confirm the OP package is actually in the image:
  `kubectl -n projectcontour exec deploy/python-envoy-authz -- python -c "import importlib.util; print(importlib.util.find_spec('envoy_authz.op') is not None)"` → must print `True`. Merging those PRs is safe ahead of this plan: federation stays dormant until Task 5 sets the three variables.
- **Ordering hazard this plan avoids:** enabling federation before Vikunja has an OIDC provider would make every federated request deny (401/503) and lock users out; configuring Vikunja's provider before the OP exists would leave it pointing at a 404. The parked-host trick in Task 5 breaks that circular dependency.
