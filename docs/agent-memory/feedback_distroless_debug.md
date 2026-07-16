---
name: distroless-debug
description: Debug distroless containers using a privileged sysadmin debug container and /proc/1/root to access the target filesystem
metadata: 
  node_type: memory
  type: feedback
  originSessionId: b30af091-0463-44f2-9385-872052510a73
---

On distroless images, use a privileged (sysadmin) debug container with additional tools installed, then access the target container's filesystem via `/proc/1/root`.

**Why:** Distroless images have no shell or debugging tools, so you can't exec into them directly.

**How to apply:** When debugging a pod running a distroless image, attach an ephemeral debug container with `--target` to share the process namespace, then browse the target's filesystem at `/proc/1/root`.
