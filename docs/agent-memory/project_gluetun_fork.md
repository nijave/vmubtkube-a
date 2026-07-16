---
name: gluetun-fork-for-userns
description: "gluetun deployments in this repo use a forked image that removes the unconditional /dev/net/tun check, enabling kernel-WG with hostUsers:false"
metadata: 
  node_type: memory
  type: project
  originSessionId: f172211b-5ef8-4420-bf69-3fb2d3bb7b61
---

The repo's gluetun pods run a forked image at `registry.apps.nickv.me/qdm12/gluetun:latest` (mirror of a local patch). The patch removes gluetun's unconditional `tun.Check`/`tun.Create` on `/dev/net/tun` in `cmd/gluetun/main.go`, which fails with `operation not permitted` when the pod has `hostUsers: false` because mknod of device nodes is forbidden inside an unprivileged user namespace.

**Why:** Wants kernel-mode WireGuard (`WIREGUARD_IMPLEMENTATION=kernelspace`) running inside a userns-isolated pod. Kernel WG goes through netlink (`setupKernelSpace` in `internal/wireguard/run.go`) and never opens the TUN device, but upstream gluetun's main.go forces the check regardless of VPN backend. The standard bind-mount-from-host workaround would defeat the userns isolation goal.

**How to apply:** When working on gluetun manifests here, use the forked image, keep `hostUsers: false`, and grant `NET_ADMIN` (and `NET_RAW` for ICMP/healthchecks). Don't reintroduce `/dev/net/tun` host bind-mounts — the patched binary doesn't need them. Related: [[private-registry-nickv]].
