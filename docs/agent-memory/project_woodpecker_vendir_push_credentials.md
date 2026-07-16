---
name: woodpecker-vendir-push-credentials
description: "How CI pushes vendir-sync commits back — Woodpecker secret handling and command-step quirks"
metadata: 
  node_type: memory
  type: project
  originSessionId: 2c9444f7-85f4-4db4-9f5a-77b0cc5b1698
---

The vendir-sync CI step pushes sync commits back to PR branches over SSH using
a write-scoped GitHub deploy key. Retrieve and rotate its material through the
approved secret-management workflow; do not copy credential values or local
key paths into agent context. The pipeline consumes the corresponding
Woodpecker repository secret via `from_secret` in `.woodpecker.yaml`.

Gotchas learned the hard way:
- Woodpecker injects netrc ONLY into trusted clone plugins — `commands:` steps get no git credentials; that was the original push failure.
- Secret `images:` filters apply to plugin steps only; on a commands step the pipeline errors ("only allowed to be used by plugins"). Don't set an image filter for command-step secrets.
- `WOODPECKER_ENCRYPTION_KEY` is inert — secrets-at-rest encryption is hard-disabled upstream (issue #1541 open). Don't set it; revisit if upstream fixes.
- Identify the current CNPG primary by its `cnpg.io/instanceRole=primary` label
  before any approved database maintenance; never assume a fixed instance.
- Newer alternative for future secrets: Woodpecker secret-extension (signed HTTP endpoint, supported by the running version — `secret_extension_netrc` column exists); could co-host with the planned [[renovate-custom-version-api]] service.
