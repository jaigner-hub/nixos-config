# RSS reader (Miniflux) — design

**Date:** 2026-05-17
**Status:** approved, pending implementation plan

## Goal

Add a single-user RSS reader to the homelab as a new NixOS host (`rss`), running [Miniflux](https://miniflux.app/) backed by Postgres, reachable only from the tailnet over HTTPS with a `tailscale cert`-issued TLS cert. Daily encrypted Postgres dumps go offsite to Backblaze B2 via restic.

## Non-goals (out of scope for v1)

- **Multi-user.** Single-operator homelab; one local admin account.
- **OIDC via Pocket-ID.** Not worth the config for one user — could be added later (miniflux supports generic OAuth2). Local username/password is fine.
- **Public access via cloudflared.** Tailnet-only; reader is consumed from devices that already have Tailscale.
- **Native mobile client.** Mobile reading is via the PWA in the phone browser; we're not committing to a sync protocol (Fever / Google Reader API) yet. Miniflux exposes both if a native client is ever wanted.
- **Webhook integrations** (Telegram, Slack, ntfy push of new entries). Easy to add later, not in v1.
- **OPML migration as part of activation.** OPML import is a one-shot user action via the web UI, not something the deploy needs to handle.

## Topology

```
                tailnet
                  │
        ┌─────────┼──────────────┐
        │         │              │
       rss      monitor         clients
       ──────   ────────        ───────
       nginx :443                browser / PWA
       (TLS)                        │
         │                          │
       miniflux :8080  ◄────────────┘
         │
       postgres (local)
       ── miniflux DB
         │
       daily pg_dump → /var/backups/miniflux/miniflux.sql.gz
         │
       restic → B2 (Backup-jaigner-homelab/rss)
```

- New host `rss` added to `flake.nix` via the existing `mkSystem` helper and exposed to Colmena via `hostNames`.
- All traffic stays inside the tailnet; no cloudflared tunnel.
- TLS terminated by nginx on the host using a cert issued by `tailscale cert`, renewed weekly.
- Postgres runs locally on the same host — module-default, no separate DB host.

## Files added / changed

| Path | Change |
|------|--------|
| `flake.nix` | append `"rss"` to `hostNames` |
| `machines/rss/configuration.nix` | new — host module |
| `machines/rss/hardware-configuration.nix` | new — generic-virtio placeholder |
| `machines/monitor/configuration.nix` | add `"rss:9100"` to node_exporter scrape targets and Gatus HTTP check for `https://rss.tail1ec6c3.ts.net/healthz` |

No changes to `common/base.nix`.

## Components

### rss host

- **`services.miniflux`**:
  - `enable = true`
  - `adminCredentialsFile = "/etc/miniflux-admin-creds"` — `ADMIN_USERNAME=`/`ADMIN_PASSWORD=` KEY=VAL file, read once at first start to seed the admin account.
  - `config`:
    - `LISTEN_ADDR = "127.0.0.1:8080"` — bind loopback; nginx reverse-proxies.
    - `BASE_URL = "https://rss.tail1ec6c3.ts.net"` — used for absolute links in the UI and entry URLs.
    - `RUN_MIGRATIONS = "1"` — auto-run schema migrations on upgrade.
    - `LOG_FORMAT = "json"` — friendlier for journald grepping later.
  - The module auto-provisions a local Postgres instance and a `miniflux` DB/user. No separate `services.postgresql` config required.

- **`services.nginx`** — reverse proxy with TLS:
  - one virtualHost for `rss.tail1ec6c3.ts.net`
  - `forceSSL = true`, cert/key from `/var/lib/tailscale-cert/{cert,key}.pem`
  - `recommendedProxySettings`, `recommendedTlsSettings`, `recommendedOptimisation`, `recommendedGzipSettings` (same as other hosts)
  - `locations."/"` → `http://127.0.0.1:8080`, with `proxyWebsockets = true` (miniflux uses WS for live entry updates)

- **`tailscale-cert.service`** + `.timer` — same shape as paperless / immich / vaultwarden. Oneshot script calls `tailscale cert`, chowns to `nginx:nginx`, reloads nginx; weekly timer with randomized 1h delay.

- **Firewall**: `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ]`. Top-level `allowedTCPPorts` stays empty (set by `common/base.nix`).

### Backup

- **`systemd.services.miniflux-db-backup`** — oneshot, runs as `postgres` user:
  ```
  pg_dump --clean --no-owner --no-privileges miniflux \
    | gzip > /var/backups/miniflux/miniflux.sql.gz.tmp
  mv .../miniflux.sql.gz.tmp .../miniflux.sql.gz
  ```
  Atomic rename so a partial dump never replaces a good one.
- **`systemd.timers.miniflux-db-backup`** — `OnCalendar=*-*-* 03:00:00`, `Persistent=true`, `RandomizedDelaySec=30m`. Runs 90 minutes before the restic job (matches immich's pattern).
- **`services.restic.backups.rss`** — daily, `04:30` after the dump, pruneOpts `--keep-daily 7 --keep-weekly 4 --keep-monthly 12`, repository `s3:https://s3.us-east-005.backblazeb2.com/Backup-jaigner-homelab/rss`, `passwordFile = "/etc/restic/password"`, `environmentFile = "/etc/restic/b2.env"`. Paths: `/var/backups/miniflux`. No excludes needed.

### Failure handling

- `mkNtfyOnFailure { topic = "homelab-warn"; title = "rss: miniflux failed"; } "miniflux.service"` → `homelab-warn` topic.
- Same for `tailscale-cert.service`, `miniflux-db-backup.service`, and `restic-backups-rss.service`. All warn-tier (none are user-facing critical; cert renewals are weekly with 3-month validity, backup misses for one day are recoverable).

### monitor changes

Two additions:
1. Append `"rss:9100"` to the prometheus node_exporter scrape job's `static_configs.targets`.
2. Append a Gatus endpoint:
   ```yaml
   - name: rss
     group: tailnet
     url: https://rss.tail1ec6c3.ts.net/healthz
     interval: 60s
     conditions:
       - "[STATUS] == 200"
   ```
   Miniflux exposes a `/healthz` that returns 200 when the app + DB are reachable.

## Data flow

1. User opens `https://rss.tail1ec6c3.ts.net` in a browser (Tailscale required — phone, laptop, etc.).
2. nginx terminates TLS, proxies to miniflux on `127.0.0.1:8080`.
3. Miniflux reads/writes its DB on local Postgres at `/var/lib/postgresql/<version>/miniflux`.
4. Miniflux's internal poller fetches feeds on its own schedule (default every hour, configurable per-feed).
5. Daily at ~03:00, `miniflux-db-backup.timer` triggers `pg_dump` → `/var/backups/miniflux/miniflux.sql.gz`.
6. Daily at ~04:30, `restic-backups-rss.timer` snapshots `/var/backups/miniflux` to B2.

## DNS

Nothing to configure manually. Tailscale MagicDNS assigns `rss.tail1ec6c3.ts.net` automatically when the host joins the tailnet with `networking.hostName = "rss"`.

## Firewall posture

- Top-level `allowedTCPPorts` empty (inherited from `common/base.nix`).
- `tailscale0` interface allows TCP 443 only.
- Postgres binds to its default unix socket — no TCP listener, no firewall rule needed.

## Secrets

Provisioned out-of-band, never committed:

| Path | Mode | Owner | Purpose |
|------|------|-------|---------|
| `/etc/miniflux-admin-creds` | 0600 | `root:root` | `ADMIN_USERNAME=` + `ADMIN_PASSWORD=`. Module reads on first start to seed the admin user; subsequent password changes happen in-app and persist in the DB. |
| `/etc/restic/password` | 0600 | `root:root` | Restic repo passphrase (same as other hosts) |
| `/etc/restic/b2.env` | 0600 | `root:root` | `B2_ACCOUNT_ID=` + `B2_ACCOUNT_KEY=` (same as other hosts) |
| `/var/lib/tailscale-cert/cert.pem` | 0644 | `nginx:nginx` | TLS chain |
| `/var/lib/tailscale-cert/key.pem` | 0600 | `nginx:nginx` | TLS private key |

## Bootstrap

A new host on this homelab follows the established sequence (documented in `CLAUDE.md`):

1. On the rss console (or via initial SSH): `nixos-generate-config --show-hardware-config`, replace `machines/rss/hardware-configuration.nix` with the output.
2. Join tailscale on the new host: `sudo tailscale up --ssh`. Confirm it shows up as `rss.tail1ec6c3.ts.net` in `tailscale status`.
3. From your workstation: `sudo nixos-rebuild boot --flake github:jaigner-hub/nixos-config#rss` then reboot. Using `boot` (not `switch`) avoids live-restarting `boot.mount`.
4. After it comes back up, `scripts/deploy.sh rss` works going forward.
5. Provision the admin creds before first miniflux start:
   ```
   printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=%s\n' '<chosen-password>' \
     | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
   sudo systemctl restart miniflux
   ```
6. Issue the TLS cert (known first-deploy gotcha — the unit isn't `wantedBy = multi-user.target`):
   ```
   sudo systemctl start tailscale-cert.service
   ```
7. Provision restic creds (copy `/etc/restic/password` and `/etc/restic/b2.env` from any other host).
8. Browse to `https://rss.tail1ec6c3.ts.net`, log in as `admin`, change the password in Settings, optionally import an OPML.

## Why these choices

### Miniflux over FreshRSS

- Single Go binary + Postgres vs PHP-FPM + (MySQL|Postgres|SQLite). Smaller blast radius.
- Opinionated minimal UI is the actual product — themes/plugins of FreshRSS are negative value for one user.
- NixOS module is mature, takes a `config` attrset of env vars (1:1 with miniflux's documented env), auto-provisions Postgres.
- Built-in healthz + Fever API + Miniflux API leave the future-flexibility door open without committing to anything now.

### Local Postgres, not shared

The miniflux NixOS module brings its own Postgres instance and DB user. We don't run a fleet-wide Postgres host — every service that needs one (immich, nextcloud, miniflux) brings its own. Pros: hosts are self-contained, backup story is local, no shared-fate. Cons: more Postgres processes. Acceptable in a single-operator homelab.

### Tailnet-only, no cloudflared

RSS is read from devices that already have Tailscale (phone, laptops). Public exposure would mean a public attack surface for a single-user app with no useful sharing/collaboration feature. Same logic as vaultwarden.

### Single dedicated host, not co-located

Every service in this homelab gets its own host (even adguard runs as two dedicated VMs). Co-locating miniflux on `monitor` or `dev` would save a VM but break the pattern. The cost of a VM is ~256 MB RAM and one extra entry in deploys; the benefit is host-level isolation for backups, restore, network policy, and future moves.

## Future considerations (deliberately deferred)

- **OIDC via Pocket-ID.** Wire miniflux's `OAUTH2_PROVIDER=oidc` to Pocket-ID if a second user shows up. Adds two env vars + a Pocket-ID client.
- **Push notifications.** Miniflux can hit a webhook on new entries. Could fan out to ntfy for "high-priority" feeds (e.g., security advisories). Not in v1 — would add noise without filtering.
- **OPML auto-import from git.** Persist `feeds.opml` in this repo and reconcile on boot. Tempting but probably over-engineered for one user who'll subscribe via the UI anyway.
- **External Postgres consolidation.** If we ever run >3 services with their own Postgres, consolidating to a shared instance with per-app DBs may pay for itself in resource use. Defer until it's a real problem.
