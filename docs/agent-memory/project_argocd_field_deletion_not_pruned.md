---
name: project-argocd-field-deletion-not-pruned
description: ArgoCD can report Synced while live objects keep fields deleted from git, because apply cannot prune fields it does not own; remove them manually or enable ServerSideApply
metadata:
  node_type: memory
  type: project
  originSessionId: b453a4f7-cc35-4a33-9aa7-146184ac05cf
---

Observed 2026-08-21 during the external-dns annotation migration (#461/#464/#465): removing the `external-dns.alpha.kubernetes.io/hostname` key from git cleaned 10 Services on sync, but 8 Services and 4 Application CRs kept the key while every app reported Synced and Healthy at the merge commit. Additions (#461's new GA keys) applied fine on all; deletions did not.

**Mechanism:** ArgoCD's apply path cannot delete a field it does not own. These objects carried no `kubectl.kubernetes.io/last-applied-configuration`, so a three-way apply treats live-only fields as externally managed and leaves them in place, and the comparison still reports Synced. "Synced" does not prove a deleted field left the cluster.

**Re-add loop:** child Helm apps re-add the annotation to their Services whenever their live Application spec still contains it in `valuesObject`. Fixing the parent Application CR stops the loop; cleaning only the Service invites the next child sync to restore the key.

**Detection traps:**

- Searching a whole Application object for a key hits `.status` snapshots (`operationState`, `syncResult`, `history` hold old rendered values). Scan `spec.source.helm.valuesObject` / `spec.sources[].helm.valuesObject` paths only.
- If webhooks miss a push, apps compare against a stale revision. `kubectl -n argocd patch application <name> --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"true"}}}'` forces a comparison; auto-sync then finishes.

**Remedies that worked:**

- Application CRs: `kubectl patch --type merge` with `null` at the exact leaf deletes the key (`{"spec":{"source":{"helm":{"valuesObject":{...{"external-dns.alpha.kubernetes.io/hostname":null}}}}}}`). Re-applying a cleaned full object does **not** delete it — JSON merge keeps keys the submitted object omits.
- Services: `kubectl -n <ns> annotate svc <name> <key>-` (trailing minus) removes the annotation. After the parent specs are clean, refreshing the app re-renders without the key and the child sync removes it on its own.

**Structural fix if it recurs:** enable the `ServerSideApply=true` sync option on affected apps so ArgoCD owns the fields it applies and deletions propagate reliably.
