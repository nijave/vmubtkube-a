# Deluge stack migration: vmcent74deluge (Docker Compose) → Kubernetes

Date: 2026-08-22
Status: approved design, pending implementation plan
Related: [2026-08-22-torrent-vm-to-k8s-design.md](2026-08-22-torrent-vm-to-k8s-design.md)
(rtorrent/Flood/cross-seed on vmubttorrent01 — separate VM, separate AirVPN
identity, independent migration)

## Goal

Replace the docker-compose torrent stack on `vmcent74deluge`
(172.16.1.127, aka the `deluge` ssh alias) with workloads in the `media`
namespace of vmubtkube-a, then decommission the VM after a soak period.
Scope: **deluge (daemon + web UI) and unpackerr**. node_exporter is
host-level and dies with the VM. cross-seed stays disabled (out of
scope; it belongs to the vmubttorrent01 stack).

## Current state (VM)

- Compose project at `/mnt/docker` with four active services:
  `deluged` (custom Alpine image, deluged + deluge-web in one container,
  host networking), `unpackerr`, `node_exporter`, `deluge_exporter`.
- VPN is host-level: `wg-quick@airvpn`, kernel WireGuard, full tunnel
  (`AllowedIPs 0.0.0.0/0,::/0`), MTU 1320, ca3 endpoint, AirVPN DNS
  `10.128.0.1`.
- Killswitch today = deluge binds to the `airvpn` interface
  (`listen_interface: airvpn`); listen port `59836` bound to the WG IP.
- Deluge state: ~63M under `/var/lib/deluge/.config/deluge`
  (~325 torrents incl. fastresumes). Downloads live on NFS export
  `nas.apps.somemissing.info:/media/av` mounted at `/media`; incomplete →
  `/media/torrents/.incomplete`, completed move to `/media/torrents`.
- Web UI on :8112 (LAN-wide, self-signed TLS). Daemon RPC 58846 localhost-only.
- unpackerr talks to sonarr with an API key hardcoded in compose env
  (plaintext exposure — rotated during this migration).

## Design

### Workload topology (namespace `media`)

**Deployment `deluge`** — single replica, `Recreate`, `hostUsers: false`
(userns isolation), terminationGracePeriodSeconds ≥ 30 (clean session
save on SIGTERM):

| container | image | notes |
|---|---|---|
| init `gluetun` (restartPolicy Always) | upstream `qmcgaw/gluetun`, digest-pinned | runs the AirVPN tunnel; pod shares its netns |
| `deluge` | `lscr.io/linuxserver/deluge`, digest-pinned | `PUID=1002/PGID=1001`, TZ Etc/UTC |
| sidecar `deluge-exporter` | `tobbez/deluge_exporter`, digest-pinned | metrics :9354 |

Pod DNS: `dnsPolicy: None` + `dnsConfig` resolvers through the tunnel
(POC pattern: 1.1.1.1, 8.8.4.4, `ndots: "1"`).

gluetun container details:

- `envFrom` Secret `gluetun-airvpn`, produced by an ExternalSecret from the
  `default` ClusterSecretStore (Bitwarden): static provider keys
  (`VPN_SERVICE_PROVIDER=airvpn`, `VPN_TYPE=wireguard`,
  `WIREGUARD_IMPLEMENTATION=kernelspace`, `SERVER_COUNTRIES=canada`)
  rendered in `target.template`; sensitive values
  (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_PRESHARED_KEY`,
  `WIREGUARD_ADDRESSES`) via `remoteRef`.
- Extra env: `WIREGUARD_MTU=1320` — the WireGuard backend reads
  `WIREGUARD_MTU`; `VPN_MTU` is OpenVPN-only and is ignored here
  ([gluetun wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/options/wireguard.md)),
  `HEALTH_SERVER_ADDRESS=0.0.0.0:9999`,
  `HEALTH_TARGET_ADDRESSES=cloudflare.com:443,google.com:443`,
  `FIREWALL_INPUT_PORTS="9999,8112,9354"` — health server, web UI, exporter
  metrics. In-cluster traffic to the exporter Service DNATs into the netns
  and traverses gluetun's INPUT chain; without the 9354 allow every
  ServiceMonitor scrape blackholes (same mechanic as the sibling spec),
  `FIREWALL_VPN_INPUT_PORTS="59836"`,
  `FIREWALL_OUTBOUND_SUBNETS="172.16.0.0/22,192.168.208.0/20,192.168.224.0/20,192.168.240.0/28"`
  (mirrors the VM's off-tunnel exemptions: NAS, node/pod/service ranges,
  Contour VIPs).
- `securityContext`: NET_ADMIN + NET_RAW. startupProbe on :9999 gates the
  app containers.

Upstream gluetun is expected to work now under userns without the old
forked-image workaround (see `docs/agent-memory/project_gluetun_fork.md`,
stale after this migration); first-boot verification covers this.
Fallback if it regresses: the documented fork path as contingency only.

deluge container details:

- Volume mounts: `deluge-data` PVC at `/config` (LSIO layout; migrated
  state lands in `/config/.config/deluge`), media PVC at `/media`
  (**exact path parity** keeps fastresumes valid).
- Ports: 8112 `http`. Probes mirror the sabnzbd shape (startupProbe tcp,
  liveness/readiness http `/`).

deluge-exporter sidecar details:

- Mounts `.config/deluge` subPath read-only for auth/config, connects to
  deluged over **localhost** — no cross-pod RPC hole through the gluetun
  firewall. Exposes port `metrics` :9354.

**Deployment `unpackerr`** — separate plain pod, no VPN:

- Digest-pinned `docker.io/golift/unpackerr`, `runAsUser 1002/runAsGroup
  1001`.
- Media PVC at `/media/torrents` via `subPath: torrents` (the PVC serves
  the export root `/media/av`; a bare mount would nest paths as
  `/media/torrents/torrents/…` and sonarr-provided paths wouldn't
  resolve); no config PVC (stateless).
- `UN_SONARR_0_URL=http://sonarr.media.svc.cluster.local:8989`; **rotated**
  sonarr API key injected via ExternalSecret (Bitwarden item created
  out-of-band; removes the compose-file plaintext key).

### Storage

- `deluge-data`: 40Gi `ReadWriteOncePod`, default SC
  `zfs-generic-iscsi-csi` — same as arr data PVCs.
- volsync `ReplicationSource restic-repo-deluge`: schedule `*/30 * * * *`,
  `copyMethod: Clone`, mover runAsUser 1002 / runAsGroup 1001 / fsGroup
  1001, retain hourly 6 / daily 5 / weekly 4 / monthly 3. Credentials via
  ExternalSecret `restic-repo-deluge` (new repo trio in Bitwarden,
  out-of-band prerequisite).
- Static PV/PVC pairs `deluge-media` and `unpackerr-media` pointing at
  `nas.apps.somemissing.info:/media/av` (100Ti RWX, Retain, bound by
  volumeName) — same pattern as `sabnzbd-media`; same export the VM
  mounts, no data movement. Capacity is advisory on static PVs and sized
  generously since the export expands over time.

### Exposure & monitoring

- Service `deluge` (ClusterIP): port `http` 80→8112, GA annotation
  `external-dns.kubernetes.io/hostname: deluge.k8s.somemissing.info`
  (Service IPs are routable; matches sonarr/sabnzbd pattern).
- Exporter service entry carries label `app.kubernetes.io/name: arr` so
  the existing `arr` ServiceMonitor scrapes it; remove the static
  `deluge` job from `additionalScrapeConfigs` in
  `application.kube-prometheus.yaml`. Metric names unchanged →
  `TooManyPausedTorrents` rule unaffected.
- New guardrail alert: deluge pod not-ready / health endpoint down for
  10m → warning (in-pod equivalent of the VPN-wedge probe rtorrent had).
- Decom-time cleanup (this VM only): drop `vmcent74deluge:9100` from
  `prometheus-ext.yaml`. The rtorrent ScrapeConfig/alerts belong to
  vmubttorrent01 and are handled by the sibling migration, not here.

### Config deltas applied to migrated state (before first start)

- `core.conf`: `listen_interface: ""` (no `airvpn` iface in pod; gluetun's
  firewall is the killswitch), `allow_remote: true`, `natpmp/upnp` off.
- Everything else (ports 58846/59836, paths, plugins ltConfig/AutoAdd/
  Label/Stats) carried over untouched.

## Out-of-band prerequisites (before cutover)

1. Export the VM's current working WG private/preshared keys into
   Bitwarden items; confirm AirVPN forwarded port locked to 59836.
   Each migration holds its own AirVPN identity — the vmubttorrent01
   stack must never share this key material (one live session per key).
2. Bitwarden items: restic repo trio for `restic-repo-deluge`; **rotated**
   sonarr API key. Consult the mittwald/ESO encoding memory note when
   authoring ExternalSecrets.

## Cutover runbook

Ordering mirrors the sibling spec: AirVPN permits one live session per
WireGuard key, so the VM tunnel drops before the pod dials in.

1. Pre-flight: prerequisites done; manifests merged with the `deluge`
   Deployment at `replicas: 0` (ArgoCD autosync on — storage and secrets
   reconcile, pod stays down until the cutover commit flips replicas to
   1); confirm ExternalSecrets render non-empty; compare the Secret key
   material's public key against `sudo wg show airvpn` on the VM to
   confirm which identity the pod will present.
2. Pause arr activity: disable the deluge download client in
   radarr/sonarr.
3. **Stop the VM stack**: `cd /mnt/docker && docker compose stop` (stop,
    not down — fast rollback), then `sudo systemctl stop wg-quick@airvpn`
    — frees the connection.
4. Sync state: helper pod mounts `deluge-data`; rsync
   VM:`/var/lib/deluge/.config/deluge/` → `<pvc>/.config/deluge/`;
   apply the core.conf deltas. The copy starts only after every VM
   service is stopped so fastresume state is consistent (same rationale
   as the sibling spec).
5. Flip replicas to 1 (cutover commit). Verify in order:
   - gluetun startupProbe passing, WG handshake established
   - egress IP via tunnel is an AirVPN exit (curl ifconfig.me)
   - inbound :59836 reachable through the tunnel (online AirVPN port
     checker) — before any client is repointed
   - torrents resume without rehash (spot-check several; labels/plugins
     intact); NFS writes work as 1002:1001
   - web UI serves at `deluge.k8s.somemissing.info`; exporter metrics
     flowing; guardrail alert quiet
6. Repoint radarr/sonarr download clients to
   `deluge.k8s.somemissing.info`; re-enable them; run one small
   end-to-end test download; confirm unpackerr picked up the rotated key
   (next completed archive unpacks).
7. Burn-in 24–48h: alerts quiet, upload moving.
8. Power VM off; PR removing `vmcent74deluge:9100` from
   `prometheus-ext.yaml`.
9. Soak ~1 week → decom VM (delete + DNS cleanup), delete
   `local_files/gluetun-poc.yaml` + `local_files/qds.yaml` (closes TODO
   working-tree-cleanup item), update TODO.md / UNTRACKED.md entries,
   refresh the stale gluetun-fork memory note.

## Rollback (<15 min)

Scale the `deluge` Deployment back to `replicas: 0` first (releases the
tunnel identity), `wg-quick up airvpn` on the VM, `docker compose start`,
re-point radarr/sonarr to the VM hostname. `argocd.argoproj.io/
sync-options: Prune=confirm` annotations keep PVs/PVCs safe throughout.

## Risks & mitigations

- **Deluge version delta** (Alpine 2.x build vs LSIO 2.x): state/fastresume
  formats are compatible across deluge 2.x. Worst case a forced recheck;
  data itself is untouched.
- **Upstream gluetun under userns**: expected fixed; verified at first
  boot. Contingency = forked-image path already proven by the poc.
- **Port-forward mismatch**: forwarded port must be 59836; verified
  during cutover step 5 before arr clients are repointed.
- **Key sharing across migrations**: deluge and rtorrent stacks hold
  distinct AirVPN identities; runbooks enforce one live session per key.
- **Secret exposure**: no credentials in git; all via ExternalSecret →
  Bitwarden. Plaintext sonarr key rotated. Revoked poc keys deleted from
  the working tree at decom.

## Out of scope

- cross-seed re-enablement and anything touching the vmubttorrent01 /
  rtorrent stack (see sibling spec).
- HTTPProxy/TLS/auth fronting for the web UI (plain ClusterIP + DNS like
  other arr apps; can be added later).
- Any change to sonarr/radarr/prowlarr/sabnzbd beyond the download-client
  hostname flip.
