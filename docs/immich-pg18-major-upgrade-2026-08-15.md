# Immich PostgreSQL 17 → 18 in-place major upgrade — 2026-08-15

Outcome record for PR #426 (Renovate bump of
`ghcr.io/tensorchord/cloudnative-vectorchord` `17-1.1.1` → `18-1.1.1`,
merged as `33e880a` after prep commit `6c689da`). That tag change is a
PostgreSQL major upgrade (17.10 → 18.4; VectorChord stays 1.1.1). With
CNPG ≥ 1.26 a PG-major `imageName` change is **not** a rolling restart —
the operator runs an offline in-place `pg_upgrade --link` on the primary
PVC, then destroys and re-clones the replicas.

## Preconditions verified before merging

| Check | Result |
|---|---|
| Operator supports in-place major upgrade | v1.30.0 (≥ 1.26), vendored and live in sync |
| Image tag auto-detection | `18-1.1.1` parses (major first, then `-`), so the major-upgrade flow triggers |
| Same distro (must match) | both tags build `FROM ghcr.io/cloudnative-pg/postgresql:<pg>-system-bookworm` |
| PG 17.0–17.5 `max_slot_wal_keep_size` upgrade bug | N/A — 17.10, live value `-1` |
| Immich v3.1.0 ranges | PG `>=14,<20`, VectorChord `>=0.3,<2.0`, pgvector `>=0.5,<1` — all in range |
| Extensions in target image | vchord 1.1.1, pgvector 0.8.x, cube, earthdistance |
| Backups | daily barman plugin backups completing; DB 277 MB |

## Executed sequence

1. **Pre-change backup**: immediate `immich-pre-vchord-update` (plugin
   method, ~70 s).
2. **Restore drill**: scratch cluster `immich-restore-drill` bootstrapped
   from that backup via `bootstrap.recovery.source` + an
   `externalClusters` plugin entry (the shape plugin-barman-cloud v0.14.0
   requires — the CRD forbids `serverName` on the ObjectStore, and
   `source` must reference an externalCluster, not the ObjectStore name).
   The drill set `serverName: immich` on the recovery plugin entry and
   omitted `isWALArchiver`, so the drill only read from the archive.
   Recovered in ~80 s with all 9,817 assets, both vector indexes, and
   `vchord=0.4.3` (the pre-change state, proving backup freshness).
   Cluster + PVC deleted afterwards. This is the first exercised restore
   of the barman chain for this cluster.
3. **Closed the outstanding VectorChord follow-up** from that morning's
   image bump (`a9f45f1`): the catalog was still at 0.4.3 with 1.1.1
   binaries. Ran `ALTER EXTENSION vchord UPDATE` (update path
   `0.4.3--0.5.0--…--1.1.1` verified via `pg_extension_update_paths`)
   plus `REINDEX INDEX face_index; REINDEX INDEX clip_index;` so the
   major upgrade ran with catalog and binaries matched.
4. **PR #426 additions** (`6c689da`): `serverName: immich-pg18` on the
   barman plugin (archive separation — see below), removed the stale
   trixie `imageName` comment, corrected the `renovate.json` rule note.
5. **Upgrade itself**: Argo auto-sync → all pods down →
   `immich-2-major-upgrade` job (`pg_upgrade --link`) → primary up →
   `immich-1` PVC destroyed and re-cloned via a join job → healthy.
   ~5.5 min merge → healthy, rollback never needed.
6. **Post-upgrade**: applied pg_upgrade's `update_extensions.sql`
   (`pg_stat_statements` in four DBs, `vector` → 0.8.3), `ANALYZE`,
   immediate base backup `immich-post-pg18-base`, then a cold start of
   `immich-server` to prove the startup version checks and migrations
   pass on the new stack.

## Why `serverName` changed with the image

`pg_upgrade` creates a new database system (new system id, timeline reset
to 1). The barman plugin never splits archives across majors, so
post-upgrade timeline-1 WAL would have overwritten the pg17 archive under
`s3://cnpg-immich/immich/`. The plugin parameter `serverName: immich-pg18`
(now in `immich/cluster.immich.yaml`) sends WAL and backups to a fresh
server dir and leaves the pg17 archive untouched. Keep the serverName
in sync with the imageName PG major on any future major bump.

## Final state (verified same day)

- PostgreSQL 18.4, primary `immich-2`, both instances Running, ArgoCD
  Synced/Healthy at `33e880a`.
- Extensions: `vchord=1.1.1`, `vector=0.8.3`.
- Vector search functional end to end: nearest-neighbor queries on both
  `smart_search` and `face_search` return results (note for manual psql:
  VectorChord 1.x needs `SET vchordrq.probes=N` or the scan errors with
  "need 1 probes, but 0 probes provided" — Immich sets it in its own
  sessions).
- WAL archiving healthy under `immich-pg18` (live `pg_switch_wal` test:
  archived count increments, failures frozen at 18 — all from the
  startup window before the plugin sidecar was ready).

## Follow-ups

- **pg17 archive retention**: `s3://cnpg-immich/immich/` is now inert —
  barman manages only `immich-pg18`, so retention will never prune the
  old dir. Delete it manually once the pg18 cluster has proven itself
  (e.g. after one 90 d retention window). Tracked as item 8 in the
  repo's follow-ups list. Deleted 2026-08-16 at the owner's request, one
  day post-upgrade, after a second restore drill proved the
  `immich-pg18` chain restorable.
- **volsync**: the `ReplicationSource` snapshots PVC `immich-1` (a
  replica), which the upgrade destroyed and re-cloned — its restic
  history has a discontinuity, and standby-PVC snapshots are only
  crash-consistent. The barman chain is the real DB backup. The volsync
  restore drill (follow-ups item 8) remains untested; 2026-08-15
  exercised a barman restore, not volsync.
- **Immich schema-check false positive**: v3.1.0's
  `immich-admin schema-check` reports `FunctionCreate: user_delete_audit
  is missing` on every startup. Benign and unrelated to this upgrade:
  the function exists in `public` with the exact body the tool generates,
  its trigger exists, owner matches the unflagged sibling audit
  functions, migrations are up to date, and reapplying the generated SQL
  does not clear the warning. It predates the upgrade (pg_upgrade
  preserves `pg_proc`/`pg_trigger`, and the server had not cold-started
  since v3.1.0 deployed ~6 days earlier). Re-check after the next Immich
  upgrade; report upstream if it persists.
