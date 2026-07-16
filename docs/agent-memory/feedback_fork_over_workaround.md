---
name: fork-over-workaround
description: "when upstream behavior blocks a clean architecture, this user will fork and patch rather than compromise the design"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: f172211b-5ef8-4420-bf69-3fb2d3bb7b61
---

When upstream software has a small behavior that blocks a clean architectural goal (e.g., gluetun's unconditional TUN check blocking `hostUsers: false`), this user prefers to fork and patch the upstream rather than apply the conventional workaround. In one case the user forked gluetun and patched out the offending check in ~6 minutes.

**Why:** Values architectural correctness and security posture (e.g., userns isolation) over conventional workarounds that compromise it. Treats "fork the upstream" as a small, normal cost — not an extraordinary one.

**How to apply:** When presenting solution options for upstream-induced friction, include "fork and patch upstream" as a legitimate option alongside workarounds. Don't dismiss it as "out of scope" by default — estimate the actual patch size first. If the patch is small (<50 lines) and the workaround degrades the design goal, lead with the fork option. Related: [[gluetun-fork-for-userns]].
