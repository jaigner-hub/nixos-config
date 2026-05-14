# Cloudflare Tunnel for public homelab access

**Date:** 2026-05-14

## Problem

Homelab is on a residential connection with a changing public IP. The existing
no-ip workaround uses an unwanted hostname, and reaching services from outside
the tailnet currently requires Tailscale on every client. We want a real domain
(already owned at Cloudflare) routing to four services with no port forwarding,
no DDNS, and no IP chasing.

## Approach

Per-host Cloudflare Tunnel (`cloudflared`) running as a systemd unit on each
public-facing service host. TLS terminates at the Cloudflare edge; the daemon
holds an outbound connection to Cloudflare and proxies requests to a loopback
upstream on the same host.

Existing tailnet access (nginx + `tailscale-cert`) is untouched. Tailnet remains
the admin/recovery path; public hostnames become the canonical user-facing URLs.

### Why not a single centralized tunnel

Considered and rejected. A central cloudflared (e.g. on `nas`) would mean:

- a single point of failure for all public services
- plaintext traffic across the LAN, or extra config to encrypt via tailnet
  hostnames
- every host's nginx vhost has to learn the new public hostname

Per-host matches the existing isolation model (each host independently
terminates its own tailnet TLS via `tailscale-cert`) and is no harder to
operate.

### Why not classic DDNS + port forwarding

Cloudflare Tunnel sidesteps the dynamic-IP problem entirely (outbound
connection from the home network; no inbound ports). No router config, no DDNS
client to babysit, no public-cert lifecycle to manage on the hosts.

## Scope

Four hosts gain public exposure:

| Host         | Public hostname (default)     | Local upstream            |
|--------------|-------------------------------|---------------------------|
| nextcloud    | `nextcloud.<domain>`          | `http://127.0.0.1:80`     |
| vaultwarden  | `vaultwarden.<domain>`        | `http://127.0.0.1:8222`   |
| immich       | `immich.<domain>`             | `http://127.0.0.1:2283`   |
| paperless    | `paperless.<domain>`          | `http://127.0.0.1:28981`  |

Subdomain scheme mirrors the existing tailnet convention
(`<service>.tail1ec6c3.ts.net`).

## Components

### Per-host NixOS config

Use the upstream `services.cloudflared` module in nixpkgs. Each host adds:

```nix
let
  publicFqdn = "vaultwarden.example.com";
  tunnelId = "abc12345-...-uuid";  # from credentials JSON
in {
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:8222";
      };
    };
  };
}
```

No shared module is added. The four config blocks are small and host-specific
(different tunnel IDs, different upstreams); a wrapper would add indirection
without removing duplication.

### Per-host service-config touch-ups

- **vaultwarden** — `services.vaultwarden.config.DOMAIN = "https://vaultwarden.<domain>"`.
  Vaultwarden accepts a single canonical `DOMAIN`; public becomes canonical.
  Tailnet access still works for login; push notifications resolve against the
  public URL.
- **nextcloud** — append public hostname to
  `services.nextcloud.settings.trusted_domains`.
- **immich** — no change; immich accepts any Host header by default.
- **paperless** — set `PAPERLESS_URL = "https://paperless.<domain>"` and add
  the public host to `PAPERLESS_TRUSTED_PROXIES`.

### Secret: tunnel credentials

`/etc/cloudflared/<tunnel-id>.json` per host, owned by the `cloudflared`
system user, mode `0600`. Provisioned out-of-band, same pattern as
`/etc/vaultwarden.env`, `/etc/restic/password`. Never committed.

### DNS records

One CNAME per host, `<subdomain>.<domain>` → `<tunnel-id>.cfargotunnel.com`.
Created via `cloudflared tunnel route dns` during bootstrap; lives in
Cloudflare DNS independently of the tunnels themselves.

## Bootstrap

One-time per host, run from a workstation with `cloudflared` installed.

1. `cloudflared tunnel login` — browser flow, authorizes the local CLI
   against the Cloudflare account. Once per workstation, not per host.
2. `cloudflared tunnel create <name>` — produces a UUID and a credentials
   JSON in `~/.cloudflared/<uuid>.json`.
3. `cloudflared tunnel route dns <name> <fqdn>` — creates the CNAME.
4. `scp` the JSON to the host; `sudo install -m 600 -o cloudflared -g cloudflared`
   into `/etc/cloudflared/<uuid>.json`.
5. Edit `machines/<host>/configuration.nix` with the tunnel UUID, ingress, and
   any service-config touch-ups. Commit.
6. `scripts/deploy.sh <host>`.

After deploy, `cloudflared.service` starts automatically. This is comparable
to the existing `tailscale-cert` first-deploy gotcha: a manual step that lands
once and is then declarative forever.

## Failure modes & operations

- **CF edge outage / tunnel disconnected.** Public access fails; tailnet path
  unaffected. `cloudflared` retries indefinitely.
- **Credentials missing or wrong perms.** `systemctl status cloudflared` shows
  the error. Fix file ownership/mode and restart the unit.
- **Adding a new public hostname.** Edit the `ingress` map in Nix; run
  `cloudflared tunnel route dns <name> <new-fqdn>` once; deploy. No tunnel
  recreation.
- **Rotating credentials.** `cloudflared tunnel delete <name>` then recreate.
  Old credentials immediately invalid.
- **Auto-updates.** Disabled — nixpkgs manages the cloudflared version.
- **DNS lifecycle.** CNAMEs live in CF DNS independently of tunnels. If a host
  is removed, the CNAME has to be deleted manually (harmless if left).

## Non-goals

- **Cloudflare Access (auth gate).** All four services have their own auth
  (master password, 2FA, etc.) and native mobile apps that don't speak CF
  Access. Adding it would double-login browser users and break mobile clients.
- **Replacing tailnet access.** Tailnet remains for admin, recovery, and
  internal services (adguard, monitor, dev).
- **Bypassing the tailnet path entirely.** nginx + `tailscale-cert` stays on
  each host as a fallback and admin route.
- **Public exposure of nas (Jellyfin), adguard, monitor, dev.** Out of scope
  for this design; can be added later by following the same pattern.

## Open questions

None. All clarifications resolved in the brainstorming pass.

## Memory updates

After implementation, add a note alongside the existing
`project_tailscale_cert.md`:

> Cloudflare Tunnel hosts need credentials JSON manually installed at
> `/etc/cloudflared/<uuid>.json` (mode 0600, owned by `cloudflared:cloudflared`)
> before the first deploy will succeed.
