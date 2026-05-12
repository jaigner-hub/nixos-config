# Vaultwarden server — design

**Date:** 2026-05-12
**Status:** approved, pending implementation plan

## Goal

Add a Vaultwarden server (Bitwarden-compatible self-hosted password manager) to
the homelab flake as a new NixOS host (`vaultwarden`), reachable only from the
tailnet over HTTPS, with TLS provided by a `tailscale cert`-issued Let's Encrypt
certificate.

## Non-goals (out of scope for v1)

- Public access via `gateway` / Caddy
- SMTP (no password-reset emails, no email-based invites in v1)
- PostgreSQL/MySQL backend — SQLite is sufficient and simpler for personal use
- Vaultwarden-specific Prometheus metrics (only node_exporter scraping)
- Multi-org / enterprise features
- 2FA enforcement (per-user TOTP works out of the box; org-wide policy is post-v1)
- Off-site backup automation

## Topology

```
                tailnet
                  │
        ┌─────────┼──────────────┐
        │         │              │
   vaultwarden   monitor        clients
   ───────────   ────────       ─────────
   nginx :443    scrapes        Bitwarden
   (TLS)         vaultwarden    browser ext / mobile / web vault
       │         :9100
   rocket :8222
   (vaultwarden)
       │
   sqlite + attachments
   /var/lib/vaultwarden
```

- New host `vaultwarden` added to `flake.nix` via the existing `mkSystem` helper.
- All traffic stays inside the tailnet; `gateway` is **not** modified.
- TLS terminated by nginx on the host using a cert issued by `tailscale cert`,
  renewed weekly by a systemd timer.

## Files added / changed

| Path | Change |
|------|--------|
| `flake.nix` | add `vaultwarden = mkSystem "vaultwarden";` |
| `machines/vaultwarden/configuration.nix` | new — host module |
| `machines/vaultwarden/hardware-configuration.nix` | new — generic-virtio placeholder |
| `machines/monitor/configuration.nix` | append `"vaultwarden:9100"` to `scrapeTargets` |

No changes to `common/base.nix`, `gateway`, `nas`, `dev`, `fragrance-app`, or `nextcloud`.

## Components

### vaultwarden host

- **`services.vaultwarden`**:
  - `enable = true`
  - `dbBackend = "sqlite"` (default; explicit for clarity)
  - `backupDir = "/var/backup/vaultwarden"` — module-provisioned nightly SQLite backup
  - `environmentFile = "/etc/vaultwarden.env"` — supplies `ADMIN_TOKEN`
  - `config`:
    - `DOMAIN = "https://vaultwarden.<tailnet>.ts.net"` (replace `<tailnet>`; the committed file uses `tail1ec6c3` to match the existing nextcloud config)
    - `ROCKET_ADDRESS = "127.0.0.1"` (bind to localhost only; nginx proxies)
    - `ROCKET_PORT = 8222`
    - `SIGNUPS_ALLOWED = false` (admin invites users via /admin)
    - `INVITATIONS_ALLOWED = true`
    - `WEB_VAULT_ENABLED = true`
- **`services.nginx`** — reverse proxy with TLS:
  - one virtualHost for the tailnet FQDN
  - `forceSSL = true`
  - cert and key read from `/var/lib/tailscale-cert/{cert,key}.pem`
  - locations:
    - `/` → `http://127.0.0.1:8222` (proxy + WebSocket support)
    - `/notifications/hub` → `http://127.0.0.1:8222` (explicit WebSocket location for live sync)
- **Cert renewal**:
  - `tailscale-cert.service` — oneshot script that calls `tailscale cert` and reloads nginx
  - `tailscale-cert.timer` — weekly, `Persistent = true`, randomized delay
  - Initial cert issuance is a **manual deploy step** because `tailscale up` must happen first; the service is not `wantedBy = multi-user.target` to avoid a boot-time failure cascade.
- **Firewall**: `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ]`. Top-level `allowedTCPPorts` stays empty.

### monitor changes

One-line addition: `"vaultwarden:9100"` in the `scrapeTargets` list.

## Data flow

1. User opens Bitwarden client (browser extension / mobile app / web vault) pointed at `https://vaultwarden.<tailnet>.ts.net`.
2. Tailnet routes connection to the vaultwarden VM (MagicDNS auto-resolves the hostname; no public DNS).
3. nginx terminates TLS using the tailscale-issued cert and proxies HTTP to `127.0.0.1:8222`.
4. Vaultwarden reads/writes:
   - **Vault metadata + secrets** → SQLite at `/var/lib/vaultwarden/db.sqlite3`
   - **Attachments / file sends** → `/var/lib/vaultwarden/attachments/`
   - **Backups** → `/var/backup/vaultwarden/` (nightly, by the module)
5. Live-sync events flow back over a WebSocket on `/notifications/hub` (clients re-pull when a vault changes).

## DNS

Nothing to configure manually. Tailscale MagicDNS assigns `vaultwarden.<tailnet>.ts.net`
automatically when the VM joins the tailnet with `networking.hostName = "vaultwarden"`.
Tailscale's ACME proxy issues the LE cert for that same name. Verify the tailnet
suffix with `tailscale status --json | jq -r .MagicDNSSuffix` from any tailnet
device.

## Firewall posture

`common/base.nix` already marks `tailscale0` as the only trusted interface.

- **vaultwarden:** `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ]`. Top-level `allowedTCPPorts` stays empty so 443 is not reachable from any other interface.

## Secrets

Provisioned out-of-band, never committed (matches existing pattern of
`/etc/putio-sync.env`, `/etc/fragrance-app.env`, `/etc/nextcloud-admin-pass`,
`/etc/grafana-secret-key`):

| Path | Mode | Owner | Purpose |
|------|------|-------|---------|
| `/etc/vaultwarden.env` | 0400 | `vaultwarden:vaultwarden` | Contains `ADMIN_TOKEN=...` for the /admin panel |
| `/var/lib/tailscale-cert/cert.pem` | 0644 | `nginx:nginx` | TLS chain (from `tailscale cert`) |
| `/var/lib/tailscale-cert/key.pem` | 0600 | `nginx:nginx` | TLS private key |

### Admin token generation

Two acceptable forms:

1. **Plaintext** (acceptable for tailnet-only deployment):
   ```
   ADMIN_TOKEN=$(head -c 48 /dev/urandom | base64)
   ```
2. **Argon2id PHC** (preferred — vaultwarden verifies hash, plaintext is never persisted):
   ```
   nix-shell -p libargon2 --run \
     'echo -n "<plaintext>" | argon2 "$(openssl rand -hex 16)" -id -t 3 -m 16 -p 4 -l 32 -e'
   ```
   The output starts with `$argon2id$v=19$...`. **Wrap it in single quotes** in
   the env file because of the `$` characters; otherwise systemd will try to
   expand them.

### TLS cert issuance

After first deploy, on the vaultwarden host (requires the node to be auth'd to
the tailnet):

```
sudo tailscale up   # if not already authed
sudo systemctl start tailscale-cert.service
sudo systemctl restart nginx
```

The weekly `tailscale-cert.timer` keeps the cert renewed thereafter.

## Boot ordering

- **`vaultwarden.service`** depends on the data dir at `/var/lib/vaultwarden`,
  which is a local filesystem — no special ordering needed.
- **`nginx.service`** depends on the cert files being present. On first boot
  they don't exist; nginx will fail to bind that vhost. This is **expected** —
  manual recovery (see "TLS cert issuance" above) is documented in the deploy plan.
- **`tailscale-cert.service`** is **not** `wantedBy = multi-user.target` — it
  fires only on the weekly timer or via manual invocation. This avoids a
  failure cascade on first boot before `tailscale up` has been run.

## Validation plan

1. **Eval check:** `nix flake check` — no errors.
2. **VM smoke test:** `nixos-rebuild build-vm --flake .#vaultwarden`, then run the resulting VM. nginx will fail to load the TLS vhost (no cert in the VM) but vaultwarden itself should start, listening on 127.0.0.1:8222.
3. **Real-hardware deploy** (after `hardware-configuration.nix` is regenerated on the target):
   - Provision `/etc/vaultwarden.env` with `ADMIN_TOKEN=...`.
   - `sudo nixos-rebuild switch --flake .#vaultwarden`.
   - `sudo tailscale up` (interactive).
   - `sudo systemctl start tailscale-cert.service`.
   - `sudo systemctl restart nginx`.
   - From a tailnet device, `curl -k https://vaultwarden.<tailnet>.ts.net/alive` — expected: 200.
   - Browse to the same URL — Bitwarden web vault login UI loads.
   - Sign up first user: temporarily flip `SIGNUPS_ALLOWED = true` → rebuild → register → revert → rebuild.
4. **Admin panel check:** browse to `/admin`, provide the admin token, confirm dashboard loads.
5. **Monitoring check:** `monitor`'s Prometheus targets page shows `vaultwarden:9100` as UP.

## Risks & follow-ups

- **First-boot UX is a manual three-step dance** (`tailscale up` → cert service → nginx restart). Documented in the plan; acceptable for a homelab host that's deployed once.
- **Single point of failure on SQLite** — vault corruption would lose all entries. Mitigated by the module's nightly `sqlite .backup` to `/var/backup/vaultwarden`. Follow-up: replicate that directory to `nas` over rsync/restic on a timer.
- **Cert renewal silently failing** — if `tailscale cert` fails three weeks in a row, the cert expires (90-day LE). Follow-up: emit a textfile metric reporting `tailscale_cert_expiry_seconds` and alert from `monitor`.
- **Admin token plaintext-on-disk** — file mode 0400 mitigates, but a compromised root account is game-over. Argon2id PHC reduces blast radius. Acceptable for homelab.
- **No public reachability** — if you're off-tailnet (no client installed, or tailnet is down), the vault is unreachable. By design — vaultwarden clients cache the last unlock locally, so this is OK for short outages. Long outages would need a public reverse proxy via `gateway`; out of scope for v1.
- **No 2FA enforcement** — vaultwarden supports per-user TOTP; admin can encourage but not enforce. Follow-up: post-v1 policy.
