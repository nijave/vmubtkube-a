# HyperDX API key: intentionally committed

The HyperDX API key (`67591567-eca7-43b1-b218-4af3992e5e9b`) is committed to
git in three places on purpose:

- `application.hyperdx.yaml` — `HYPERDX_API_KEY` Helm value (the value HyperDX
  was originally bootstrapped with)
- `application.otel-collector.yaml` — `authorization:` header on the OTLP
  exporter to `hyperdx-otel-collector.hyperdx:4317`
- `application.otel-logs-daemonset.yaml` — same exporter header, from the
  per-node logs daemonset

## Why it's checked in

1. **Backwards compatibility.** The original HyperDX setup was no-auth; the
   same key has been in use since the deployment was first brought up.
   Rotating it would break every shipper of telemetry until they were all
   updated in lockstep, with no benefit (see below).

2. **HyperDX has no public API to set or retrieve the API key.** The key is
   generated once during initial setup and stored internally; there is no
   documented endpoint to rotate it programmatically or fetch it from the
   HyperDX API after the fact. So the usual pattern of "store in
   Bitwarden → ExternalSecret → reference everywhere" doesn't actually work
   here — the source of truth is this repo, not the secret store.

## Why it isn't a meaningful security boundary

The receiver at `hyperdx-otel-collector.hyperdx:4317` is an OTLP receiver
with no authentication plugin configured. The `authorization:` header is
sent by clients (the cluster-wide OTel collector and the per-node logs
daemonset) but nothing on the receiver enforces it. Any pod on the cluster
network can ship OTLP directly to that endpoint and bypass the key entirely.

So treating the key as a secret would be theater: the real trust boundary
is the cluster network itself, not the key. If telemetry ingress ever needs
to be a real boundary, the fix is to add an OTLP auth extension or a
NetworkPolicy limiting 4317/4318 to specific source namespaces — at which
point the key would become worth rotating and pulling out of git.
