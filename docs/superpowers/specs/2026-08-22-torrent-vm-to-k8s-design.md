# Torrent stack migration: vmubttorrent01 (Docker Compose) → Kubernetes

Date: 2026-08-22
Status: approved design; manifests on feat/rtorrent-vm-to-k8s
Related: [2026-08-22-deluge-vm-to-k8s-design.md](2026-08-22-deluge-vm-to-k8s-design.md)
(deluge/unpackerr on vmcent74deluge — separate VM, separate AirVPN identity,
independent migration, already live)

## Context

The torrent client stack is the last media-stack component still running on a VM.
Everything it talks to already lives in the cluster: prowlarr/radarr/sonarr/sabnzbd
run in the `media` namespace, monitoring scrapes the VM today, and downloads land
on the shared NAS export. Decision: lift-and-shift the same technology stack into
the `media` namespace, following the deluge migration's manifest conventions
(ExternalSecret shape, volsync shape, probes, comment style). No client swap, no
component changes beyond credential plumbing.

## Current state (vmubttorrent01, 172.16.1.120)

Ubuntu 24.04, 4 vCPU / 5.8 GiB, Docker 29 + Compose 2.40. Two containers from
`/mnt/docker/docker-compose.yaml`, both `network_mode: host`:

| Service | Image | Ports | Notes |
|---|---|---|---|
| rtorrent | local build from `/mnt/docker/rtorrent` | nginx RPC2 :5000 (basic auth), Flood :3000, exporter :9135 | Arch-based image: rtorrent 0.16.x (Alpine's 0.16.12 deadlocks under this workload, rakshasa/rtorrent#1689), nginx SCGI→XML-RPC proxy, Flood UI, aauren rtorrent-exporter v1.6.0, xmlrpc2scgi helper |
| cross-seed | ghcr.io/cross-seed/cross-seed:6 | :2468 | reads torrents from rTorrent over XML-RPC; Torznab → prowlarr |

VPN: host-level `wg-quick@air-ca` (AirVPN Canada). Interface address
10.162.220.102/32 (+v6), MTU 1320, endpoint ca3.vpn.airdns.org:1637,
AllowedIPs 0.0.0.0/0 with fwmark policy routing. LAN/service exclusions via ip
rules: 172.16.0.0/22, 192.168.208.0/20, 192.168.224.0/20, 192.168.240.0/28.

NFS: the VM mounts `172.16.1.118:/media/av` at `/media` (nfs4, vers 4.2,
hard); downloads live in `/media/torrents`, files owned by UID/GID
1002:1001.

rtorrent specifics that must survive the move byte-for-byte:

- `session.path.set = /mnt/config/session` (local disk, ~54 MB)
- `directory.default.set = /media/torrents` — resolves identically when the
  same export root is mounted at `/media`
- `network.bind_address.set = 10.162.220.102` (binds the VPN IP; the WG
  identity is `10.162.220.102/32` plus an `fd7d:...` IPv6 `/128`)
- listen port 16312 (static AirVPN forwarded port), SCGI on 127.0.0.1:6262
- versions verified 2026-10-11: rtorrent 0.16.20-1 / libtorrent
  0.16.20-1 (`pacman -Q` on the VM) — matches
  `ghcr.io/hotio/rflood:release-0.16.20` exactly

Known debt cleaned up by this migration: nginx RPC password baked into the
Dockerfile; Prowlarr API key sitting in plaintext in cross-seed `config.js`
(rotated out-of-band, then injected as env); `local_files/gluetun-poc.yaml`
untracked with revoked keys (TODO.md item 7).

Sibling project, not superseded by this spec:
[2026-08-22-deluge-vm-to-k8s-design.md](2026-08-22-deluge-vm-to-k8s-design.md)
covers a different but similar torrent VM (`vmcent74deluge`: deluge + unpackerr,
iface `airvpn`, port 59836). This spec governs `vmubttorrent01` only. The two
migrations touch overlapping files (application.kube-prometheus.yaml
additionalScrapeConfigs/rules regions), so land them sequentially and don't
treat the other VM's monitoring entries as stale.

## Design

### Workload topology (namespace `media`)

Two Deployments, both replicas=0 pre-cutover, strategy Recreate:

**Deployment `torrent`** — no user namespace (`hostUsers` defaults to true —
NFS volumes do not support idmap mounts, so the media PVC rules out userns).
Kernelspace WireGuard in upstream gluetun ≥ v3.41.3 needs no `/dev/net/tun`,
so the forked gluetun image is not needed either
(`docs/agent-memory/project_gluetun_fork.md` stays fallback-only).
terminationGracePeriodSeconds 90 for clean session save of ~325 torrents on
SIGTERM.

| container | image | notes |
|---|---|---|
| init `rtorrent-init` | `ghcr.io/hotio/rflood` (same image as rtorrent, entrypoint overridden) | every boot: writes `/config/rpc2/basic_auth_credentials` (nginx htpasswd) from Secret `rtorrent-rpc-auth` and `/config/vpn.rc` (bind addresses + listen port) from Secret `gluetun-airvpn-torrent` + ConfigMap `torrent-vpn` |
| init `gluetun` (restartPolicy Always) | upstream `qmcgaw/gluetun` v3.41.3, digest-pinned | runs the AirVPN tunnel; pod shares its netns |
| `rtorrent` | `ghcr.io/hotio/rflood:release-0.16.20`, digest-pinned | rTorrent 0.16.20 built from source (the VM's version), Flood bundled, nginx /RPC2; s6-overlay, drops to `PUID`/`PGID` |
| sidecar `rtorrent-exporter` | `docker.io/aauren/rtorrent-exporter` v1.6.0, digest-pinned | metrics :9135; the VM's exporter version, so alert metric names are unchanged |

Pod DNS: `dnsPolicy: None` + `dnsConfig` resolvers through the tunnel
(1.1.1.1, 8.8.4.4, `ndots: "1"`).

gluetun container details:

- `envFrom` Secret `gluetun-airvpn-torrent`, produced by an ExternalSecret
  from the `default` ClusterSecretStore (Bitwarden). Named `...-torrent`
  because the deluge migration owns `gluetun-airvpn` in this namespace
  (Secret names collide). Static provider config
  (`VPN_SERVICE_PROVIDER=airvpn`, `VPN_TYPE=wireguard`,
  `WIREGUARD_IMPLEMENTATION=kernelspace`, `SERVER_COUNTRIES=canada`) in
  `target.template`; sensitive values (`WIREGUARD_PRIVATE_KEY`,
  `WIREGUARD_PRESHARED_KEY`, `WIREGUARD_ADDRESSES`) via `remoteRef` AND
  re-rendered through `target.template.data` (`"{{ .KEY }}"` entries) —
  ESO renders only the keys listed there, so without the template entries
  the Secret would carry only the static keys. Bitwarden items are
  `gluetun-rtorrent-wireguard-{private-key,preshared-key,addresses}`.
- Extra env: `WIREGUARD_MTU=1320` (the WireGuard backend takes
  `WIREGUARD_MTU`, not OpenVPN's `VPN_MTU`),
  `HEALTH_SERVER_ADDRESS=0.0.0.0:9999`,
  `HEALTH_TARGET_ADDRESSES=cloudflare.com:443,google.com:443`,
  `FIREWALL_INPUT_PORTS="9999,5000,3000,9135"` — health server, nginx RPC2,
  Flood, exporter. In-cluster traffic to the Services DNATs into the netns
  and traverses gluetun's INPUT chain; without these allows every Service
  blackholes.
  `FIREWALL_VPN_INPUT_PORTS="16312"`,
  `FIREWALL_OUTBOUND_SUBNETS="172.16.0.0/22,192.168.208.0/20,192.168.224.0/20,192.168.240.0/28"`
  (mirrors the VM's wg-quick ip-rule exemptions exactly: NAS, node/pod/
  service ranges, Contour LB VIPs stay off-tunnel).
- `securityContext`: NET_ADMIN + NET_RAW. startupProbe on :9999 gates the
  app containers; a readinessProbe on :9999 makes a failing tunnel take the
  pod NotReady (startup and liveness alone would just restart gluetun).

rtorrent container details:

- **Init container `rtorrent-init`** (same rflood image with the s6
  entrypoint overridden) runs on every boot and renders two files on the
  config PVC:
  - `/config/rpc2/basic_auth_credentials` (htpasswd format, user `admin`)
    from Secret `rtorrent-rpc-auth`, `chmod 640`; rflood would otherwise
    generate a random `hotio:` user. Running every boot means a rotated
    Secret takes effect after reloader restarts the pod. The password never
    appears in argv (piped to `openssl passwd -apr1` via stdin).
  - `/config/vpn.rc` — the bind addresses and listen port, single-sourced
    (see Network). Env: `LISTEN_PORT` from ConfigMap `torrent-vpn` key
    `FIREWALL_VPN_INPUT_PORTS`, `WIREGUARD_ADDRESSES` from Secret
    `gluetun-airvpn-torrent`. Splits the comma-separated addresses, strips
    spaces and the `/prefix`; `:` marks the IPv6 entry, `.` the IPv4; fails
    (exit 1) if there is no IPv4 entry or the port is not a number. Written
    via temp file + `mv` so rtorrent never sees a half-written file. Only
    the addresses and port are echoed — they are not secret; the private
    key is never printed.
- **Env**: `PUID=1002`/`PGID=1001` (hotio remap, no `runAsUser` — s6 starts
  as root and drops), `UMASK=002`, `TZ=Etc/UTC`, `FLOOD_AUTH=true`
  (rflood defaults Flood to *no login*), `S6_SERVICES_GRACETIME=60000` and
  `S6_KILL_GRACETIME=5000` (s6-overlay gives services 3s to stop by
  default; the full session save must fit in
  `terminationGracePeriodSeconds: 90`).
- Probes: startup/readiness/liveness `tcpSocket` on port `rpc` (nginx
  :5000), **not Flood** — Flood is a UI and must not gate the RPC Service
  radarr/sonarr use. rtorrent wedges (2026-08-15 incident) surface through
  the exporter scrape alert instead.
- Volume mounts: `torrent-config` PVC at `/config` (rflood's `CONFIG_DIR`;
  session/, watch/, rpc2/, flood/), the `rtorrent-rc` ConfigMap subPath
  `rtorrent.rc` at `/config/rtorrent.rc` read-only (rflood only writes a
  default `rtorrent.rc` when the file is missing, so the mount wins), and
  `torrent-media` PVC at `/media` — the same export root the VM mounts
  (`172.16.1.118:/media/av`), so `directory.default.set = /media/torrents`
  resolves identically and fastresume paths stay valid.

rtorrent.rc (ConfigMap `rtorrent-rc` in torrent.yaml) is the VM's file with
these deltas, each commented inline in the ConfigMap:

- `session.path.set = /config/session/`, preceded by
  `execute.throw = sh, -c, "mkdir -p /config/session /config/watch"`.
- `directory.default.set = /media/torrents` kept as-is.
- Removed: `network.bind_address.set`, `network.listen.port.set` and
  `network.listen.port.random` (moved to `/config/vpn.rc`, imported below
  — single source, see Network).
- Added: `import = /config/vpn.rc` — plain import (not `try_import`): a
  missing file must stop rtorrent from starting.
- Removed: `system.daemon.set`, `network.scgi.open_port`, both
  `method.redirect` lines and both `method.insert=d.down.sequential*`
  lines — rflood starts rtorrent with daemon mode and the SCGI unix socket
  `/dev/shm/rtorrent.sock` and already injects those four lines via
  `/app/rtorrent-fix.rc` (duplicate `method.insert` would error).
- Everything else unchanged (logging to stdout, encryption, throttles,
  schedule, session save on insert, buffers, xmlrpc size limit 4M —
  rflood's nginx reads `client_max_body_size` from the
  `network.xmlrpc.size_limit.set` line).

exporter sidecar: `aauren/rtorrent-exporter` v1.6.0 with
`command: ["/rtorrent-exporter"]` (the image has no ENTRYPOINT — its CMD
is the binary path — so `args` alone would replace CMD and fail to exec),
`--rtorrent.addr=http://127.0.0.1:5000/RPC2` and
`--rtorrent.trackers.enabled=false`, no credentials — rflood's nginx has
`satisfy any; allow 127.0.0.1`, so RPC2 requests from localhost bypass
basic auth. Runs as 65534, metrics port 9135.

**Deployment `cross-seed`** (`cross-seed.yaml`) — separate from the torrent
pod, no VPN: it only talks to prowlarr and rtorrent in-cluster. cross-seed
v6 with `useClientTorrents: true` reads torrents from rTorrent over
XML-RPC, so it does not need rtorrent's session dir either.

- Digest-pinned `ghcr.io/cross-seed/cross-seed:6`, `args: [daemon]`,
  runAsUser 1002 / runAsGroup 1001 / runAsNonRoot true, pod fsGroup 1001.
- Default cluster DNS (no dnsPolicy override).
- Env: `RTORRENT_RPC_PASSWORD` from Secret `rtorrent-rpc-auth`; envFrom
  Secret `cross-seed` (`PROWLARR_API_KEY`, see Secrets).
- Mounts: `cross-seed-config` PVC at `/config`; `torrent-media` (RWX,
  shared with torrent) at `/media` **read-only** — only needed if linkDirs
  are enabled later (it must become writable then).
- Probes: startup/readiness/liveness `tcpSocket` on `http` (:2468).
- The VM's config.js today: `torrentDir: "/config/state"` (rTorrent's
  session dir), `torrentClients: ["rtorrent:http://<user:pass>@127.0.0.1:
  5000/RPC2"]`, `action: "inject"`, `matchMode: "safe"`,
  `linkType: "hardlink"` with **no linkDirs** (so no linking happens
  today), `dataDirs: []`, `sonarr`/`radarr` undefined, port 2468.
- config.js lives on the PVC (copied from the VM's `/mnt/docker/cross-seed`
  at cutover) and must be edited at cutover to read secrets from env:
  `torrentClients: [\`rtorrent:http://admin:${process.env.RTORRENT_RPC_PASSWORD}@rtorrent-rpc.media.svc.cluster.local/RPC2\`]`,
  torznab URLs pointing at
  `http://prowlarr.media.svc.cluster.local/<id>/api?apikey=${process.env.PROWLARR_API_KEY}`,
  `useClientTorrents: true`, `torrentDir: null`.

### Network

- Services (ClusterIP + external-dns `*.k8s.somemissing.info` hostnames):
  - `rtorrent-rpc` :80→5000 (XML-RPC for radarr/sonarr/prowlarr/cross-seed)
  - `flood` :3000 (UI access from LAN)
  - `rtorrent-metrics` :9135 (exporter; see Monitoring)
  - `cross-seed` :2468
- Peer traffic: no Service, no hostPort. Peers connect to the AirVPN
  forwarded port through the tunnel; gluetun's firewall passes 16312 into
  the shared netns where rtorrent listens.
- **Single source for the VPN bind addresses and listen port**: ConfigMap
  `torrent-vpn` carries `FIREWALL_VPN_INPUT_PORTS: "16312"` (the AirVPN
  static forwarded port — AirVPN has no port-forward API, gluetun only
  supports automatic forwarding for PIA/ProtonVPN/PrivateVPN/
  PerfectPrivacy). The gluetun sidecar consumes it via `envFrom`; the
  `rtorrent-init` container gets it plus `WIREGUARD_ADDRESSES` (from the
  gluetun Secret) and renders `/config/vpn.rc` every boot:
  `network.bind_address.ipv4.set` / `network.bind_address.ipv6.set` (only
  if an IPv6 entry exists) / `network.listen.port.set` /
  `network.listen.port.random = no`. rTorrent 0.16 binds IPv4 and IPv6
  separately and opens one listen socket per family — binding to the
  tunnel addresses means no traffic flows if the tunnel is down. The VM's
  identity is `10.162.220.102/32` plus an `fd7d:...` IPv6 `/128`; IPv6
  egress through gluetun was verified working in the live deluge pod.
  Nothing that must match lives in two places: the port appears once (in
  the ConfigMap) and the addresses once (in the Bitwarden-backed Secret).

### Storage

- `torrent-config` PVC (5 Gi, `ReadWriteOncePod`, default
  `zfs-generic-iscsi-csi` SC): session/, watch/, rpc2/ (nginx htpasswd),
  vpn.rc (bind addresses + listen port — both rendered from the
  Secret/ConfigMap by the rtorrent-init container on every boot),
  flood/ (Flood's DB). (cross-seed moved to its own PVC.) volsync
  `ReplicationSource` restic backup every 30 min:
  `copyMethod: Clone`, moverSecurityContext runAsUser 1002 / runAsGroup
  1001 / fsGroup 1001, retain hourly 6 / daily 5 / weekly 4 / monthly 3.
- `cross-seed-config` PVC (1 Gi, `ReadWriteOncePod`): config.js and
  cross-seed state, backed up the same way via repo `volsync-cross-seed`.
- NFS PV/PVC `torrent-media` → `nas.apps.somemissing.info:/media/av`
  (100Ti RWX, Retain), mounted at `/media`. Same export the VM mounts, no
  data movement; capacity is advisory on static PVs and sized generously
  since the export expands over time. Shared with cross-seed (RWX).

### Secrets

- `gluetun-airvpn-torrent`: ExternalSecret as above (see workload
  topology). No manual Secret involved.
- `rtorrent-rpc-auth`: mittwald kubernetes-secret-generator auto-generates
  the RPC password, **hex-encoded**:
  ```yaml
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: password
    secret-generator.v1.mittwald.de/encoding: hex
    secret-generator.v1.mittwald.de/length: "48"
  ```
  Hex because the password is URI-embedded: cross-seed's config.js builds
  `rtorrent:http://admin:<pw>@rtorrent-rpc.../RPC2`, and base64's `/` and
  `+` break every URL parser (see
  `docs/agent-memory/feedback_mittwald_password_encoding.md`). The
  rtorrent-init init container renders the nginx htpasswd
  (`/config/rpc2/basic_auth_credentials`) from this Secret on every boot;
  no image embeds a password any more. **Flood's user DB is not migrated**:
  the VM's Flood users.db carries connection settings pointing at the VM's
  TCP SCGI port, which no longer exists. Flood starts fresh with
  `FLOOD_AUTH=true`; create the Flood user on first login and connect it to
  the rTorrent socket `/dev/shm/rtorrent.sock`.
- `cross-seed` ExternalSecret: `PROWLARR_API_KEY` from Bitwarden item
  `prowlarr-api-key` — **rotated** out-of-band (the old key sat in
  plaintext in config.js on the VM).
- `restic-repo-torrent` and `restic-repo-cross-seed` ExternalSecrets: restic
  repo trios from Bitwarden for buckets `volsync-torrent` and
  `volsync-cross-seed`.

### Images

- The VM's custom Arch image (`images/rtorrent/`, deleted from this
  branch) is replaced by **`ghcr.io/hotio/rflood:release-0.16.20`** —
  rTorrent 0.16.20 built from source (the VM's exact version), Flood
  bundled, nginx serving `/RPC2` with basic auth and a localhost bypass —
  plus the official **`aauren/rtorrent-exporter` v1.6.0** image as a
  sidecar (the VM's exporter version, so metric names are unchanged).
- Why: maintained public images Renovate can track digest-pinned, no
  manual build/push step, and the baked-in RPC password debt goes away
  (the htpasswd is rendered from the Secret at boot instead).
- Third-party images (cross-seed, upstream gluetun) digest-pinned per repo
  convention.

### Monitoring

Monitoring touchpoints for this box (`vmubttorrent01`) today: the rtorrent
ScrapeConfig + `rtorrent-alerts` PrometheusRule (live), a
`vmubttorrent01.rules` group with a VPN-tunnel-passing-traffic alert fed by
a vpn-probe metric, and the `vmubttorrent01:9100` node_exporter target.
(The deluge job, `deluge.rules`, and `vmcent74deluge:9100` belong to the
sibling VM — out of scope here.)

- Scraping moves to the **in-cluster kube-prometheus** (not the ext
  Prometheus): a ServiceMonitor `rtorrent-metrics` in `media` labelled
  `release: prom` (same mechanic as the `arr` ServiceMonitor in media.yaml)
  selects the `rtorrent-metrics` Service via the metadata label
  `app.kubernetes.io/component: rtorrent-metrics` (metadata only, not in
  the pod selector). Its scrape job label is the Service name,
  `rtorrent-metrics`.
- The branch merges **before cutover** while the VM is still live, so
  `rtorrent-alerts.yaml` stays on `prometheus: ext` with main's expr
  (`scrapeConfig/.*/rtorrent-exporter`) until then. The **cutover commit**
  deletes `scrapeconfig-rtorrent-exporter.yaml`, moves
  `rtorrent-alerts.yaml` to label `release: prom`, and changes its job
  matcher to `job="rtorrent-metrics"` — all in one commit, same as the
  deluge migration's scrape-job flip.
- Guardrail alerts (`torrent-guardrails.yaml`, label `release: prom`):
  torrent or cross-seed pod not-ready 10m → warning. A wedged gluetun
  tunnel fails the sidecar's readinessProbe on :9999, which takes the pod
  NotReady — the in-pod replacement for the host-level tunnel probe once
  the VM dies.
- Decom-time cleanup: retire `vmubttorrent01.rules` and drop the
  `vmubttorrent01:9100` target from `prometheus-ext.yaml`. Leave every
  `vmcent74deluge` entry alone.

## Out-of-band prerequisites (before cutover)

1. ~~Export the VM's live WG private/preshared keys into Bitwarden items
   (`gluetun-rtorrent-wireguard-*`) while `wg-quick@air-ca` is still up~~
   **done** — items created from the VM's live air-ca config; public key
   verified. The AirVPN forwarded port is locked at 16312.
2. Bitwarden items: restic repo trio for `restic-repo-torrent` and
   `restic-repo-cross-seed` (buckets `volsync-torrent`, `volsync-cross-seed`);
   **rotated** `prowlarr-api-key` — still outstanding. Consult the
   mittwald/ESO encoding memory note when authoring ExternalSecrets.
3. ~~Confirm the VM's rtorrent version~~ **verified 2026-10-11**:
   rtorrent 0.16.20-1 / libtorrent 0.16.20-1, matching
   `ghcr.io/hotio/rflood:release-0.16.20`. Only re-check
   (`docker exec rtorrent rtorrent -h | head -1`) if the VM is upgraded
   before cutover; pick the matching rflood release tag if it differs.
   No image build step — both images are pulled digest-pinned.

## Cutover runbook

Ordering matters: AirVPN permits one live session per WireGuard key, and the
pod will dial in with the same identity the VM holds, so the VM tunnel must be
down before the pod connects.

1. Pre-flight: manifests merged with both Deployments at `replicas: 0`
   (ArgoCD autosync on — storage and secrets reconcile, pods stay down
   until the cutover commit flips replicas to 1); confirm ExternalSecrets
   render non-empty; compare the public key of the Secret's key material
   against `wg show air-ca` on the VM to know which identity the pod will
   present.
2. Pause arr activity: disable radarr/sonarr/prowlarr download clients (and
   any cross-seed schedules).
3. Stop the VM compose stack: `cd /mnt/docker && docker compose stop`
   (stop, not down — fast rollback).
4. Drop the VM tunnel: `sudo systemctl stop wg-quick@air-ca`.
5. Sync state into the PVCs (helper pod): rsync
   `/mnt/docker/rtorrent/config/session` into `torrent-config`'s `session/`
   subdir; rsync `/mnt/docker/cross-seed` into `cross-seed-config`. Do
   **not** copy Flood's users.db (fresh Flood DB — see Secrets). Then edit
   cross-seed's config.js on the PVC to read secrets from env
   (`RTORRENT_RPC_PASSWORD` / `PROWLARR_API_KEY`), set
   `useClientTorrents: true`, `torrentDir: null`, and point torznab URLs
   at `http://prowlarr.media.svc.cluster.local/<id>/api?...` (see
   workload topology).
6. ~~Confirm the VM's rtorrent version~~ **verified 2026-10-11**: rtorrent
   0.16.20-1 / libtorrent 0.16.20-1, matching
   `ghcr.io/hotio/rflood:release-0.16.20`. Only re-check
   (`docker exec rtorrent rtorrent -h | head -1`) if the VM is upgraded
   before cutover; pick the matching rflood release tag if it differs
   (fastresume compatibility).
7. **Cutover commit**: flip replicas to 1 for `torrent` AND `cross-seed`,
   delete `scrapeconfig-rtorrent-exporter.yaml`, move
   `rtorrent-alerts.yaml` to label `release: prom` with
   `job="rtorrent-metrics"`. Verify in order:
   - gluetun readiness probe passing, WG handshake established
   - egress IP via tunnel is an AirVPN exit (curl ifconfig.me from the
     rtorrent container)
   - seeds resumed without rehash (spot-check several; a forced full recheck
     on everything is the failure signal for fastresume compat)
   - inbound peer port reachable from outside through the tunnel (AirVPN
     port checker against 16312) before any arr client is repointed
   - NFS writes work as 1002:1001; completed-download move behaves
   - ServiceMonitor target up (`job="rtorrent-metrics"`); alerts green
   - cross-seed picks up rTorrent via RPC (useClientTorrents)
   - Flood: first login creates the user; connect it to the rTorrent
     socket `/dev/shm/rtorrent.sock` and confirm the transfer list matches
8. Re-point download clients in radarr/sonarr/prowlarr to
   `rtorrent-rpc.k8s.somemissing.info`; distribute the new RPC password
   from `rtorrent-rpc-auth`.
9. Re-enable download clients; run one small end-to-end test download.
10. Burn-in 24–48 h: alerts quiet, upload moving. Power the VM off (not
    wiped) and hold ~1 week before decommissioning.

Unlike the deluge-era plan, there is no overlap window where both stacks seed
concurrently: the VM tunnel must be down before the pod dials in (one live
session per AirVPN key), and the session dir is copied after full stop so
fastresume state is consistent.

## Rollback (<15 min)

Scale both Deployments to zero (releases the tunnel identity),
`wg-quick up air-ca` on the VM, `docker compose start`, re-point arr download
clients to the VM hostname. `argocd.argoproj.io/sync-options:
Prune=confirm` annotations keep PVs/PVCs safe throughout. Divergence risk is
limited to torrents added after cutover; document any before powering down
again.

## Risks & mitigations

- **Fastresume/version drift**: `ghcr.io/hotio/rflood:release-0.16.20`
  matches the VM's rtorrent 0.16.20; confirm the VM's version at cutover
  (`docker exec rtorrent rtorrent -h | head -1`) and pick the matching
  rflood release tag if it differs. Worst case a forced recheck; data
  untouched.
- **Upstream gluetun**: verified under the deluge migration's identical
  setup; regression = forked-image fallback path documented in
  `docs/agent-memory/project_gluetun_fork.md`.
- **Port mismatch**: forwarded port must be 16312; verified via AirVPN
  checker in the runbook before arr clients move.
- **MTU**: 1320 carried into WIREGUARD_MTU; first-boot throughput check
  catches black-holing of large packets.
- **RPC password in a URI**: mittwald hex encoding keeps it URL-safe (see
  Secrets); no escaping needed anywhere.
- **Secret exposure**: no credentials in git — WG keys/restic trios/
  Prowlarr key via ExternalSecret → Bitwarden, RPC password auto-generated
  by mittwald; config.js rewritten to env at cutover; revoked POC keys
  deleted from the working tree at decom.

## Follow-ups / cleanup

- `local_files/gluetun-poc.yaml` + `local_files/qds.yaml` cleanup (keys
  revoked; TODO.md item 7) is still outstanding — the deluge migration did
  not do it. This migration deletes both at decom.
- Add `ghcr.io/hotio/rflood` and `docker.io/aauren/rtorrent-exporter` to
  Renovate tracking if not automatic (the custom-image build removed them
  from the loop before).
- Remove this VM's monitoring touchpoints listed under Monitoring at decom;
  update TODO.md entries.
- Refresh `docs/agent-memory/project_gluetun_fork.md` at decom: upstream
  gluetun v3.41.3 kernelspace works; fork is fallback-only now.
- VM config source of truth lives in the infra workspace
  (`hosts/vmubttorrent01/`) — retire its WG/compose state there at decom.
