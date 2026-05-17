# RSS Reader (Miniflux) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tailnet-only `rss` host running Miniflux backed by local Postgres, with nginx + `tailscale cert` for TLS and daily encrypted Postgres dumps offsited to B2 via restic.

**Architecture:** New NixOS host added via `mkSystem`/`hostNames` in `flake.nix`. `services.miniflux` listens on `127.0.0.1:8080`, nginx proxies to it on `tailscale0:443` with a `tailscale cert`-issued cert renewed weekly. A daily systemd timer dumps Postgres to `/var/backups/miniflux`, restic snapshots that directory to Backblaze B2 the morning after. Failure of any moving part fires an ntfy notification to `homelab-warn`.

**Tech Stack:** NixOS unstable, Nix flakes, `services.miniflux`, `services.postgresql` (auto-pulled by miniflux module), nginx, `tailscale cert`, restic + Backblaze B2.

**Spec:** `docs/superpowers/specs/2026-05-17-rss-miniflux-design.md`

---

## Notes for the implementer

- Run every command from `/home/enum/Projects/nixos-config`.
- "Build" steps use `nixos-rebuild build` (not `switch`) — they produce `./result` and verify the closure builds without touching the running system. The deploy step (last task) is the only one that touches the live machine.
- The Nix module system is the test runner: clean `nix flake check` + successful `nixos-rebuild build .#rss` is "green."
- Commit messages follow the existing repo style: lowercase, short, host-prefixed, no Conventional Commits — see `git log --oneline`.
- Secrets (`/etc/miniflux-admin-creds`, `/etc/restic/{password,b2.env}`) are provisioned **out-of-band** during the deploy task. The plan steps reference them by path but never put them in the Nix store.
- The user has already provisioned a VM at `10.0.0.27` and intends to join it to the tailnet as `rss`. Tasks 1-8 should be doable without touching that VM at all — only Task 9 (deploy) connects to it.

---

## File Structure

**New files**
- `machines/rss/hardware-configuration.nix` — generic-virtio placeholder, replaced by real config during deploy.
- `machines/rss/configuration.nix` — host module: miniflux + nginx + tailscale-cert + backup + ntfy.

**Modified files**
- `flake.nix` — append `"rss"` to `hostNames`.
- `machines/monitor/configuration.nix` — add `"rss:9100"` to `scrapeTargets`; add a Gatus endpoint for `https://rss.tail1ec6c3.ts.net/healthz`.

No other files change.

---

## Task 1: Scaffold the `rss` host (skeleton only)

Get a minimal host that evaluates and builds. Service config comes in later tasks.

**Files:**
- Create: `machines/rss/hardware-configuration.nix`
- Create: `machines/rss/configuration.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Create the hardware-configuration placeholder**

Verbatim copy of the placeholder used by other recent hosts (`vaultwarden`, `adguard`, `auth`, `paperless`) — same fake UUIDs, generic virtio kernel modules. Replaced with real output from `nixos-generate-config` during the deploy task.

`machines/rss/hardware-configuration.nix`:
```nix
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-uuid/16848dea-65ee-4b8c-9d71-4df779e021fc";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/711D-40F3";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [
    { device = "/dev/disk/by-uuid/656c438f-01c9-4b69-b79f-a696f3bdd349"; }
  ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

- [ ] **Step 2: Create the minimal `configuration.nix`**

`machines/rss/configuration.nix`:
```nix
{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rss";

  system.stateVersion = "25.11";
}
```

- [ ] **Step 3: Register the host in `flake.nix`**

Edit `flake.nix:14-25`. Append `"rss"` to the `hostNames` list, keeping the existing order:

```nix
hostNames = [
  "nas"
  "dev"
  "monitor"
  "nextcloud"
  "vaultwarden"
  "adguard"
  "adguard2"
  "paperless"
  "immich"
  "auth"
  "rss"
];
```

- [ ] **Step 4: Validate the flake**

Run: `nix flake check`
Expected: completes without error. `rss` should now appear in `nixosConfigurations`.

Sanity check: `nix run nixpkgs#colmena -- eval -E '{ nodes, ... }: builtins.attrNames nodes' --impure | grep rss`
Expected: `"rss"` appears in the array.

- [ ] **Step 5: Build the host closure**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully, leaves a `./result` symlink. No `switch`/`activate` happens.

- [ ] **Step 6: Commit**

```
git add machines/rss/hardware-configuration.nix machines/rss/configuration.nix flake.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: scaffold host skeleton"
```

---

## Task 2: Enable `services.miniflux`

Bring up the actual application. Postgres is auto-pulled by the module.

**Files:**
- Modify: `machines/rss/configuration.nix`

- [ ] **Step 1: Add the `services.miniflux` block**

Edit `machines/rss/configuration.nix`. Insert the block below **after** the `networking.hostName = "rss";` line and **before** the `system.stateVersion` line:

```nix
  # Miniflux: single-binary Go RSS reader, Postgres backend (auto-provisioned
  # by the module). Bound to loopback; nginx terminates TLS and proxies in.
  # Admin user seeded from the creds file on first start; provision before
  # first activation or the unit will fail with a missing EnvironmentFile.
  #   printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=<pw>\n' \
  #     | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux-admin-creds";
    config = {
      LISTEN_ADDR = "127.0.0.1:8080";
      BASE_URL = "https://rss.tail1ec6c3.ts.net";
      LOG_FORMAT = "json";
    };
  };
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully. The closure now includes miniflux + postgresql.

- [ ] **Step 3: Commit**

```
git add machines/rss/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: enable miniflux"
```

---

## Task 3: Add nginx reverse proxy

Tailnet TLS termination, no public exposure.

**Files:**
- Modify: `machines/rss/configuration.nix`

- [ ] **Step 1: Add `let` bindings + the `services.nginx` block + firewall**

Edit `machines/rss/configuration.nix`. Wrap the existing body with a `let`/`in` to introduce reusable bindings, then add nginx + firewall.

Replace the entire current contents of `machines/rss/configuration.nix` with:

```nix
{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "rss.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rss";

  # Miniflux: single-binary Go RSS reader, Postgres backend (auto-provisioned
  # by the module). Bound to loopback; nginx terminates TLS and proxies in.
  # Admin user seeded from the creds file on first start; provision before
  # first activation or the unit will fail with a missing EnvironmentFile.
  #   printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=<pw>\n' \
  #     | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux-admin-creds";
    config = {
      LISTEN_ADDR = "127.0.0.1:8080";
      BASE_URL = "https://${tailnetFqdn}";
      LOG_FORMAT = "json";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${tailnetFqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/cert.pem";
      sslCertificateKey = "${certDir}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  system.stateVersion = "25.11";
}
```

(The cert and key paths reference files that the next task's `tailscale-cert` unit will create. Building doesn't require them to exist on the host — they're read at nginx runtime.)

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully.

- [ ] **Step 3: Commit**

```
git add machines/rss/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: nginx reverse proxy on tailnet"
```

---

## Task 4: Add `tailscale cert` issuance & weekly renewal

Mirror the pattern from paperless / immich / vaultwarden. First-run requires manual `systemctl start tailscale-cert.service` (documented gotcha — see `project_tailscale_cert.md` memory note).

**Files:**
- Modify: `machines/rss/configuration.nix`

- [ ] **Step 1: Add the `tailscale-cert` service + timer**

Edit `machines/rss/configuration.nix`. Insert the block below **after** `networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];` and **before** `system.stateVersion`:

```nix
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for rss";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail
      mkdir -p ${certDir}
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file ${certDir}/cert.pem \
        --key-file ${certDir}/key.pem \
        ${tailnetFqdn}
      chown -R nginx:nginx ${certDir}
      chmod 0644 ${certDir}/cert.pem
      chmod 0600 ${certDir}/key.pem
      ${pkgs.systemd}/bin/systemctl reload-or-restart nginx.service || true
    '';
  };

  systemd.timers.tailscale-cert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully.

- [ ] **Step 3: Commit**

```
git add machines/rss/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: tailscale-cert issuance + weekly renewal"
```

---

## Task 5: Add Postgres backup + restic to B2

Daily `pg_dump` into `/var/backups/miniflux`, restic snapshots that directory to Backblaze B2 90 minutes later.

**Files:**
- Modify: `machines/rss/configuration.nix`

- [ ] **Step 1: Extend the `let` block with B2 constants**

Edit `machines/rss/configuration.nix`. Replace the existing `let` block at the top with:

```nix
let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "rss.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
  backupDir = "/var/backups/miniflux";
in
```

- [ ] **Step 2: Add the `miniflux-db-backup` service + timer + restic job**

Insert the block below **after** the `systemd.timers.tailscale-cert` block and **before** `system.stateVersion`:

```nix
  # Ensure the backup dir exists with the right ownership before either the
  # dump or restic try to use it.
  systemd.tmpfiles.rules = [
    "d ${backupDir} 0750 postgres postgres -"
  ];

  # Daily pg_dump of the miniflux DB into the backup dir. Atomic rename so a
  # half-written dump never replaces a good one. Runs as the `postgres` user
  # so it can connect via the default peer-auth unix socket.
  systemd.services.miniflux-db-backup = {
    description = "Dump miniflux Postgres DB for offsite backup";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
    };
    script = ''
      set -euo pipefail
      ${config.services.postgresql.package}/bin/pg_dump \
        --clean --no-owner --no-privileges miniflux \
        | ${pkgs.gzip}/bin/gzip > ${backupDir}/miniflux.sql.gz.tmp
      mv ${backupDir}/miniflux.sql.gz.tmp ${backupDir}/miniflux.sql.gz
    '';
  };

  systemd.timers.miniflux-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # Daily encrypted restic snapshot of the dump dir to Backblaze B2.
  # Runs roughly 90 minutes after the db-backup timer (same pattern as
  # immich) so the dump is always fresh when restic sweeps it up.
  services.restic.backups.rss = {
    paths = [ backupDir ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/rss";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };
```

- [ ] **Step 3: Build**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully.

- [ ] **Step 4: Commit**

```
git add machines/rss/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: postgres dump + restic to b2"
```

---

## Task 6: Add ntfy failure notifications

`mkNtfyOnFailure` helper comes in via `_module.args` from `common/ntfy-notify.nix` (already imported by `common/base.nix`). Pattern matches paperless / immich.

**Files:**
- Modify: `machines/rss/configuration.nix`

- [ ] **Step 1: Add `onFailure` units**

Edit `machines/rss/configuration.nix`. Insert the block below **after** the `services.restic.backups.rss` block and **before** `system.stateVersion`:

```nix
  # ntfy failure notifications. All warn-tier:
  # - miniflux: user-visible if it stays down, but tailnet-only single user.
  # - tailscale-cert: weekly renewal, ~3mo validity → days of recovery time.
  # - miniflux-db-backup / restic: single missed day is recoverable.
  systemd.services."ntfy-failed-miniflux" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "rss: miniflux failed";
    } "miniflux.service";
  systemd.services.miniflux.onFailure = [ "ntfy-failed-miniflux.service" ];

  systemd.services."ntfy-failed-tailscale-cert" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "rss: tailscale-cert failed";
    } "tailscale-cert.service";
  systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];

  systemd.services."ntfy-failed-miniflux-db-backup" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "rss: miniflux-db-backup failed";
    } "miniflux-db-backup.service";
  systemd.services.miniflux-db-backup.onFailure = [ "ntfy-failed-miniflux-db-backup.service" ];

  systemd.services."ntfy-failed-restic-rss" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "rss: restic backup failed";
    } "restic-backups-rss.service";
  systemd.services.restic-backups-rss.onFailure = [ "ntfy-failed-restic-rss.service" ];
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#rss`
Expected: completes successfully.

- [ ] **Step 3: Commit**

```
git add machines/rss/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: ntfy on failure"
```

---

## Task 7: Update monitor (node_exporter scrape + Gatus uptime check)

Two small additions to `machines/monitor/configuration.nix`.

**Files:**
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Add `rss:9100` to the node_exporter scrape targets**

Edit `machines/monitor/configuration.nix`. In the `scrapeTargets` `let` binding (around lines 11-23), insert `"rss:9100"` immediately after `"auth:9100"` so the resulting list reads:

```nix
  scrapeTargets = [
    "monitor:9100"
    "nass:9100"
    "dev:9100"
    "nextcloud:9100"
    "vaultwarden:9100"
    "adguard:9100"
    "adguard2:9100"
    "paperless:9100"
    "immich:9100"
    "auth:9100"
    "rss:9100"
    "10.0.0.55:9100"
  ];
```

- [ ] **Step 2: Add a Gatus endpoint for `rss/healthz`**

Edit `machines/monitor/configuration.nix`. In `services.gatus.settings.endpoints`, insert the following block immediately before the closing `]` of the endpoints list (i.e., after the existing `ntfy` endpoint that ends with `"[BODY].healthy == true"`):

```nix
        {
          name = "rss";
          group = "homelab";
          url = "https://rss.${tailnet}/healthz";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
          alerts = [ { type = "ntfy"; } ];
        }
```

- [ ] **Step 3: Build monitor**

Run: `nixos-rebuild build --flake .#monitor`
Expected: completes successfully.

- [ ] **Step 4: Commit**

```
git add machines/monitor/configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "monitor: scrape rss node_exporter + gatus uptime check"
```

---

## Task 8: VM smoke test

Builds an ephemeral VM from the `rss` configuration. Validates that the closure actually boots and the systemd units come up. `miniflux.service` will fail inside the VM because `/etc/miniflux-admin-creds` doesn't exist — that's expected; the rest of the units (nginx, postgresql, tailscaled, etc.) should be active.

**Files:** none modified.

- [ ] **Step 1: Build the VM**

Run: `nixos-rebuild build-vm --flake .#rss`
Expected: completes successfully, produces `./result/bin/run-rss-vm`.

- [ ] **Step 2: Boot the VM**

Run: `./result/bin/run-rss-vm`
The VM autologins as root (empty password) per `common/base.nix`'s `vmVariant`.

- [ ] **Step 3: Inside the VM — check unit state**

At the VM root prompt:

```
systemctl status nginx postgresql
systemctl status miniflux       # expected: failed (missing /etc/miniflux-admin-creds)
journalctl -u miniflux -n 20 --no-pager
```

Expected:
- `nginx.service` and `postgresql.service` → active (running).
- `miniflux.service` → failed, with a log line mentioning `/etc/miniflux-admin-creds` (env file not found). This is the intended out-of-band-secrets behavior.

- [ ] **Step 4: Inside the VM — write a creds file and restart miniflux**

```
printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=vmtest\n' > /etc/miniflux-admin-creds
chmod 600 /etc/miniflux-admin-creds
systemctl restart miniflux
sleep 3
systemctl is-active miniflux        # expected: active
curl -fsS http://127.0.0.1:8080/healthz && echo OK
```

Expected: `active`, then `OK` (miniflux's `/healthz` returns 200 with no body when DB is reachable).

- [ ] **Step 5: Shut down the VM**

At the VM prompt: `poweroff`

- [ ] **Step 6: No commit**

Nothing changed in the working tree. Skip the commit.

---

## Task 9: Deploy to the real `rss` host

The user has provisioned a VM at `10.0.0.27`. This task joins it to the tailnet, replaces the hardware-config placeholder with the real one, pushes the closure, and brings up out-of-band secrets.

**Files:**
- Modify (after capture from target): `machines/rss/hardware-configuration.nix`

- [ ] **Step 1: Get a shell on the new host and join the tailnet**

Use whatever access you set up when you brought the VM up at `10.0.0.27` — console, password SSH, or pre-installed key. If your username on the install isn't `jeff` yet, that's fine; this task doesn't require it (the user is created by `common/base.nix` on first deploy).

On the rss host:
```
sudo tailscale up --ssh
```
Walk through the auth URL in a browser, approve the device, confirm the hostname `rss`. Then verify:
```
tailscale status | head -2
```
Expected: a line showing `<tailscale-ip>  rss  ...  <tailnet>.ts.net` for the local node.

Once tailscale is up, you can also reach the host via SSH using the tailnet name (`rss.tail1ec6c3.ts.net`) instead of the LAN IP — useful if your LAN access was console-only.

- [ ] **Step 2: Capture real hardware-config from the host**

Still on the rss host:
```
nixos-generate-config --show-hardware-config
```
Copy the **entire output** to your clipboard.

- [ ] **Step 3: Replace the placeholder hardware-config in the repo**

Back on your workstation, replace the entire contents of `machines/rss/hardware-configuration.nix` with the output captured in Step 2.

- [ ] **Step 4: Validate and commit the real hardware-config**

```
nix flake check
nixos-rebuild build --flake .#rss
git add machines/rss/hardware-configuration.nix
git -c gpg.format=ssh -c commit.gpgsign=false commit -m "rss: refresh hardware-configuration from target"
git push origin main
```

- [ ] **Step 5: Provision admin credentials on rss**

On the rss host (via the tailnet now: `ssh jeff@rss.tail1ec6c3.ts.net`):
```
printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=%s\n' '<chosen-password>' \
  | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
```

Substitute a real password for `<chosen-password>`. Don't reuse anything; you can change it via the UI after first login.

- [ ] **Step 6: Provision restic creds on rss**

Copy `/etc/restic/password` and `/etc/restic/b2.env` from any other host that already has them (e.g. paperless):
```
ssh jeff@paperless.tail1ec6c3.ts.net 'sudo cat /etc/restic/password' \
  | ssh jeff@rss.tail1ec6c3.ts.net 'sudo install -m 600 -o root -g root /dev/stdin /etc/restic/password'

ssh jeff@paperless.tail1ec6c3.ts.net 'sudo cat /etc/restic/b2.env' \
  | ssh jeff@rss.tail1ec6c3.ts.net 'sudo install -m 600 -o root -g root /dev/stdin /etc/restic/b2.env'
```

- [ ] **Step 7: First boot-deploy from GitHub**

On the rss host:
```
sudo nixos-rebuild boot --flake github:jaigner-hub/nixos-config#rss
sudo reboot
```

`boot` (not `switch`) avoids live-restarting `boot.mount` during the first activation. Wait for the host to come back up over SSH.

- [ ] **Step 8: Issue the initial TLS cert (known first-deploy gotcha)**

After the reboot finishes and SSH is back:
```
ssh jeff@rss.tail1ec6c3.ts.net 'sudo systemctl start tailscale-cert.service'
ssh jeff@rss.tail1ec6c3.ts.net 'sudo systemctl status tailscale-cert.service --no-pager'
```
Expected: `Active: inactive (dead)` with `status=0/SUCCESS` for the last run; nginx reloaded.

- [ ] **Step 9: Verify miniflux is up**

```
ssh jeff@rss.tail1ec6c3.ts.net 'systemctl is-active miniflux nginx postgresql'
```
Expected: three `active` lines.

```
curl -fsS https://rss.tail1ec6c3.ts.net/healthz && echo OK
```
Expected: `OK` (200 from healthz).

- [ ] **Step 10: Deploy monitor changes (Task 7's commit)**

The monitor changes only take effect once monitor is rebuilt. Run from your workstation:
```
scripts/deploy.sh monitor
```
Expected: monitor activates the new closure. After a minute, the new Gatus endpoint should appear at `https://monitor.tail1ec6c3.ts.net/` (group `homelab`, name `rss`).

- [ ] **Step 11: First login**

Open `https://rss.tail1ec6c3.ts.net` in a browser on a Tailscale-connected device. Log in as `admin` with the password from Step 5. Settings → change password. Optionally Settings → Import to upload an OPML.

- [ ] **Step 12: Sanity-check the backup units**

```
ssh jeff@rss.tail1ec6c3.ts.net 'sudo systemctl start miniflux-db-backup.service && sudo systemctl status miniflux-db-backup.service --no-pager'
ssh jeff@rss.tail1ec6c3.ts.net 'ls -la /var/backups/miniflux/'
```
Expected: backup unit exits 0, `miniflux.sql.gz` exists and is non-empty.

```
ssh jeff@rss.tail1ec6c3.ts.net 'sudo systemctl start restic-backups-rss.service && sudo systemctl status restic-backups-rss.service --no-pager'
```
Expected: restic exits 0; first run should print `repository ... opened (repository version 2) successfully` and a snapshot ID.

- [ ] **Step 13: No new commits**

All commits already pushed in earlier tasks. Done.

---

## Done criteria

- `nix flake check` passes on `main`.
- `https://rss.tail1ec6c3.ts.net` serves the miniflux UI over a valid LE cert.
- `https://rss.tail1ec6c3.ts.net/healthz` returns 200.
- Gatus on `monitor` shows the new `rss` endpoint as healthy.
- Prometheus on `monitor` is scraping `rss:9100` (verify in `https://monitor.tail1ec6c3.ts.net:3000` → Explore → query `up{instance="rss:9100"}` → returns `1`).
- `/var/backups/miniflux/miniflux.sql.gz` exists on rss after the first backup-timer fire.
- A first restic snapshot exists in B2 (`restic -r s3:... snapshots`).
