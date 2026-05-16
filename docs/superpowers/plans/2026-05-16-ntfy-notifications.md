# ntfy Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a self-hosted ntfy server on a new `auth` VM (tailnet-only), wire systemd `OnFailure=` handlers across the fleet, and route Gatus alerts through it so failures stop being silent.

**Architecture:** ntfy runs on a new `auth` host behind nginx + `tailscale-cert`. A shared `common/ntfy-notify.nix` module exposes a `mkNtfyOnFailure` helper that each host uses to wire its own failure-prone units. Three severity topics (`homelab-critical`, `homelab-warn`, `homelab-info`); the title carries `<host>: <description>`.

**Tech Stack:** NixOS unstable, `services.ntfy-sh`, nginx, `tailscale cert`, Gatus's native ntfy alerting integration.

**Spec:** `docs/superpowers/specs/2026-05-16-ntfy-notifications-design.md`

---

## Notes for the implementer

- Run Nix commands from `/home/enum/Projects/nixos-config`.
- "Build" steps use `nixos-rebuild build --flake .#<host>` — produces a `./result` symlink, doesn't touch any live machine.
- "Validate every host" steps use `nix flake check` — evaluates every `nixosConfigurations.<name>.config.system.build.toplevel`, catches option errors fleet-wide.
- Deploys use `scripts/deploy.sh <host>` (probes reachability, then `colmena apply --on <host>`). `scripts/deploy.sh` with no args probes all hosts.
- Commit messages follow the existing style: lowercase, short, host-prefixed (`nas: ...`, `monitor: ...`). No Conventional Commits.
- Hosts are accessed over the tailnet (`<host>.tail1ec6c3.ts.net`); SSH as user `jeff`. Exception: `auth` is reached at `jeff@10.0.0.40` (LAN IP) until tailscale comes up on it.
- ntfy tokens are secrets — never commit any `tk_xxxxx` value.
- `tailscale-cert.service` requires a manual `systemctl start` the first time on any new host (known gotcha, memory: `project_tailscale_cert`).

### Placeholders to substitute throughout

| Token            | Substitute with                                                                |
|------------------|--------------------------------------------------------------------------------|
| `<NTFY_TOKEN>`   | The `tk_xxx...` writer token printed in Task 5.                                |

---

## File Structure

**New files**
- `machines/auth/configuration.nix` — ntfy server + nginx + tailscale-cert.
- `machines/auth/hardware-configuration.nix` — placeholder generic virtio disk initially; replaced with real values in Task 3.
- `common/ntfy-notify.nix` — shared helper module imported by every host.

**Modified files**
- `flake.nix` — add `auth` to `hostNames`.
- `scripts/deploy.sh` — add `auth` (and drive-by-fix the missing `immich`) to the `SSH_TARGET` map.
- `common/base.nix` — add `./ntfy-notify.nix` to `imports`.
- `machines/monitor/configuration.nix` — add `auth:9100` to `scrapeTargets`; add Gatus ntfy alerting; wire `restic-backups-grafana` and `tailscale-cert` to ntfy.
- `machines/nas/configuration.nix` — wire `putio-sync` and three `restic-backups-*` units.
- `machines/nextcloud/configuration.nix` — wire `nextcloud-db-backup`.

**Out-of-repo artifacts** (provisioned out-of-band, never committed)
- `/etc/ntfy-token` on every host (mode 0600, root:root).
- `/etc/gatus.env` on `monitor` (mode 0600, root:root, `NTFY_TOKEN=tk_xxx...`).
- `/var/lib/ntfy-sh/user.db` on `auth` (created by ntfy itself).

---

## Task 1: Add `auth` to the flake with full ntfy config

Create the new host's Nix files and add it to the flake. The full config (ntfy + nginx + tailscale-cert) lands here so the very first deploy in Task 2 boots into a working state.

**Files:**
- Create: `machines/auth/configuration.nix`
- Create: `machines/auth/hardware-configuration.nix`
- Modify: `flake.nix`
- Modify: `scripts/deploy.sh`

- [ ] **Step 1: Create the placeholder `machines/auth/hardware-configuration.nix`**

Copy the existing placeholder from any other host (they're all identical generic-virtio blocks; we'll replace this with real hardware in Task 3). Easiest:

```bash
cp machines/paperless/hardware-configuration.nix machines/auth/hardware-configuration.nix
```

Then open `machines/auth/hardware-configuration.nix` and verify it looks like:

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

The UUIDs are wrong for the real auth VM but that's fine — this file only has to be syntactically valid for `nix flake check` to pass. The real hardware values land in Task 3.

- [ ] **Step 2: Create `machines/auth/configuration.nix`**

Write this exact content:

```nix
{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "auth.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "auth";

  # Self-hosted ntfy. Listens on loopback; nginx terminates TLS using the
  # tailscale-issued cert (same pattern as monitor's gatus vhost).
  #
  # auth-default-access = "deny-all" forces every publish/subscribe to carry
  # a valid token. Admin user + tokens are bootstrapped out-of-band via the
  # ntfy CLI on first deploy — they live in /var/lib/ntfy-sh/user.db, which
  # ntfy manages itself.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${fqdn}";
      listen-http = "127.0.0.1:2586";
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";
      behind-proxy = true;
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${fqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/cert.pem";
      sslCertificateKey = "${certDir}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:2586";
        proxyWebsockets = true;
      };
    };
  };

  # tailscale0 is trusted via common/base.nix. Open 443 on the tailnet
  # for nginx.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  # First-deploy gotcha: this unit must be manually started once
  # (`sudo systemctl start tailscale-cert`) before nginx will find the
  # cert files. The timer keeps it renewed weekly after that.
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for auth (ntfy)";
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
        ${fqdn}
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

  system.stateVersion = "25.11";
}
```

- [ ] **Step 3: Add `auth` to `flake.nix`**

Edit `flake.nix:14-24`. Append `"auth"` to the `hostNames` list. The list becomes:

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
      ];
```

No need to edit `targetHostFor` — `auth`'s directory name matches its hostname (unlike `nas`/`nass`).

- [ ] **Step 4: Add `auth` (and `immich`) to `scripts/deploy.sh`**

The deploy script has its own `SSH_TARGET` map and currently doesn't list `immich` (pre-existing gap) or `auth` (new host). Without these, `scripts/deploy.sh` with no args silently skips them.

Edit `scripts/deploy.sh:13-22`. The map becomes:

```bash
declare -A SSH_TARGET=(
  [adguard]=adguard
  [adguard2]=adguard2
  [auth]=auth
  [dev]=dev
  [immich]=immich
  [monitor]=monitor
  [nas]=nass
  [nextcloud]=nextcloud
  [paperless]=paperless
  [vaultwarden]=vaultwarden
)
```

(Alphabetic ordering matches the existing style.)

- [ ] **Step 5: Validate the flake**

Run: `nix flake check`
Expected: no errors. Every host (including the new `auth`) evaluates cleanly.

If `auth` fails with an option error, double-check that `services.ntfy-sh` exists in the pinned nixpkgs:

```
nix eval .#nixosConfigurations.auth.options.services.ntfy-sh.enable.description
```

- [ ] **Step 6: Build `auth`**

Run: `nixos-rebuild build --flake .#auth`
Expected: produces `./result` symlink, no errors. This is a sanity check before pushing to GitHub (the bootstrap pulls from there).

- [ ] **Step 7: Commit and push**

```bash
git add machines/auth/configuration.nix machines/auth/hardware-configuration.nix flake.nix scripts/deploy.sh
git commit -m "auth: new host for ntfy and (eventually) SSO"
git push
```

Pushing is mandatory — Task 2 bootstraps the VM by pulling this commit from GitHub.

---

## Task 2: First-boot bootstrap of the `auth` VM

Manual procedure on the VM console (or initial SSH session) to bring it from a fresh NixOS install to a colmena-deployable state. Mirrors the pattern in `CLAUDE.md` under "Bootstrapping a new host."

**Files:** none in the repo. All steps run on the VM itself.

- [ ] **Step 1: Confirm SSH access**

From your workstation:

```bash
ssh jeff@10.0.0.40 'whoami && hostname'
```

Expected: `jeff` and the current hostname of the VM (may not yet be `auth` — that's fine, the rebuild fixes it).

If SSH is refused, the VM likely needs its initial NixOS install configured to start sshd and allow `jeff`'s key. Resolve that out-of-band (it's not part of this plan).

- [ ] **Step 2: Capture real hardware config on the VM**

```bash
ssh jeff@10.0.0.40 'sudo nixos-generate-config --show-hardware-config'
```

Expected: prints a Nix expression with the real disk UUIDs and kernel modules for this VM. **Copy the entire output** — you'll paste it into `machines/auth/hardware-configuration.nix` in Task 3.

Save it to a tmp file on your workstation so you don't lose it:

```bash
ssh jeff@10.0.0.40 'sudo nixos-generate-config --show-hardware-config' > /tmp/auth-hardware.nix
```

- [ ] **Step 3: Run the first-boot rebuild from the GitHub flake**

```bash
ssh jeff@10.0.0.40 'sudo nixos-rebuild boot --flake github:jaigner-hub/nixos-config#auth'
```

Expected: pulls the flake from GitHub, builds, and sets the new generation as the default for the next boot. No errors. Takes a few minutes.

Using `boot` (not `switch`) avoids restarting `boot.mount` live, which can hang when disk layouts shift. (Same precaution as `CLAUDE.md`'s bootstrap section.)

If the build fails with a missing `services.ntfy-sh` option, the pinned nixpkgs may not have it yet — abort this plan, bump the flake input, retry from Task 1 step 4.

- [ ] **Step 4: Reboot the VM**

```bash
ssh jeff@10.0.0.40 'sudo reboot'
```

Wait ~30 seconds, then verify it's back:

```bash
ssh jeff@10.0.0.40 'hostname'
```

Expected: `auth` (the hostname is now set by the Nix config).

- [ ] **Step 5: Verify tailscale joined the tailnet**

The VM may already be on the tailnet from earlier work; if not, register it now:

```bash
ssh jeff@10.0.0.40 'sudo tailscale status' || ssh jeff@10.0.0.40 'sudo tailscale up'
```

The first form prints status if connected. If not connected, `tailscale up` triggers the login URL — paste it into a browser and authorize.

Once connected, verify:

```bash
ssh jeff@auth.tail1ec6c3.ts.net 'hostname'
```

Expected: `auth`. From here on, deploys reach it via the tailnet MagicDNS name, not the LAN IP.

- [ ] **Step 6: Confirm `jeff` has passwordless sudo**

```bash
ssh jeff@auth.tail1ec6c3.ts.net 'sudo -n true && echo ok'
```

Expected: `ok`. (`common/base.nix` sets `security.sudo.wheelNeedsPassword = false`.)

No commit yet — Task 3 captures the hardware config back into the repo.

---

## Task 3: Capture real hardware config and add auth to monitoring

Replace the placeholder hardware-configuration.nix with the values from the running VM, and add `auth:9100` to monitor's scrape targets. Both changes are small enough to bundle.

**Files:**
- Modify: `machines/auth/hardware-configuration.nix`
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Replace `machines/auth/hardware-configuration.nix` with the captured values**

Open `machines/auth/hardware-configuration.nix` and replace its entire contents with the output saved to `/tmp/auth-hardware.nix` in Task 2 step 2:

```bash
cp /tmp/auth-hardware.nix machines/auth/hardware-configuration.nix
```

Inspect the result. It should be a Nix expression of the same shape as the placeholder, with the real disk UUIDs.

- [ ] **Step 2: Add `auth:9100` to monitor's scrape targets**

Edit `machines/monitor/configuration.nix:11-21`. The `scrapeTargets` list becomes:

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
    "auth:9100"
    "10.0.0.55:9100"
  ];
```

Order matches the existing alphabetic-ish drift; placing `auth` near the bottom keeps the diff small.

- [ ] **Step 3: Validate the flake**

Run: `nix flake check`
Expected: no errors.

- [ ] **Step 4: Build `auth` and `monitor`**

Run:

```bash
nixos-rebuild build --flake .#auth
nixos-rebuild build --flake .#monitor
```

Expected: both build cleanly.

- [ ] **Step 5: Deploy to both hosts**

Run: `scripts/deploy.sh auth monitor`
Expected: both deploys succeed. Auth's deploy is now happening over the tailnet (vs the GitHub-pull bootstrap), via colmena.

- [ ] **Step 6: Verify node_exporter is reachable from monitor**

```bash
ssh jeff@monitor 'curl -sI http://auth:9100/metrics'
```

Expected: `HTTP/1.1 200 OK`. Prometheus picks it up automatically on the next scrape interval (15s default).

- [ ] **Step 7: Verify ntfy is running on `auth` (but unreachable yet)**

```bash
ssh jeff@auth 'systemctl status ntfy-sh.service --no-pager'
```

Expected: `Active: active (running)`. The unit is up; nginx isn't serving yet because the tailscale cert files don't exist (that's Task 4).

`curl https://auth.tail1ec6c3.ts.net/` from another host should currently fail with a connection-refused / SSL error — that's expected at this point.

- [ ] **Step 8: Commit**

```bash
git add machines/auth/hardware-configuration.nix machines/monitor/configuration.nix
git commit -m "auth: capture real hardware-config; monitor scrapes auth"
```

---

## Task 4: Issue the tailscale cert and verify ntfy responds

Manual one-time activation of `tailscale-cert` on auth, plus the end-to-end health check that says "nginx can now front ntfy."

**Files:** none.

- [ ] **Step 1: Start the `tailscale-cert` unit manually**

```bash
ssh jeff@auth 'sudo systemctl start tailscale-cert'
```

Expected: command exits cleanly. The unit is `Type=oneshot`, so it runs to completion and stops.

Verify:

```bash
ssh jeff@auth 'sudo systemctl status tailscale-cert --no-pager'
```

Expected: `Active: inactive (dead)` with `code=exited, status=0/SUCCESS`. (Oneshots show inactive after a successful run — that's correct.)

Cert files should now exist:

```bash
ssh jeff@auth 'ls -la /var/lib/tailscale-cert/'
```

Expected: `cert.pem` (mode 0644, owned by nginx) and `key.pem` (mode 0600, owned by nginx).

- [ ] **Step 2: Verify nginx picked up the cert**

```bash
ssh jeff@auth 'sudo systemctl status nginx --no-pager'
```

Expected: `Active: active (running)`. The tailscale-cert script ends with `reload-or-restart nginx`, so the new cert is already loaded.

- [ ] **Step 3: Verify ntfy responds over HTTPS**

From any host on the tailnet (or your workstation, if it's tailscale-joined):

```bash
curl -s https://auth.tail1ec6c3.ts.net/v1/health
```

Expected: `{"healthy":true}` (or similar; ntfy returns JSON).

If you get a connection refused, recheck nginx status. If you get a 401, you're somehow hitting an auth-protected endpoint — `/v1/health` should be open. (`auth-default-access = deny-all` applies to publish/subscribe, not the health endpoint.)

No commit — `tailscale-cert` is a runtime artifact, no repo change.

---

## Task 5: Bootstrap the ntfy admin user and writer token

Create the admin user, set ACLs, and mint the writer token that every host will use to publish. Token is recorded for use in Tasks 6+.

**Files:** none in the repo.

- [ ] **Step 1: Create the admin user**

```bash
ssh jeff@auth 'sudo -u ntfy-sh ntfy user add --role=admin jeff'
```

Expected: prompts for a password (set a strong one — record it in your password manager). Confirms `user jeff added with role admin`.

The `ntfy-sh` system user owns `/var/lib/ntfy-sh/user.db`, hence the `sudo -u ntfy-sh`.

- [ ] **Step 2: Grant `jeff` access to the `homelab-*` topic pattern**

```bash
ssh jeff@auth 'sudo -u ntfy-sh ntfy access jeff "homelab-*" rw'
```

Expected: `granted rw access for user jeff on topic "homelab-*"`.

Topics matching `homelab-critical`, `homelab-warn`, `homelab-info` (and any future `homelab-<anything>`) are now readable and writable by jeff.

- [ ] **Step 3: Mint the writer token**

```bash
ssh jeff@auth 'sudo -u ntfy-sh ntfy token add jeff'
```

Expected: prints a token starting with `tk_`. **Record this value as `<NTFY_TOKEN>`** — you'll paste it into files on every host in Task 7 and into `/etc/gatus.env` in Task 12.

The token doesn't expire by default. Rotating means `ntfy token remove jeff <token-id>` followed by `ntfy token add jeff` and redistributing.

- [ ] **Step 4: Sanity-check the token works**

From the auth host itself:

```bash
ssh jeff@auth 'curl -sS -H "Authorization: Bearer <NTFY_TOKEN>" -d "bootstrap test" https://auth.tail1ec6c3.ts.net/homelab-info'
```

Expected: JSON response with `"id":"..."`, `"event":"message"`, `"message":"bootstrap test"`.

The publish succeeded against the locally-defined endpoint. No subscribers yet, so the message just sits in ntfy's cache.

No commit.

---

## Task 6: Create `common/ntfy-notify.nix` and wire it fleet-wide

Add the shared helper module, import it from `common/base.nix`, deploy to every host. `nixos-upgrade` is wired here (every host has it); per-service wiring is in later tasks.

**Files:**
- Create: `common/ntfy-notify.nix`
- Modify: `common/base.nix`

- [ ] **Step 1: Create `common/ntfy-notify.nix`**

Write this exact content:

```nix
{ config, lib, pkgs, ... }:

let
  ntfyUrl = "https://auth.tail1ec6c3.ts.net";

  # POSTs $3 to ntfy topic $1 with title $2, using the writer token at
  # /etc/ntfy-token. Fails-silent on network/curl errors so a missing token
  # or down ntfy server doesn't cascade into more unit failures.
  ntfy-notify = pkgs.writeShellScriptBin "ntfy-notify" ''
    set -euo pipefail
    topic="$1"; title="$2"; body="$3"
    if [ ! -r /etc/ntfy-token ]; then
      echo "ntfy-notify: /etc/ntfy-token missing or unreadable; skipping" >&2
      exit 0
    fi
    token=$(cat /etc/ntfy-token)
    ${pkgs.curl}/bin/curl -sS --max-time 10 \
      -H "Authorization: Bearer $token" \
      -H "Title: $title" \
      -d "$body" \
      "${ntfyUrl}/$topic" || \
      echo "ntfy-notify: publish to $topic failed" >&2
  '';

  # Returns a systemd oneshot service definition that calls ntfy-notify with
  # the given topic/title and a body containing the last 20 lines of
  # `systemctl status` for the failing unit. Use as the OnFailure= target.
  mkOnFailure = { topic, title }: unitName: {
    description = "ntfy notification for ${unitName} failure";
    serviceConfig.Type = "oneshot";
    script = ''
      ${ntfy-notify}/bin/ntfy-notify ${topic} "${title}" \
        "$(${pkgs.systemd}/bin/systemctl status --no-pager --lines=20 ${unitName} || true)"
    '';
  };
in {
  environment.systemPackages = [ ntfy-notify ];

  # nixos-upgrade.service exists on every host via common/base.nix's
  # system.autoUpgrade block. Wire it here so all hosts get coverage
  # without each one repeating the pattern.
  systemd.services."ntfy-failed-nixos-upgrade" =
    mkOnFailure {
      topic = "homelab-warn";
      title = "${config.networking.hostName}: nixos-upgrade failed";
    } "nixos-upgrade.service";
  systemd.services.nixos-upgrade.onFailure = [ "ntfy-failed-nixos-upgrade.service" ];

  # Expose the helper to per-host configs via _module.args so they can wire
  # their own service-specific failures (e.g. restic, putio-sync, db-backup).
  _module.args.mkNtfyOnFailure = mkOnFailure;
}
```

- [ ] **Step 2: Import the new module from `common/base.nix`**

`common/base.nix` currently has no `imports` line. Add one near the top of the body (right after the opening `{` on line 3). The first few lines become:

```nix
{ config, pkgs, claude-code-nix, hostKey, ... }:

{
  imports = [ ./ntfy-notify.nix ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

- [ ] **Step 3: Validate the flake**

Run: `nix flake check`
Expected: every host evaluates cleanly. If any host complains about `mkNtfyOnFailure` being undefined, you tried to use it in that host's config before this task lands — back out the offending change.

- [ ] **Step 4: Build all hosts**

Run: `for h in nas dev monitor nextcloud vaultwarden adguard adguard2 paperless immich auth; do echo "=== $h ==="; nixos-rebuild build --flake .#$h || break; done`

Expected: all 10 hosts build. If one fails, stop and investigate before deploying anything.

- [ ] **Step 5: Deploy fleet-wide**

Run: `scripts/deploy.sh`
Expected: deploys to every reachable host. The `ntfy-failed-nixos-upgrade.service` units now exist on every host but won't fire until `nixos-upgrade.service` itself fails. Token files don't exist yet — that's Task 7.

- [ ] **Step 6: Verify the unit exists on one host**

```bash
ssh jeff@nass 'systemctl cat ntfy-failed-nixos-upgrade.service'
```

Expected: prints the generated unit. The `ExecStart=` line references the `ntfy-notify` script from `/nix/store/...`.

- [ ] **Step 7: Commit**

```bash
git add common/ntfy-notify.nix common/base.nix
git commit -m "common: ntfy-notify helper module"
```

---

## Task 7: Distribute the writer token to every host

Install `/etc/ntfy-token` on every host (including `auth` for self-notifications). One file, one mode, one owner — repeated 10 times.

**Files:** none in the repo.

- [ ] **Step 1: Write the token to a tmp file on your workstation**

```bash
umask 077
echo -n '<NTFY_TOKEN>' > /tmp/ntfy-token
```

The `-n` matters: no trailing newline. `umask 077` makes the tmp file 0600 from the start.

- [ ] **Step 2: Distribute to every host**

Use the *SSH* hostnames (tailscale MagicDNS short names), not the flake directory names — `nas`'s host is `nass`. All others match:

```bash
for h in nass dev monitor nextcloud vaultwarden adguard adguard2 paperless immich auth; do
  echo "=== $h ==="
  scp /tmp/ntfy-token jeff@$h:/tmp/ntfy-token && \
    ssh jeff@$h 'sudo install -m 600 -o root -g root /tmp/ntfy-token /etc/ntfy-token && rm /tmp/ntfy-token' || \
    echo "FAILED on $h"
done
```

Expected: each host prints its name and no `FAILED` lines.

- [ ] **Step 3: Clean up the workstation tmp file**

```bash
rm /tmp/ntfy-token
```

- [ ] **Step 4: Verify on one host**

```bash
ssh jeff@nass 'sudo ls -la /etc/ntfy-token'
```

Expected: `-rw------- 1 root root <len> ... /etc/ntfy-token`.

- [ ] **Step 5: End-to-end test the helper**

```bash
ssh jeff@nass 'sudo ntfy-notify homelab-info "nas: ntfy-notify smoke test" "if you see this, the helper works"'
```

Expected: command exits cleanly with no error output.

On `auth` (or anywhere), confirm the message landed:

```bash
ssh jeff@auth 'curl -sS -H "Authorization: Bearer <NTFY_TOKEN>" "https://auth.tail1ec6c3.ts.net/homelab-info/json?poll=1&since=1m"'
```

Expected: one JSON object per recent message. The `nas: ntfy-notify smoke test` message should be in there.

- [ ] **Step 6: Fire the auto-wired failure handler manually**

```bash
ssh jeff@nass 'sudo systemctl start ntfy-failed-nixos-upgrade.service'
```

Expected: completes cleanly. A new message in `homelab-warn` with title `nas: nixos-upgrade failed` and body containing `systemctl status nixos-upgrade.service` output should now exist in ntfy.

Verify same way as Step 5 but against `/homelab-warn/json?poll=1&since=1m`.

No commit.

---

## Task 8: Wire `nas` service failures

Add OnFailure handlers for `putio-sync` and the three `restic-backups-*` units.

**Files:**
- Modify: `machines/nas/configuration.nix`

- [ ] **Step 1: Add the wiring block to `machines/nas/configuration.nix`**

Edit the function signature at the top of the file. Currently it's:

```nix
{ config, lib, pkgs, claude-code-nix, ... }:
```

Change to:

```nix
{ config, lib, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:
```

Then append the following block just before the final `system.stateVersion = "25.11";` line:

```nix
  systemd.services."ntfy-failed-putio-sync" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "nas: putio-sync failed";
    } "putio-sync.service";
  systemd.services.putio-sync.onFailure = [ "ntfy-failed-putio-sync.service" ];

  systemd.services."ntfy-failed-restic-nextcloud" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic backup (nextcloud) failed";
    } "restic-backups-nextcloud.service";
  systemd.services.restic-backups-nextcloud.onFailure = [ "ntfy-failed-restic-nextcloud.service" ];

  systemd.services."ntfy-failed-restic-immich" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic backup (immich) failed";
    } "restic-backups-immich.service";
  systemd.services.restic-backups-immich.onFailure = [ "ntfy-failed-restic-immich.service" ];

  systemd.services."ntfy-failed-restic-filebrowser" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nas: restic backup (filebrowser) failed";
    } "restic-backups-filebrowser.service";
  systemd.services.restic-backups-filebrowser.onFailure = [ "ntfy-failed-restic-filebrowser.service" ];
```

- [ ] **Step 2: Build `nas`**

Run: `nixos-rebuild build --flake .#nas`
Expected: builds cleanly.

- [ ] **Step 3: Deploy**

Run: `scripts/deploy.sh nas`
Expected: deploy succeeds.

- [ ] **Step 4: Verify a handler fires**

Manually trigger the putio-sync handler (cheap to test — doesn't actually invoke putio-sync):

```bash
ssh jeff@nass 'sudo systemctl start ntfy-failed-putio-sync.service'
```

Confirm the message arrived (any subscribed client, or curl from auth):

```bash
ssh jeff@auth 'curl -sS -H "Authorization: Bearer <NTFY_TOKEN>" "https://auth.tail1ec6c3.ts.net/homelab-warn/json?poll=1&since=1m" | grep "putio-sync failed"'
```

Expected: line containing `"title":"nas: putio-sync failed"`.

- [ ] **Step 5: Commit**

```bash
git add machines/nas/configuration.nix
git commit -m "nas: wire putio-sync and restic failures to ntfy"
```

---

## Task 9: Wire `nextcloud` service failures

Add an OnFailure handler for `nextcloud-db-backup`.

**Files:**
- Modify: `machines/nextcloud/configuration.nix`

- [ ] **Step 1: Add the wiring block to `machines/nextcloud/configuration.nix`**

Edit the function signature. Currently:

```nix
{ config, pkgs, claude-code-nix, ... }:
```

Change to:

```nix
{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:
```

Append before the final `system.stateVersion = "25.11";` line:

```nix
  systemd.services."ntfy-failed-nextcloud-db-backup" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nextcloud: db-backup failed";
    } "nextcloud-db-backup.service";
  systemd.services.nextcloud-db-backup.onFailure = [ "ntfy-failed-nextcloud-db-backup.service" ];
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#nextcloud`
Expected: builds cleanly.

- [ ] **Step 3: Deploy**

Run: `scripts/deploy.sh nextcloud`
Expected: deploy succeeds.

- [ ] **Step 4: Verify the handler fires**

```bash
ssh jeff@nextcloud 'sudo systemctl start ntfy-failed-nextcloud-db-backup.service'
```

Confirm via curl that `homelab-critical` received `nextcloud: db-backup failed`.

- [ ] **Step 5: Commit**

```bash
git add machines/nextcloud/configuration.nix
git commit -m "nextcloud: wire db-backup failure to ntfy"
```

---

## Task 10: Wire `monitor` service failures

Add OnFailure handlers for `restic-backups-grafana` and `tailscale-cert`.

**Files:**
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Add the wiring block to `machines/monitor/configuration.nix`**

Edit the function signature. Currently:

```nix
{ config, pkgs, claude-code-nix, ... }:
```

Change to:

```nix
{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:
```

Append before the final `system.stateVersion = "25.11";` line:

```nix
  systemd.services."ntfy-failed-restic-grafana" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "monitor: restic backup (grafana) failed";
    } "restic-backups-grafana.service";
  systemd.services.restic-backups-grafana.onFailure = [ "ntfy-failed-restic-grafana.service" ];

  systemd.services."ntfy-failed-tailscale-cert" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "monitor: tailscale-cert failed";
    } "tailscale-cert.service";
  systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#monitor`
Expected: builds cleanly.

- [ ] **Step 3: Deploy**

Run: `scripts/deploy.sh monitor`
Expected: deploy succeeds.

- [ ] **Step 4: Verify the handlers fire**

```bash
ssh jeff@monitor 'sudo systemctl start ntfy-failed-restic-grafana.service'
ssh jeff@monitor 'sudo systemctl start ntfy-failed-tailscale-cert.service'
```

Confirm `homelab-critical` got `monitor: restic backup (grafana) failed` and `homelab-warn` got `monitor: tailscale-cert failed`.

- [ ] **Step 5: Commit**

```bash
git add machines/monitor/configuration.nix
git commit -m "monitor: wire restic-grafana and tailscale-cert failures to ntfy"
```

---

## Task 11: Wire `auth` tailscale-cert failures

Self-notification on the auth host (it also uses the tailscale-cert pattern).

**Files:**
- Modify: `machines/auth/configuration.nix`

- [ ] **Step 1: Add the wiring block to `machines/auth/configuration.nix`**

Edit the function signature. Currently:

```nix
{ config, pkgs, claude-code-nix, ... }:
```

Change to:

```nix
{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:
```

Append before the final `system.stateVersion = "25.11";` line:

```nix
  systemd.services."ntfy-failed-tailscale-cert" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "auth: tailscale-cert failed";
    } "tailscale-cert.service";
  systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];
```

- [ ] **Step 2: Build**

Run: `nixos-rebuild build --flake .#auth`
Expected: builds cleanly.

- [ ] **Step 3: Deploy**

Run: `scripts/deploy.sh auth`
Expected: deploy succeeds.

- [ ] **Step 4: Verify the handler fires**

```bash
ssh jeff@auth 'sudo systemctl start ntfy-failed-tailscale-cert.service'
```

Confirm `homelab-warn` got `auth: tailscale-cert failed`.

- [ ] **Step 5: Commit**

```bash
git add machines/auth/configuration.nix
git commit -m "auth: wire tailscale-cert failure to ntfy"
```

---

## Task 12: Gatus → ntfy alerting

Add the ntfy alerting destination to Gatus on `monitor`, plus per-endpoint alert blocks. Gatus reads the token from `/etc/gatus.env`.

**Files:**
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Install `/etc/gatus.env` on `monitor`**

On your workstation:

```bash
umask 077
echo "NTFY_TOKEN=<NTFY_TOKEN>" > /tmp/gatus.env
scp /tmp/gatus.env jeff@monitor:/tmp/gatus.env
ssh jeff@monitor 'sudo install -m 600 -o root -g root /tmp/gatus.env /etc/gatus.env && rm /tmp/gatus.env'
rm /tmp/gatus.env
```

Verify:

```bash
ssh jeff@monitor 'sudo cat /etc/gatus.env'
```

Expected: `NTFY_TOKEN=tk_xxxxx` (one line, no surrounding quotes).

- [ ] **Step 2: Add `EnvironmentFile` to the Gatus systemd unit**

The nixpkgs `services.gatus` module doesn't expose `environmentFile` directly, so override the unit. Edit `machines/monitor/configuration.nix`. Append before the final `system.stateVersion = "25.11";` line:

```nix
  systemd.services.gatus.serviceConfig.EnvironmentFile = "/etc/gatus.env";
```

- [ ] **Step 3: Add the ntfy alerting destination**

In `machines/monitor/configuration.nix`, find the `services.gatus.settings` block. It currently has `web`, `metrics`, and `endpoints` keys. Add an `alerting` key as a sibling (place it between `metrics` and `endpoints`):

```nix
      alerting = {
        ntfy = {
          url = "https://auth.tail1ec6c3.ts.net";
          topic = "homelab-warn";
          token = "$NTFY_TOKEN";
          default-alert = {
            failure-threshold = 3;
            success-threshold = 2;
            send-on-resolved = true;
          };
        };
      };
```

The `$NTFY_TOKEN` literal is the env-var reference Gatus expands at startup (loaded from `/etc/gatus.env` via the systemd `EnvironmentFile` set in step 2).

- [ ] **Step 4: Add `alerts` to each endpoint**

In the same `services.gatus.settings.endpoints` list, every endpoint object needs an `alerts` field. The existing objects look like:

```nix
{
  name = "adguard-ui";
  group = "homelab";
  url = "https://adguard.${tailnet}/";
  interval = "1m";
  conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
}
```

Add `alerts = [ { type = "ntfy"; } ];` to each one. The block becomes:

```nix
{
  name = "adguard-ui";
  group = "homelab";
  url = "https://adguard.${tailnet}/";
  interval = "1m";
  conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
  alerts = [ { type = "ntfy"; } ];
}
```

Do this for all 10 endpoints (`adguard-ui`, `adguard-dns`, `adguard2-ui`, `adguard2-dns`, `vaultwarden`, `nextcloud`, `paperless`, `jellyfin`, `grafana`, `prometheus`). The `default-alert` block in step 3 supplies the threshold/resolved settings — `[ { type = "ntfy"; } ]` is enough per endpoint.

- [ ] **Step 5: Add a Gatus endpoint for ntfy itself**

While we're here, add ntfy to the endpoint list so an `auth` outage shows up in Gatus too. Add this as a new entry in the `endpoints` list:

```nix
{
  name = "ntfy";
  group = "internal";
  url = "https://auth.${tailnet}/v1/health";
  interval = "1m";
  conditions = [ "[STATUS] == 200" "[BODY].healthy == true" ];
  alerts = [ { type = "ntfy"; } ];
}
```

Yes, ntfy alerts on its own outage will themselves fail to deliver. The recovery alert lands when it's back — that's the value.

- [ ] **Step 6: Validate the flake**

Run: `nix flake check`
Expected: no errors.

- [ ] **Step 7: Build**

Run: `nixos-rebuild build --flake .#monitor`
Expected: builds cleanly.

- [ ] **Step 8: Deploy**

Run: `scripts/deploy.sh monitor`
Expected: deploy succeeds.

- [ ] **Step 9: Verify Gatus loaded the env file**

```bash
ssh jeff@monitor 'sudo systemctl show gatus -p Environment'
```

Expected: a line including `NTFY_TOKEN=tk_xxxxx`. (The systemd `EnvironmentFile=` directive surfaces in `show -p Environment`.)

- [ ] **Step 10: Trigger a Gatus alert by force-failing an endpoint**

Easiest way without breaking real services: temporarily change one of the Gatus endpoint URLs to something that returns 404 (then revert). Or, simpler, stop one of the watched services for >3 minutes:

```bash
ssh jeff@adguard 'sudo systemctl stop adguardhome' && \
  sleep 240 && \
  ssh jeff@adguard 'sudo systemctl start adguardhome'
```

`adguardhome` is the upstream-named unit; if it's called something else on your install, look it up first with `systemctl list-units | grep -i adguard`.

After 3 failed checks (Gatus's `failure-threshold = 3` with `interval = "1m"` means ~3 minutes), `homelab-warn` should receive an `[ALERT] adguard-ui` message. After it recovers, you should get a `[RESOLVED] adguard-ui` message.

If nothing shows up, check `journalctl -u gatus -n 100` for ntfy errors. A 401 from ntfy means the token didn't reach Gatus's env; verify Step 9.

- [ ] **Step 11: Commit**

```bash
git add machines/monitor/configuration.nix
git commit -m "monitor: route gatus alerts through ntfy"
```

---

## Task 13: Subscribe phone + end-to-end verification

Final manual verification that the system works from the operator's phone.

**Files:** none.

- [ ] **Step 1: Install the ntfy app on your phone**

Android: `ntfy` in F-Droid or Google Play.
iOS: `ntfy` in the App Store.

- [ ] **Step 2: Configure the default server**

In the app settings, set the default server to `https://auth.tail1ec6c3.ts.net`. Ensure your phone is on the tailnet (Tailscale app running, connected) before you subscribe — the server is tailnet-only.

- [ ] **Step 3: Subscribe to all three topics**

In the app, add three subscriptions:

| Topic               | Server                                 | Auth                          | Priority    |
|---------------------|----------------------------------------|-------------------------------|-------------|
| `homelab-critical`  | `https://auth.tail1ec6c3.ts.net`       | Access token `<NTFY_TOKEN>`   | High        |
| `homelab-warn`      | `https://auth.tail1ec6c3.ts.net`       | Access token `<NTFY_TOKEN>`   | Default     |
| `homelab-info`      | `https://auth.tail1ec6c3.ts.net`       | Access token `<NTFY_TOKEN>`   | Min         |

Set the per-topic priority in the subscription's notification settings (varies by OS but both apps support it).

- [ ] **Step 4: Fire one notification per severity to verify push delivery**

From any host:

```bash
ssh jeff@nass 'sudo ntfy-notify homelab-info "test info" "should be silent"'
ssh jeff@nass 'sudo ntfy-notify homelab-warn "test warn" "should buzz like a regular notification"'
ssh jeff@nass 'sudo ntfy-notify homelab-critical "test critical" "should be loud — heads-up / breakthrough DND"'
```

Expected: phone receives all three with the configured priorities. `homelab-info` may be silent depending on OS settings — that's the point of "Min."

**iOS caveat reminder:** if the app isn't open, real-time delivery won't work on tailnet-only (no APNS path). You'll see the message next time you open the app or via background fetch. If this is painful, plan to add a cloudflared ingress later.

- [ ] **Step 5: Verify a real failure path**

Pick one of the wired units and force-fail it as a final check. Easiest: temporarily break `tailscale-cert` on one host by removing the cert dir (which the script tries to write to) — no, actually that mutates state. Cleaner: edit one of the units' `ExecStart` to a nonexistent binary, deploy, run it, see the alert, revert. **Skip if you want — Steps 4 and the per-task verifications already prove the path works.**

- [ ] **Step 6: No commit**

Nothing in the repo changed.

---

## Post-implementation

- Update `MEMORY.md` with a new entry pointing at `project_ntfy_bootstrap.md`:
  > ntfy first-deploy gotcha: admin user + writer token must be created manually via the ntfy CLI on `auth` before notifications fire; token then deployed to `/etc/ntfy-token` on every host.
- Update `CLAUDE.md`'s "Host-specific notes" section: add an `auth` entry describing it as the ntfy host (and future SSO host).
