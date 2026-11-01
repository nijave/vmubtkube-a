---
name: immich-schema-drift-false-positive
description: Immich's "Detected schema drift" (user_delete_audit is missing) warning is a known false positive from a pg_upgrade OID collision; ignore it
metadata:
  node_type: memory
  type: project
---

On every immich-server start, both the Api and Microservices workers log
`WARN [DatabaseService] Detected schema drift`. `immich-admin schema-check`
reports a single item: `FunctionCreate: user_delete_audit is missing`.

This is a false positive. The function and its trigger exist and work. The
2026-08-15 PG17→18 pg_upgrade gave the function OID 16727, which is also the
OID of the `vector` extension's `halfvec[]` type. Immich's schema reader
excludes extension-owned functions through `pg_depend` without a `classid`
filter, so it hides the function (immich-app/immich#31257, a duplicate of
#30696; unpatched as of 2026-11-01).

- Do not chase it as a seccomp, rollout, or migration problem.
- Do not run the SQL that schema-check suggests. It cannot clear the warning.
- After an Immich upgrade, run `immich-admin schema-check` and look for new
  items beyond `user_delete_audit`.

Details and the optional fix: `docs/immich-pg18-major-upgrade-2026-08-15.md`
(Follow-ups, "Immich schema-check false positive").
