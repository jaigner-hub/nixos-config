# Filebrowser on the NAS for file sharing

**Date:** 2026-05-15

## Problem

Want to share files via link with recipients outside the household, and want a
web UI for browsing the NAS tree that isn't in the Nextcloud or Immich data
dirs. Nextcloud already runs (on its own host) but is overkill for casual
share-link use and only sees its own data folder. Samba covers LAN access but
not external sharing.

## Approach

Add the upstream `services.filebrowser` module to the existing `nas` host,
serving `/mnt/storage` as its root. Expose publicly via a per-host
`cloudflared` tunnel at `files.youtalklikeafag.com` — same pattern as the
four existing service tunnels (nextcloud, vaultwarden, immich, paperless).

A single admin user (`jeff`) is seeded from a password file at
`/etc/filebrowser-password`, provisioned out-of-band like the other homelab
secrets.

### Why not Seafile or roll-your-own

Seafile would replace Nextcloud rather than complement it, and uses its own
block-based storage so it can't sit on top of the existing files.
Roll-your-own (nginx autoindex, etc.) doesn't have share-link generation or
auth. Filebrowser is a single Go binary, has a NixOS module, and does exactly
the two things we need: web browse + share links.

### Why on `nas` (not its own host)

The files we want to expose already live on `nas`. Running filebrowser there
avoids re-exporting `/mnt/storage` over NFS just to read it. The host already
has Samba, Jellyfin, NFS, and putio-sync co-resident — one more user-facing
service fits the same shape.

## Scope

- **Host:** `nas`
- **Public hostname:** `files.youtalklikeafag.com`
- **Root served:** `/mnt/storage`
- **Admin user:** `jeff` (single user)

The Nextcloud and Immich data dirs under `/mnt/storage` are already `0700`
owned by their service users, so the `filebrowser` system user cannot read
them. That's the intended access boundary — no extra config required.

## Components

### Per-host NixOS config (additions to `machines/nas/configuration.nix`)

```nix
let
  publicFqdn = "files.youtalklikeafag.com";
  tunnelId = "<FB_UUID>";
in {
  services.filebrowser = {
    enable = true;
    settings = {
      address = "127.0.0.1";
      port = 8334;
      root = "/mnt/storage";
    };
  };

  # Upstream module chmods settings.root to filebrowser:filebrowser 0700
  # via systemd-tmpfiles, which would lock down /mnt/storage and break
  # Samba/Jellyfin/NFS. Force that single rule off; the existing
  # 0755 root:root on /mnt/storage is what we want.
  systemd.tmpfiles.settings.filebrowser."/mnt/storage" = lib.mkForce {};

  # Seed/refresh the admin user from the password file on every start.
  # First start: `update` fails (no user) → `add` creates jeff with admin
  # perms and a scope rooted at /mnt/storage. Subsequent starts: `update`
  # succeeds and re-syncs the password from the file, so rotating means
  # edit the file + restart.
  systemd.services.filebrowser.serviceConfig.ExecStartPre = let
    fb = "${config.services.filebrowser.package}/bin/filebrowser";
    db = config.services.filebrowser.settings.database;
    seed = pkgs.writeShellScript "filebrowser-seed-admin" ''
      set -euo pipefail
      pw=$(cat /etc/filebrowser-password)
      ${fb} -d ${db} users update jeff --password "$pw" 2>/dev/null \
        || ${fb} -d ${db} users add jeff "$pw" --perm.admin --scope /mnt/storage
    '';
  in [ "+${seed}" ];

  services.cloudflared.tunnels.${tunnelId} = {
    credentialsFile = "/etc/cloudflared/${tunnelId}.json";
    default = "http_status:404";
    ingress = {
      ${publicFqdn} = "http://127.0.0.1:8334";
    };
  };

  services.cloudflared.enable = true;

  # Add to the existing restic backups on this host.
  services.restic.backups.filebrowser = {
    paths = [ "/var/lib/filebrowser" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/filebrowser";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 05:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 12" ];
  };
}
```

The `ExecStartPre` uses the `+` prefix so it runs as root (necessary to read
`/etc/filebrowser-password`, which is mode 0600). The main `filebrowser`
process still runs as the `filebrowser` system user.

### Secrets

- `/etc/filebrowser-password` — single line, the admin password. Mode `0600`,
  owner `root:root`. Provisioned out-of-band, never committed.
- `/etc/cloudflared/<FB_UUID>.json` — tunnel credentials. Mode `0600`, owner
  `root:root`. Same shape as the existing four tunnels.
- `/etc/restic/{password,b2.env}` — reused from the existing nextcloud/immich
  backups on this host, nothing new.

### DNS

One CNAME, `files.youtalklikeafag.com` → `<FB_UUID>.cfargotunnel.com`,
created via `cloudflared tunnel route dns` during bootstrap.

## Bootstrap

One-time, mirroring the four existing tunnel hosts.

1. On workstation: `cloudflared tunnel create filebrowser` → record
   `<FB_UUID>`.
2. `cloudflared tunnel route dns filebrowser files.youtalklikeafag.com`.
3. Edit `machines/nas/configuration.nix` with the UUID and new blocks above.
4. `scripts/deploy.sh nas`. The cloudflared unit will fail-closed on first
   start (no creds yet) — expected, same gotcha as the others.
5. `scp ~/.cloudflared/<FB_UUID>.json jeff@nass:/tmp/<FB_UUID>.json` then
   `sudo install -m 600 -o root -g root /tmp/<FB_UUID>.json /etc/cloudflared/`
   on the host.
6. `sudo systemctl restart cloudflared-tunnel-<FB_UUID>.service`.
7. Browse `https://files.youtalklikeafag.com`, log in as `jeff` with the
   password from `/etc/filebrowser-password`.

## Failure modes & operations

- **CF edge outage / tunnel disconnected.** Public access fails; LAN access
  via Samba still works. Filebrowser itself keeps running.
- **`/etc/filebrowser-password` missing or unreadable.** ExecStartPre fails;
  unit fails. Fix the file, `systemctl restart filebrowser`.
- **Rotating admin password.** Edit `/etc/filebrowser-password`,
  `sudo systemctl restart filebrowser`. The ExecStartPre re-syncs.
- **Lost share links.** Restore `/var/lib/filebrowser` from the daily
  restic snapshot.
- **Adding more users.** Filebrowser's admin UI under Settings → Users. Not
  declarative, but acceptable — users are an operational concern, not
  config-as-code. Backed up via restic.

## Non-goals

- **Multi-user accounts in Nix.** Only the bootstrap admin (`jeff`) is
  declarative. Extra accounts, if ever needed, are added via the admin UI.
- **WebDAV / mountable client.** Filebrowser supports it but Nextcloud already
  covers that use case.
- **Anonymous public browsing.** Share links use Filebrowser's per-link
  password/expiry features; the main index always requires login.
- **Tailnet vhost.** `nas` already has Samba for LAN file access; adding an
  nginx + tailscale-cert path for filebrowser would duplicate that without
  adding capability. If a tailnet-only path is wanted later it can be added
  following the existing pattern.
- **Replacing Nextcloud.** Filebrowser is a complement: raw NAS browse + ad
  hoc share links. Nextcloud stays the sync/collab tool.

## Open questions

None.

## Memory updates

No new gotchas — both the cloudflared creds dance and the restic secrets
pattern are already documented. The `lib.mkForce {}` trick for the
filebrowser tmpfiles rule is a one-off worth a code comment in the
configuration, but not a project-wide memory.
