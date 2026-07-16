---
name: homelab-risk-calibration
description: "Risk assessments for this cluster should weigh the human-merge gate, real backups, and soft uptime — don't rate automation changes by production standards"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2c9444f7-85f4-4db4-9f5a-77b0cc5b1698
---

When rating risk of changes/automation in this repo, Nick corrected an
over-weighted assessment (VectorChord Renovate API, 2026-07-05): rate against
the homelab's actual backstops, not production instincts.

**Why:** the environment has structural risk dampeners — (1) Renovate PRs are
always manually merged, never auto-merged; (2) automated backups exist (barman
WAL + ScheduledBackups for CNPG, volsync restic for PVCs); (3) Postgres minors
are backwards compatible; (4) uptime requirements are soft — hours of downtime
on apps like immich is acceptable.

**How to apply:** an automation bug only realizes its risk if it survives
human PR review AND exceeds what backups/rollback can undo AND the downtime
matters. Reserve Med-High/High risk ratings for changes that bypass the merge
gate (self-heal/pruning behavior, admission/enforcement, NetworkPolicies,
credential exposure) or can cascade cluster-wide. Data-touching automation
behind a manual merge is usually Low-Med here.
