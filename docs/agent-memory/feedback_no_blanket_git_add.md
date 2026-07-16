---
name: no-blanket-git-add
description: "Never use `git add -A`/`git add .` in this repo — stage explicit paths only; untracked secret files live in the working tree"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 2c9444f7-85f4-4db4-9f5a-77b0cc5b1698
---

Never stage with `git add -A` or `git add .` in this repo. On 2026-07-04 a blanket `git add -A` swept the untracked `gluetun-poc.yaml` (live WireGuard keys) into a pushed commit; the key had to be revoked. Nick's feedback: "remember not to be so sloppy."

**Why:** the working tree intentionally holds untracked files, sometimes with secret material (POCs, debug manifests), and other agents may add more at any time.

**How to apply:** always `git add <explicit paths>` for exactly the files the change touches; after committing, check `git show --stat HEAD` for unexpected files before pushing. Treat any `create mode` line for a file you didn't edit as a stop-and-fix signal.
