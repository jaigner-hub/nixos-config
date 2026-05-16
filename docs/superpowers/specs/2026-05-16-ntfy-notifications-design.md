# ntfy notifications across the homelab

**Date:** 2026-05-16

## Problem

Several failure-prone systemd units across the fleet currently fail silently:

- `restic-backups-*` on `nas` (nextcloud, immich, filebrowser) and `monitor` (grafana)
- `putio-sync.service` on `nas` (fires every 15 minutes)
- `nextcloud-db-backup.service` on `nextcloud`
- `tailscale-cert.service` on every host using the nginx + tailscale-cert pattern
- `nixos-upgrade.service` on every host (daily pull from GitHub)

Gatus already watches a handful of HTTP/TCP endpoints from `monitor` but has no
notification sink — it can flag a transition only in its own UI. We have no
push channel to surface any of this.

## Approach

Stand up a self-hosted [ntfy](https://ntfy.sh) server on a new dedicated VM
(`auth`, tailnet IP via MagicDNS), exposed only on the tailnet via the existing
`nginx + tailscale-cert` pattern. Every host gains a shared NixOS module that
provides a `ntfy-notify` helper and a `mkOnFailure` Nix function for wiring
unit `OnFailure=` handlers in one line. Gatus on `monitor` gains a
loopback-free outbound HTTP integration to the new server.

### Why a dedicated `auth` VM, not `monitor`

`auth` is being provisioned now as the long-term home for both ntfy and the
upcoming SSO IdP (next spec). Colocating notifications on `monitor` would mean
moving them later when SSO lands and Authentik (or equivalent) wants its own
host. One bootstrap pass on `auth` covers both phases.

### Why tailnet-only, not Cloudflare Tunnel

We don't need ntfy reachable from the open internet. All publishers (homelab
hosts) are on the tailnet; all subscribers (the operator's phone, laptop) run
Tailscale. Public exposure would mean a new ingress to harden and an auth-token
surface to defend.

**Known consequence — iOS push:** the upstream ntfy iOS app uses APNS, which
requires the server to be reachable from Apple's push gateway. A tailnet-only
server can't deliver real APNS pushes; iOS subscribers get notifications only
when the app is foregrounded or via periodic background fetch. Android via the
official app's "instant delivery" (websocket) works on tailnet-only with some
battery cost. If iOS push reliability becomes painful, the fallback is to add
a cloudflared ingress later — additive, doesn't invalidate this design.

### Why systemd `OnFailure=`, not a sidecar process

`OnFailure=` is the native systemd mechanism: it fires exactly when a unit
transitions to `failed`, has zero polling overhead, and inherits the parent
unit's identity for the notification body via `%n`. A polling sidecar or
external probe would add a moving piece without catching anything `OnFailure`
misses.

## Scope

### New host

- `machines/auth/configuration.nix` — hosts `services.ntfy-sh` plus nginx
  termination, on the tailnet only.
- `machines/auth/hardware-configuration.nix` — placeholder (committed, generic
  virtio disk) to satisfy `build-vm`; replaced with real hardware output during
  bootstrap.
- `auth` appended to the `hostNames` list in `flake.nix`.
- `auth:9100` appended to `scrapeTargets` in `machines/monitor/configuration.nix`.

### Shared module

- `common/ntfy-notify.nix` — added to the `imports` list in `common/base.nix`
  so every host picks it up automatically. Provides:
  - `pkgs.ntfy-notify`: a `writeShellScriptBin` that POSTs to ntfy using the
    host-local writer token at `/etc/ntfy-token`.
  - `_module.args.mkNtfyOnFailure { topic, title } unitName`: returns a
    systemd oneshot unit suitable for use as the `OnFailure=` target. Exposed
    via `_module.args` so per-host configs can declare it as a function
    argument.
  - Wires `nixos-upgrade.service` on every host (every host has it).
  - Does **not** wire `tailscale-cert` from here — that unit only exists on
    hosts using the nginx+tailscale-cert pattern, and conditional attrset
    keys in a shared module are fragile. Hosts that have `tailscale-cert`
    wire it themselves in their own config using `mkNtfyOnFailure`.

### Per-host wiring (phase 1)

| Host         | Unit                          | Topic              |
|--------------|-------------------------------|--------------------|
| nas          | `putio-sync.service`          | `homelab-warn`     |
| nas          | `restic-backups-nextcloud`    | `homelab-critical` |
| nas          | `restic-backups-immich`       | `homelab-critical` |
| nas          | `restic-backups-filebrowser`  | `homelab-critical` |
| nextcloud    | `nextcloud-db-backup`         | `homelab-critical` |
| monitor      | `restic-backups-grafana`      | `homelab-critical` |
| (every host) | `nixos-upgrade.service`       | `homelab-warn`     |
| monitor, auth | `tailscale-cert.service`     | `homelab-warn`     |

`nixos-upgrade` wiring lives in `common/ntfy-notify.nix` (shared module);
`tailscale-cert` wiring lives in each host's own config (only hosts that use
the pattern), using `mkNtfyOnFailure` from `_module.args`.

### Gatus integration

`machines/monitor/configuration.nix` gains:

```nix
services.gatus.settings.alerting.ntfy = {
  url = "https://auth.tail1ec6c3.ts.net";
  topic = "homelab-warn";
  token = "$NTFY_TOKEN";  # loaded from /etc/gatus.env
};
```

Each existing Gatus endpoint gains `alerts = [{ type = "ntfy"; failure-threshold = 3; send-on-resolved = true; }]`.

## Components

### ntfy server on `auth`

```nix
services.ntfy-sh = {
  enable = true;
  settings = {
    base-url = "https://auth.tail1ec6c3.ts.net";
    listen-http = "127.0.0.1:2586";
    auth-file = "/var/lib/ntfy-sh/user.db";
    auth-default-access = "deny-all";
    behind-proxy = true;
  };
};
```

Auth is default-deny. The admin user, topic ACLs, and access tokens are
provisioned out-of-band via the ntfy CLI (see Bootstrap), persisted in
`/var/lib/ntfy-sh/user.db` — a SQLite file the systemd unit owns and the
backup story can pick up later if desired.

### nginx + tailscale-cert on `auth`

Mirrors `monitor`'s setup exactly:

```nix
let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "auth.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
in {
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts.${fqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/cert.pem";
      sslCertificateKey = "${certDir}/key.pem";
      locations."/" = {
        proxyPass = "http://127.0.0.1:2586";
        proxyWebsockets = true;  # ntfy uses websockets for instant delivery
      };
    };
  };
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
}
```

Plus the same `systemd.services.tailscale-cert` + weekly timer block already
in `monitor`'s config. (The first-deploy `systemctl start tailscale-cert`
gotcha is already captured in `project_tailscale_cert.md`.)

### `common/ntfy-notify.nix`

```nix
{ config, lib, pkgs, ... }:

let
  ntfyUrl = "https://auth.tail1ec6c3.ts.net";

  ntfy-notify = pkgs.writeShellScriptBin "ntfy-notify" ''
    set -euo pipefail
    topic="$1"; title="$2"; body="$3"
    token=$(cat /etc/ntfy-token)
    ${pkgs.curl}/bin/curl -sS --fail \
      -H "Authorization: Bearer $token" \
      -H "Title: $title" \
      -d "$body" \
      "${ntfyUrl}/$topic"
  '';

  mkOnFailure = { topic, title }: name: {
    description = "ntfy notification for ${name} failure";
    serviceConfig.Type = "oneshot";
    script = ''
      ${ntfy-notify}/bin/ntfy-notify ${topic} "${title}" \
        "$(systemctl status --no-pager --lines=20 ${name} || true)"
    '';
  };
in {
  environment.systemPackages = [ ntfy-notify ];

  # nixos-upgrade exists on every host (autoUpgrade is in common/base.nix).
  systemd.services."ntfy-failed-nixos-upgrade" =
    mkOnFailure { topic = "homelab-warn"; title = "${config.networking.hostName}: nixos-upgrade failed"; }
      "nixos-upgrade.service";
  systemd.services.nixos-upgrade.onFailure = [ "ntfy-failed-nixos-upgrade.service" ];

  # Expose helper to per-host configs for wiring their own service-specific failures.
  _module.args.mkNtfyOnFailure = mkOnFailure;
}
```

`common/base.nix` gains a single line: `imports = [ ./ntfy-notify.nix ];`.

Per-host wiring then looks like (on `nas`):

```nix
{ mkNtfyOnFailure, ... }:
{
  systemd.services."ntfy-failed-putio-sync" =
    mkNtfyOnFailure { topic = "homelab-warn"; title = "nas: putio-sync failed"; }
      "putio-sync.service";
  systemd.services.putio-sync.onFailure = [ "ntfy-failed-putio-sync.service" ];
}
```

And on hosts using nginx+tailscale-cert (`monitor`, `auth`):

```nix
systemd.services."ntfy-failed-tailscale-cert" =
  mkNtfyOnFailure { topic = "homelab-warn"; title = "${config.networking.hostName}: tailscale-cert failed"; }
    "tailscale-cert.service";
systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];
```

### Topic layout

| Topic              | Priority on phone | Used for                                                |
|--------------------|-------------------|---------------------------------------------------------|
| `homelab-critical` | High / paging     | Backup failures, DB dump failures                       |
| `homelab-warn`     | Default           | Cert renewal, auto-upgrade, putio-sync, Gatus down     |
| `homelab-info`     | Min (silent)      | Gatus recoveries, optional informational events         |

One topic per *severity*, not per host or service. Title carries
`<host>: <description>` so the phone UI is self-describing.

### Secrets

- `/var/lib/ntfy-sh/user.db` on `auth` — created and managed by ntfy itself.
- `/etc/ntfy-token` on every host — 0600, root, the writer token for the host.
  Single shared writer token across the fleet; rotating means re-deploying the
  file. Per-host tokens are noise for a homelab.
- `/etc/gatus.env` on `monitor` — `NTFY_TOKEN=<token>`, referenced by the
  existing gatus unit via `EnvironmentFile`. Distinct from the host writer
  token because Gatus reads it as an env var, not from a file.

All three are provisioned out-of-band, same model as `/etc/putio-sync.env`,
`/etc/restic/password`, `/etc/cloudflared/<uuid>.json`.

## Bootstrap

One-time procedure for the new host. After this lands, ongoing changes are
declarative.

1. **Provision the VM** on the Proxmox hypervisor with hostname `auth` and a
   tailnet-routable LAN IP (already done — `jeff@10.0.0.40`). Install NixOS
   minimal if not already; join the tailnet.

2. **Capture hardware config** from the running VM:
   ```
   nixos-generate-config --show-hardware-config > machines/auth/hardware-configuration.nix
   ```
   Commit and push.

3. **First-deploy** from the host console:
   ```
   sudo nixos-rebuild boot --flake github:jaigner-hub/nixos-config#auth
   sudo reboot
   ```
   After reboot, `tailscaled` is up, `jeff` is in `trusted-users` with
   passwordless `sudo`. Subsequent deploys go through `scripts/deploy.sh auth`.

4. **Manually issue the tailscale cert** (same gotcha as every other
   nginx+tailscale-cert host):
   ```
   sudo systemctl start tailscale-cert
   ```

5. **Bootstrap ntfy admin user and writer token** — on `auth` only:
   ```
   sudo -u ntfy-sh ntfy user add --role=admin jeff
   sudo -u ntfy-sh ntfy access jeff "homelab-*" rw
   sudo -u ntfy-sh ntfy token add jeff   # writer token; record the tk_xxx output
   ```

6. **Distribute the writer token** — on every host (including `auth` itself
   for self-notifications), `scp` the token onto the host then:
   ```
   sudo install -m 600 -o root -g root /path/to/token /etc/ntfy-token
   ```

7. **Install the Gatus env file** on `monitor`:
   ```
   sudo install -m 600 -o root -g root <(echo "NTFY_TOKEN=tk_xxxxx") /etc/gatus.env
   ```

8. **Deploy per-host wiring** to all hosts:
   ```
   scripts/deploy.sh
   ```

9. **Subscribe from phone** to `https://auth.tail1ec6c3.ts.net/homelab-critical`,
   `/homelab-warn`, `/homelab-info`. Set per-topic priority in the app:
   critical → High, warn → Default, info → Min.

## Failure modes & operations

- **`auth` down.** All ntfy POSTs fail. `OnFailure` scripts are best-effort —
  failure to notify is logged but doesn't propagate further. Gatus monitors
  ntfy itself (add an endpoint for `https://auth.tail1ec6c3.ts.net/v1/health`)
  so an `auth` outage is itself a notification topic… delivered by Gatus to
  ntfy, which is down. Mitigation: add `auth` to Gatus's check list anyway
  (silent failure during outage is fine — recovery alert lands when it's back).
- **Token leak.** Generate a new token, push to every host, revoke the old one
  via `ntfy token remove`. No deployment changes needed beyond pushing the
  new file.
- **Notification storm.** ntfy has built-in rate limits per topic; configure
  if a misbehaving unit floods.
- **Cert expiry.** `tailscale-cert` weekly timer renews. The `OnFailure` hook
  on that very unit will alert (with the obvious caveat that a broken cert
  also breaks the alert path; tailnet HTTP fallback works during the gap).

## Non-goals

- **Public/internet exposure.** Tailnet-only by design. iOS push limitation is
  the accepted tradeoff; revisit later if needed.
- **Prometheus Alertmanager → ntfy.** Threshold-based alerts (disk full, CPU
  pegged, memory pressure) deferred to a future spec. Gatus + systemd
  `OnFailure` covers the immediate pain.
- **Per-service or per-host topics.** Three severity topics only. Title
  carries the host and service.
- **Backup of `/var/lib/ntfy-sh`.** User DB is small and easy to rebuild; not
  worth a restic timer yet. Add later if the message archive becomes load-bearing.
- **Per-host writer tokens.** Single shared writer token. Homelab threat model
  doesn't justify the per-host attribution.

## Open questions

None — all resolved during brainstorming.

## Memory updates

After implementation, write a new memory note alongside
`project_tailscale_cert.md` and `project_cloudflare_tunnel.md`:

> ntfy first-deploy gotcha: after bootstrapping the `auth` host, the admin
> user and writer token must be created manually via the ntfy CLI before any
> notifications will land. Token then `scp`'d to `/etc/ntfy-token` on every
> host (mode 0600).
