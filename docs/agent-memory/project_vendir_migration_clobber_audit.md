---
name: vendir-migration-clobber-audit
description: 2026-07-03 audit of the vendir migration — only cert-manager lost customizations (3 controller args from commit 6aa8707); all other vendored components clean
metadata: 
  node_type: memory
  type: project
  originSessionId: 14216c6e-26b7-44f7-ac97-db0419b89a18
---

Full audit (7 subagents, 2026-07-03) of the 2026-07-01/02 vendir migration for dropped local customizations. Verdicts: metrics-server, external-secrets-crds, kubelet-rubber-stamp, barman-cloud-plugin, cnpg, contour all CLEAN (contour's overlay carefully reproduced ~15 customizations). Only **cert-manager** was CLOBBERED: migration commit c620973 reverted three controller args added in commit 6aa8707 (2025-11-16, "fix: dns01 challenge soa resolution"): `--dns01-recursive-nameservers`, `--dns01-recursive-nameservers-only` (restored in PR #186 after the split-DNS ACME bug re-manifested), and `--max-concurrent-challenges=5` (restored in PR #187 via JSON6902 replace of base args index 4).

**Why:** the split-horizon DNS01 bug had been fixed once before; if ACME challenges for `*.k8s.somemissing.info` ever 404 on zone `k8s.somemissing.info` again, check these args first. Related: [[argocd-secret-recreated-migration]].

**How to apply:** before claiming a config flag "never existed", check git history of the pre-vendir manifest (`git log -S '<flag>' -- <old-file>`); the vendir base is pristine upstream, so all local intent must live in `vendored/<name>/kustomization.yaml` overlays.
