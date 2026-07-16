---
name: project-argocd-root-app-render-deadlock
description: vmubtkube-a is a self-referential ArgoCD root app; a render-time error deadlocks self-heal — patch the live Application spec to unstick
metadata: 
  node_type: memory
  type: project
  originSessionId: 15531b8e-5c16-45a5-9a4b-e7c28e672b96
---

The `vmubtkube-a` ArgoCD Application is **self-referential**: its `source.path` is `./`, so the repo root (which contains its own manifest `application.vmubtkube-a.yaml`) is its own source. It manages itself.

A **render-time** error on a self-referential root app — e.g. a bad `directory.exclude` glob that lets `renovate.json` (no `Kind`) get parsed — is a **self-heal deadlock**: ArgoCD fails at "load target state" *before* it can apply the corrected manifest from git, so the live spec stays stale and git fixes never land. Symptom: `status.sync.status = Unknown`, `status.conditions[].type = ComparisonError`, `operationState.phase = Error` after hitting `retry.limit`. Auto-sync and selfHeal cannot break this because the error precedes the apply.

**Recovery:** `kubectl patch application vmubtkube-a -n argocd --type=merge -p '{"spec":{"source":{"directory":{"exclude":"<git value>"}}}}'` to make the live spec match git. Next reconcile renders successfully → applies the fixed manifest → converges to `Synced`. This makes live == desired state, not a divergence (consistent with [[feedback-no-workaround-at-data-loss]] — desired state stays in git; only the stale live copy is corrected).

Verified 2026-07-02: after patching `exclude` to brace-expansion `{renovate.json,vendir.yml,vendir.lock.yml}`, app went Unknown→Synced at the fix revision within ~5s.

Related ArgoCD fact: `directory.exclude`/`include` take a **single brace-expansion glob** (`{a,b,c}`), NOT a YAML `|` newline block — the block collapses to one glob string that matches no file.
