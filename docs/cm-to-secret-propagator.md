# cm-to-secret-propagator

A generic metacontroller DecoratorController that copies ConfigMap data into
Secrets (`cm-secret-propagator.yaml`, namespace `default`). Modeled on
[metacontroller's configmappropagation example](https://github.com/metacontroller/metacontroller/tree/master/examples/configmappropagation)
with Secrets as the attachment kind.

## Why

Some components only read Secrets while their source of truth only exists as a
ConfigMap. The motivating case: `default/kube-root-ca.crt` (maintained by the
apiserver) is needed by Contour's upstream TLS `validation.caSecret`, which
only accepts Secrets.

## How it works

- The `DecoratorController` watches all ConfigMaps and calls the sync hook on
  changes plus every 300s.
- The hook parses the `mappings` key from its own ConfigMap:
  `namespace/name = secret-name`. Mapped ConfigMaps are returned as
  attachments; everything else is skipped.
- Metacontroller creates/updates the Secret (InPlace strategy) and sets an
  ownerReference to the source ConfigMap, so the Secret is garbage-collected
  with its parent.

## Adding a use case

1. Append `namespace/name = secret-name` to the `mappings` key in
   `cm-secret-propagator.yaml`.
2. Apply; the Secret appears on the next sync (events + 300s resync).

Example — copy `team-a/app-config` into a Secret named `app-config`:

```yaml
  mappings: |
    # namespace/name = secret-name
    default/kube-root-ca.crt = kube-apiserver-ca
    team-a/app-config = app-config
```

## Notes and limits

- All ConfigMap data keys are copied verbatim (base64-encoded). No templating —
  if you need that later, external-secrets can stack on top of the generated
  Secret.
- The generated Secret must not be edited by hand; metacontroller reverts
  drift on the next sync.
- The hook reads the request under `object` (DecoratorController format) and
  falls back to `parent` (CompositeController format), so it survives a switch
  of controller kinds.
- Attachments must stay declared in the DecoratorController `spec.attachments`
  (`secrets` with `updateStrategy.method: InPlace`); remove that rule only if
  you stop returning Secrets.
