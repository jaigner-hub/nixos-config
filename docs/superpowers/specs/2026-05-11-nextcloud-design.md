# Nextcloud server — design

**Date:** 2026-05-11
**Status:** approved, pending implementation plan

## Goal

Add a Nextcloud server to the homelab flake as a new NixOS host (`nextcloud`),
reachable only from the tailnet, with file storage backed by the existing
mergerfs array on `nas` via NFSv4.

## Non-goals (out of scope for v1)

- Public access / Let's Encrypt cert (gateway untouched)
- HTTPS / TLS (plain HTTP over `tailscale0`)
- External-storage apps, Collabora/OnlyOffice, Talk signaling server
- Backup automation
- Nextcloud-specific Prometheus metrics (only node_exporter scraping)

## Topology

```
                tailnet
                  │
        ┌─────────┼──────────────┐
        │         │              │
   nextcloud    nas (nass)     monitor
   ─────────    ──────────     ────────
   nginx :80    NFSv4 :2049    prometheus
   php-fpm        export       scrapes
   postgres       /mnt/storage  nextcloud:9100
   redis            /nextcloud
        ▲              │
        └──── NFS ─────┘
```

- New host `nextcloud` added to `flake.nix` via the existing `mkSystem` helper.
- All HTTP traffic stays inside the tailnet; `gateway` is **not** modified.
- Data lives on `nas` at `/mnt/storage/nextcloud`, NFS-mounted on `nextcloud`
  at `/mnt/nextcloud-data` and used as Nextcloud's `datadir`.

## Files added / changed

| Path | Change |
|------|--------|
| `flake.nix` | add `nextcloud = mkSystem "nextcloud";` |
| `machines/nextcloud/configuration.nix` | new — host module |
| `machines/nextcloud/hardware-configuration.nix` | new — generic-virtio placeholder, same convention as other hosts |
| `machines/nas/configuration.nix` | add NFS export + pinned `nextcloud` UID/GID + tailnet firewall opening for 2049 |
| `machines/monitor/configuration.nix` | append `"nextcloud:9100"` to `scrapeTargets` |

No changes to `common/base.nix`, `gateway`, `dev`, or `fragrance-app`.

## Components

### nextcloud host

- **`services.nextcloud`**, package `pkgs.nextcloud31` (latest stable at time of writing)
  - `hostName = "nextcloud"` (tailnet MagicDNS)
  - `datadir = "/mnt/nextcloud-data"`
  - `database.createLocally = true`
  - `config.dbtype = "pgsql"` → module provisions PostgreSQL role & DB
  - `configureRedis = true` → local Redis used for file locking + memcache
  - `config.adminuser = "jeff"`
  - `config.adminpassFile = "/etc/nextcloud-admin-pass"`
  - `config.trustedDomains = [ "nextcloud" "nextcloud.<tailnet>.ts.net" ]` — replace `<tailnet>` with the actual tailnet name (e.g. `tail1234`); find it via `tailscale status --json | jq -r .MagicDNSSuffix`
  - `https = false`
- **`services.nginx`** — auto-enabled by the Nextcloud module; serves the app on port 80.
- **`services.postgresql`** — auto-enabled; bound to localhost; peer auth on unix socket (no password file).
- **`services.redis.servers.nextcloud`** — auto-enabled via `configureRedis`.
- **`users.users.nextcloud`** — pinned `uid = 994`, `users.groups.nextcloud.gid = 994` so NFSv4 ownership matches nas. (994 is a chosen number in NixOS's system-user range; pre-deploy step: `getent passwd 994 && getent group 994` on both `nas` and `nextcloud` to confirm it's free, otherwise pick another and update both hosts together.)

### nas changes

- New directory `/mnt/storage/nextcloud`, owned by `nextcloud:nextcloud` (UID/GID 994).
- `users.users.nextcloud` / `users.groups.nextcloud` declared on nas with the
  same `uid = 994` / `gid = 994` (no shell, no home — the user exists only for
  consistent NFS ownership).
- `services.nfs.server`:
  - `enable = true`
  - `exports = "/mnt/storage/nextcloud 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)"`
  - The 100.64.0.0/10 range is the Tailscale CGNAT block — restricts the export to tailnet peers.
- `networking.firewall.interfaces.tailscale0.allowedTCPPorts` adds `2049`.

### monitor changes

One-line addition: `"nextcloud:9100"` in the `scrapeTargets` list.

## Data flow

1. User opens `http://nextcloud/` from a tailnet device (browser, sync client).
2. Nginx on the nextcloud host (bound only on `tailscale0`) serves static
   assets and proxies dynamic requests to PHP-FPM over a unix socket.
3. PHP-FPM reads/writes:
   - **Metadata** → local PostgreSQL via unix socket
   - **File locks / cache** → local Redis via unix socket
   - **User files & app data** → NFSv4 mount at `/mnt/nextcloud-data` (backed by `nass:/mnt/storage/nextcloud`)

## Firewall posture

`common/base.nix` already marks `tailscale0` as the only trusted interface.

- **nextcloud:** `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ]`. `allowedTCPPorts` (public) stays empty.
- **nas:** existing rules unchanged for samba/jellyfin; we only add `2049` to `interfaces.tailscale0.allowedTCPPorts`.

## Boot ordering

`services.nextcloud`'s activation (`nextcloud-setup.service`) writes into
`datadir`. If the NFS mount isn't ready, setup fails.

Mitigations on the nextcloud host:

- Mount options: `[ "nofail" "x-systemd.automount" "x-systemd.device-timeout=10" "_netdev" ]`
- Add explicit ordering: the nextcloud setup unit and `phpfpm-nextcloud.service` gain
  `after = [ "mnt-nextcloud\\x2ddata.mount" ]` and
  `requires = [ "mnt-nextcloud\\x2ddata.mount" ]`.

## Secrets

Provisioned out-of-band, never committed (matches existing pattern of `/etc/putio-sync.env`, `/etc/fragrance-app.env`, `/etc/grafana-secret-key`):

| Path | Mode | Owner | Purpose |
|------|------|-------|---------|
| `/etc/nextcloud-admin-pass` | 0400 | `nextcloud:nextcloud` | Initial admin password, consumed once at first activation |

Provisioning:

```sh
printf '%s' '<password>' \
  | sudo install -m 0400 -o nextcloud -g nextcloud /dev/stdin /etc/nextcloud-admin-pass
```

No DB password file: `database.createLocally = true` uses peer auth on a unix socket.

## Validation plan

1. **Eval check:** `nix flake check` — no errors.
2. **VM smoke test:** `nixos-rebuild build-vm --flake .#nextcloud` then run the resulting `*.qcow2`. The NFS mount will not work in the VM (no nas), but the eval and base service activation should succeed if we tolerate the missing mount via `nofail` + `x-systemd.automount`.
3. **Real-hardware deploy** (after `hardware-configuration.nix` is regenerated on the target):
   - `sudo nixos-rebuild switch --flake .#nas` first (NFS export must exist before client mounts).
   - `sudo nixos-rebuild switch --flake .#nextcloud`.
   - `mount | grep nextcloud-data` — NFS mounted.
   - `systemctl status phpfpm-nextcloud postgresql redis-nextcloud nginx` — all green.
   - Browse to `http://nextcloud/` from another tailnet device, log in as `jeff`.
   - `sudo -u nextcloud nextcloud-occ status` on the host — reports `installed: true`.
4. **Monitoring check:** `monitor`'s Prometheus targets page shows `nextcloud:9100` as UP.

## Risks & follow-ups

- **NFS ownership mismatch** — biggest landmine. Mitigated by pinning UID/GID 994 on both nas and nextcloud, verified at first deploy by `ls -ln /mnt/nextcloud-data`.
- **NFS write latency** — Nextcloud's preview generation and AppData are
  metadata-heavy. If this becomes painful, follow-up could move `appdata_*`
  off NFS to a local SSD path; out of scope for v1.
- **Plain HTTP** — some mobile clients may show a "connection insecure" prompt.
  If that becomes annoying, follow-up is `tailscale cert` + nginx TLS;
  out of scope for v1.
- **No backup** — files live on nas's mergerfs (no parity). Treating Nextcloud
  data the same as the rest of `/mnt/storage` (i.e. user's responsibility for
  off-site backup). Worth a follow-up.
