# Torrent stack migration: vmubttorrent01 (Docker Compose) → Kubernetes

Date: 2026-08-22
Status: approved design, pending implementation plan
Related: [2026-08-22-deluge-vm-to-k8s-design.md](2026-08-22-deluge-vm-to-k8s-design.md)
(deluge/unpackerr on vmcent74deluge — separate VM, separate AirVPN identity,
independent migration)

## Context

The torrent client stack is the last media-stack component still running on a VM.
Everything it talks to already lives in the cluster: prowlarr/radarr/sonarr/sabnzbd
run in the `media` namespace, monitoring scrapes the VM today, and downloads land
on the shared NAS export. The cluster side of the VPN problem was de-risked by an
untracked POC (`local_files/gluetun-poc.yaml`, gitignored) that proved gluetun can
run kernel-mode WireGuard inside a userns-isolated pod using the forked image
(see `docs/agent-memory/project_gluetun_fork.md`).

Decision: lift-and-shift the same technology stack. No client swap, no component
changes beyond credential plumbing.

## Current state (vmubttorrent01, 172.16.1.120)

Ubuntu 24.04, 4 vCPU / 5.8 GiB, Docker 29 + Compose 2.40. Two containers from
`/mnt/docker/docker-compose.yaml`, both `network_mode: host`:

| Service | Image | Ports | Notes |
|---|---|---|---|
| rtorrent | local build from `/mnt/docker/rtorrent` | nginx RPC2 :5000 (basic auth), Flood :3000, exporter :9135 | Arch-based image: current rtorrent 0.16.x (Alpine's 0.16.12 deadlocks under this workload, rakshasa/rtorrent#1689), nginx SCGI→XML-RPC proxy, Flood UI, aauren rtorrent-exporter v1.6.0, xmlrpc2scgi helper |
| cross-seed | ghcr.io/cross-seed/cross-seed:6 | :2468 | reads rtorrent session dir read-only; Torznab → prowlarr.k8s.somemissing.info |

VPN: host-level `wg-quick@air-ca` (AirVPN Canada). Interface address
10.162.220.102/32 (+v6), MTU 1320, endpoint ca3.vpn.airdns.org:1637,
AllowedIPs 0.0.0.0/0 with fwmark policy routing. LAN/service exclusions via ip
rules: 172.16.0.0/22, 192.168.208.0/20, 192.168.224.0/20, 192.168.240.0/28.

rtorrent specifics that must survive the move byte-for-byte:

- `session.path.set = /mnt/config/session` (local disk, ~54 MB)
- `directory.default.set = /media/torrents` — NFS4 mount of
  `172.16.1.118:/media/av` (~52 TB today)
- `network.bind_address.set = 10.162.220.102` (binds the VPN IP)
- listen port 16312 (static AirVPN forwarded port), SCGI on 127.0.0.1:6262
- files on NFS owned by UID/GID 1002:1001

Known debt being cleaned up by this migration: nginx RPC password baked into the
Dockerfile; Prowlarr API key sitting in plaintext in cross-seed `config.js`;
`gluetun-poc.yaml` untracked with revoked keys (TODO.md item 7); manually-created
`gluetun-airvpn` Secret not managed by Git (UNTRACKED.md audit).

Sibling project, not superseded by this spec:
[2026-08-22-deluge-vm-to-k8s-design.md](2026-08-22-deluge-vm-to-k8s-design.md)
covers a different but similar torrent VM (`vmcent74deluge`: deluge + unpackerr,
iface `airvpn`, port 59836). This spec governs `vmubttorrent01` only. The two
migrations touch overlapping files (application.kube-prometheus.yaml
additionalScrapeConfigs/rules regions), so land them sequentially and don't
treat the other VM's monitoring entries as stale.

## Design

### Workload topology (namespace `media`)

One Deployment `torrent`, replicas=1, strategy Recreate, `hostUsers: false`,
runAs 1002:1001, terminationGracePeriodSeconds tuned for rtorrent session save:

- **gluetun** — native sidecar (initContainer with `restartPolicy: Always`),
  **upstream gluetun, digest-pinned**, verified at first boot under userns (the
  POC ran the upstream PR branch successfully; the fork is now contingency
  only). If it regresses: `registry.apps.nickv.me/qdm12/gluetun` fork per
  `docs/agent-memory/project_gluetun_fork.md`. NET_ADMIN + NET_RAW, health
  server :9999 exposed only inside the netns, startupProbe gates app containers.
  Never reintroduce `/dev/net/tun` host bind-mounts.
- **rtorrent** — the existing custom image (build context moves into this repo,
  see Images), runs the existing `start.sh` (Flood + nginx + exporter loops,
  then `exec rtorrent -p 16312-16312`).
- **cross-seed** — `ghcr.io/cross-seed/cross-seed:6` daemon; mounts the config
  PVC and the session subdir read-only. Shares the pod so it keeps exact parity
  with its current host-networked behavior and needs no PVC sharing gymnastics.

### Network

- Gluetun env: `VPN_SERVICE_PROVIDER=airvpn`, `SERVER_COUNTRIES=canada`,
  `VPN_TYPE=wireguard`, `WIREGUARD_IMPLEMENTATION=kernelspace`,
  **`WIREGUARD_MTU=1320`** (verify with a first-boot throughput/large-packet
  check; the WireGuard backend takes WIREGUARD_MTU, not OpenVPN's VPN_MTU),
  peer port **16312** via `FIREWALL_VPN_INPUT_PORTS`.
- **`FIREWALL_INPUT_PORTS=9999,5000,3000,9135`** — health server, nginx RPC2,
  Flood, exporter. In-cluster traffic to the Services DNATs into the netns and
  traverses gluetun's INPUT chain; without these allows every Service
  blackholes.
- `FIREWALL_OUTBOUND_SUBNETS=172.16.0.0/22,192.168.208.0/20,192.168.224.0/20,192.168.240.0/28`
  — mirrors the VM's wg-quick ip-rule exemptions exactly: NAS (172.16.1.118),
  node/pod/service ranges, Contour LB VIPs stay off-tunnel.
- Pod DNS: `dnsPolicy: None` + explicit resolvers through the tunnel (POC
  pattern: 1.1.1.1, 8.8.4.4, ndots=1).
- Peer traffic: no Service, no hostPort. Peers connect to the AirVPN forwarded
  port through the tunnel; gluetun's firewall passes 16312 into the shared
  netns where rtorrent listens.
- Services (ClusterIP + external-dns `*.k8s.somemissing.info` hostnames):
  - `rtorrent-rpc` :80→5000 (XML-RPC for radarr/sonarr/prowlarr/cross-seed)
  - `flood` :3000 (UI access from LAN)
  - `rtorrent-metrics` :9135 (exporter)

### Storage

- `torrent-config` PVC (~5 Gi, `ReadWriteOncePod`, default
  `zfs-generic-iscsi-csi` SC): session/, watch/, cross-seed state, and Flood's
  DB — the pod bind-mounts the PVC's `flood/` subdir at `/var/lib/flood` so
  Flood state becomes persistent instead of living in the container layer.
  volsync `ReplicationSource` restic backup every 30 min: `copyMethod: Clone`,
  moverSecurityContext runAsUser 1002 / runAsGroup 1001 / fsGroup 1001,
  retain hourly 6 / daily 5 / weekly 4 / monthly 3 — same shape as the arr
  apps (ExternalSecret for restic repo credentials from Bitwarden).
- NFS PV `torrent-media` → `nas.apps.somemissing.info:/media/av/torrents`
  (100Ti RWX, Retain), mounted at `/media/torrents`. Capacity is advisory
  on static PVs and sized generously since the export expands over time.
  Absolute paths in the copied session fastresume files then resolve
  unchanged — this is what makes a session copy viable.
- Session/state copy happens over the network during cutover (rsync from VM via
  a helper pod or `kubectl cp`).

### Secrets

- `gluetun-airvpn`: one ExternalSecret (ClusterSecretStore `default`,
  Bitwarden) renders the whole envFrom Secret — static provider config
  (`VPN_SERVICE_PROVIDER`, `VPN_TYPE`, `WIREGUARD_IMPLEMENTATION`,
  `SERVER_COUNTRIES=canada`) in `target.template`, sensitive values
  (`WIREGUARD_PRIVATE_KEY`, `WIREGUARD_PRESHARED_KEY`,
  `WIREGUARD_ADDRESSES`) via `remoteRef` — replacing the manual Secret.
  Note: the POC-era keys were revoked; export the VM's live working keys into
  Bitwarden while `wg-quick@air-ca` is still up (out-of-band prerequisite).
- `rtorrent-rpc-auth`: mittwald kubernetes-secret-generator auto-generates the
  RPC password (mumble.yaml pattern):
  ```yaml
  annotations:
    secret-generator.v1.mittwald.de/autogenerate: password
    secret-generator.v1.mittwald.de/secret-type: password
    secret-generator.v1.mittwald.de/password-length: "32"
  ```
  Default base64 encoding is correct (basic-auth header, not URI-embedded).
  The rtorrent container builds `/etc/nginx/.htpasswd` and the exporter's
  password file from it at startup; the Dockerfile stops embedding a password.
  Flood's user DB (users.db) is extracted from the VM container and lands on
  the config PVC with the rest of the state sync.
- Rotation during cutover: rotate the Prowlarr API key currently embedded in
  cross-seed config.js (it sat in plaintext on the VM).

### Images

- Build context (`Dockerfile`, `nginx.conf`, `start.sh`, `port-forward.sh`,
  `rtorrent-runner.py`) lands in this repo under `images/rtorrent/`.
  Changes vs the VM version: RPC password comes from the mounted Secret;
  drop the baked-in htpasswd and users.db steps (Flood state moves to the PVC).
  Everything else identical (Arch base, pinned-around-deadlock rtorrent, Flood,
  exporter v1.6.0).
- First build pushed to `registry.apps.nickv.me` manually (repo mirror rules
  apply); renovate-release-api tracking for the fork can be added later.
- Third-party images (cross-seed, upstream gluetun) digest-pinned per repo
  convention; freeze the VM's exact Arch package set at cutover time so the
  rebuilt rtorrent is version-identical for fastresume compatibility.

### Monitoring

Monitoring touchpoints for this box (`vmubttorrent01`) today: the rtorrent
ScrapeConfig + `rtorrent-alerts` PrometheusRule (live), a `vmubttorrent01.rules`
group with a VPN-tunnel-passing-traffic alert fed by a vpn-probe metric, and
the `vmubttorrent01:9100` node_exporter target. (The deluge job, `deluge.rules`,
and `vmcent74deluge:9100` belong to the sibling VM — out of scope here.)

- Replace the VM-targeted rtorrent ScrapeConfig with a ServiceMonitor on
  `rtorrent-metrics` (namespace `media`, label `prometheus: ext` to match the
  ext Prometheus ruleSelector, same as media.yaml).
- Update `rtorrent-alerts.yaml`: job regex matches the new job; runbook text
  swaps `cd /mnt/docker && docker compose restart rtorrent` for
  `kubectl rollout restart deploy/torrent -n media`.
- New guardrail alert: pod not-ready / gluetun health down 10m → warning
  (in-pod replacement for the host-level tunnel probe once the VM dies).
- Decom-time cleanup: retire `vmubttorrent01.rules`, drop the
  `vmubttorrent01:9100` target. Leave every `vmcent74deluge` entry alone.

## Out-of-band prerequisites (before manifests merge)

1. Export the VM's live WG private/preshared keys into Bitwarden items while
   `wg-quick@air-ca` is still up; confirm the AirVPN forwarded port is locked
   at 16312.
2. Bitwarden items: restic repo trio for `restic-repo-torrent`. Consult the
   mittwald/ESO encoding memory note when authoring ExternalSecrets.
3. Build + push the image from `images/rtorrent/` to
   `registry.apps.nickv.me`.

## Cutover runbook

Ordering matters: AirVPN permits one live session per WireGuard key, and the
pod will dial in with the same identity the VM holds, so the VM tunnel must be
down before the pod connects.

1. Pre-flight: manifests merged with the Deployment at `replicas: 0` (ArgoCD
   autosync on — pod stays down until the cutover commit flips replicas to 1);
   confirm gluetun-airvpn ExternalSecret renders non-empty; compare the public
   key of the Secret's key material against `wg show air-ca` on the VM to know
   which identity the pod will present.
2. Pause arr activity: disable radarr/sonarr/prowlarr download clients (and any
   cross-seed schedules).
3. Stop the VM compose stack: `cd /mnt/docker && docker compose stop`
   (stop, not down — fast rollback).
4. Drop the VM tunnel: `sudo systemctl stop wg-quick@air-ca`.
5. Sync state into `torrent-config` PVC (helper pod): rsync
   `/mnt/docker/rtorrent/config/session`, `/mnt/docker/cross-seed`, and
   `docker cp` Flood's DB out of the stopped container
   (`docker cp rtorrent:/var/lib/flood`) into the PVC's `flood/` subdir.
6. Bring the pod up; verify in order:
   - gluetun health probe passing, WG handshake established
   - egress IP via tunnel is an AirVPN exit (curl ifconfig.me from the
     rtorrent container)
   - seeds resumed without rehash (spot-check several; a forced full recheck
     on everything is the failure signal for fastresume compat)
   - inbound peer port reachable from outside through the tunnel (AirVPN port
     checker against 16312) before any arr client is repointed
   - NFS writes work as 1002:1001; completed-download move behaves
   - ServiceMonitor target up; rtorrent-alerts green
7. Re-point download clients in radarr/sonarr/prowlarr (and cross-seed's RPC
   target) to `rtorrent-rpc.k8s.somemissing.info`; distribute the new RPC
   password from `rtorrent-rpc-auth`; rotate the Prowlarr API key everywhere it
   is referenced.
8. Re-enable download clients; run one small end-to-end test download.
9. Burn-in 24–48 h: alerts quiet, upload moving. Power the VM off (not wiped)
   and hold ~1 week before decommissioning.

Unlike the deluge-era plan, there is no overlap window where both stacks seed
concurrently: the VM tunnel must be down before the pod dials in (one live
session per AirVPN key), and the session dir is copied after full stop so
fastresume state is consistent.

## Rollback (<15 min)

Scale `torrent` to zero (releases the tunnel), `wg-quick up air-ca` on the VM,
`docker compose start`, re-point arr download clients to the VM hostname.
`argocd.argoproj.io/sync-options: Prune=confirm` annotations keep PVs/PVCs safe
throughout. Divergence risk is limited to torrents added after cutover;
document any before powering down again.

## Risks & mitigations

- **Fastresume/version drift**: rebuilt image must carry the same rtorrent
  version as the VM at cutover (Arch pins captured then). Worst case a forced
  recheck; data untouched.
- **Upstream gluetun under userns**: verified by the POC, but regression =
  forked-image fallback path already documented.
- **Port mismatch**: forwarded port must be 16312; verified via AirVPN checker
  in step 6 before arr clients move.
- **MTU**: 1320 carried into WIREGUARD_MTU; first-boot throughput check catches
  black-holing of large packets.
- **Secret exposure**: no credentials in git — WG keys/restic trio via
  ExternalSecret → Bitwarden, RPC password auto-generated by mittwald;
  revoked POC keys deleted from the working tree at decom.

## Follow-ups / cleanup

- `local_files/gluetun-poc.yaml` + `local_files/qds.yaml` cleanup (keys
  revoked; TODO.md item 7) is owned by the deluge migration — it lands
  second and deletes both at decom (its runbook step 9). Nothing to do
  here.
- Remove this VM's monitoring touchpoints listed under Monitoring at decom;
  update TODO.md / UNTRACKED.md entries (gluetun-airvpn becomes Git-managed).
- Refresh `docs/agent-memory/project_gluetun_fork.md`: upstream PR branch
  worked in the POC; fork is fallback-only now.
- VM config source of truth lives in the infra workspace
  (`hosts/vmubttorrent01/`) — retire its WG/compose state there at decom.
- If the `vmcent74deluge` deluge migration lands around the same time,
  sequence the two so their edits to application.kube-prometheus.yaml /
  prometheus-ext.yaml don't collide.
- Optionally track the forked gluetun and rtorrent images via
  renovate-release-api (TODO.md item 3 tail).
