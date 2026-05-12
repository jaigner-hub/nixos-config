# Vaultwarden Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tailnet-only Vaultwarden host to the homelab flake. SQLite backend, nginx reverse proxy with a `tailscale cert`-issued LE cert renewed weekly. No public exposure.

**Architecture:** New `vaultwarden` NixOS host added via `mkSystem`. Runs `services.vaultwarden` listening on `127.0.0.1:8222`, fronted by nginx on `tailscale0:443`. Cert lives at `/var/lib/tailscale-cert/{cert,key}.pem`; renewed by a weekly oneshot+timer pair.

**Tech Stack:** NixOS unstable, Nix flakes, `services.vaultwarden`, nginx, `tailscale cert`.

**Spec:** `docs/superpowers/specs/2026-05-12-vaultwarden-design.md`

---

## Notes for the implementer

- Run every command from `/home/enum/Projects/nixos-config` (or `/etc/nixos` once deployed).
- "Build" steps use `nixos-rebuild build` (not `switch`!) — they produce `./result` and verify the closure builds without touching the running system.
- The Nix module system is the test runner: a clean `nix flake check` + successful `nixos-rebuild build` is "green."
- Deployment (Task 7) is reserved for the end. Do not `switch` partial work onto live machines.
- Commit messages follow the existing repo style: lowercase, short, no Conventional Commits prefixes — see `git log`.

---

## File Structure

**New files**
- `machines/vaultwarden/configuration.nix`
- `machines/vaultwarden/hardware-configuration.nix`

**Modified files**
- `flake.nix` — add `vaultwarden = mkSystem "vaultwarden";`
- `machines/monitor/configuration.nix` — append `"vaultwarden:9100"` to `scrapeTargets`

No other files change.

---

## Task 1: Scaffold the `vaultwarden` host (skeleton only)

Get a minimal host that builds and registers in the flake. Service config comes in later tasks.

**Files:**
- Create: `machines/vaultwarden/hardware-configuration.nix`
- Create: `machines/vaultwarden/configuration.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Create the hardware-configuration placeholder**

Verbatim copy of the placeholder used by every other host (`fragrance-app`, `nextcloud`, etc.):

```nix
{ config, lib, pkgs, modulesPath, ... }:

# Placeholder hardware-configuration.nix.
# Replace with the output of `nixos-generate-config --show-hardware-config`
# on the target machine before deploying.

{
  imports = [ ];

  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
```

- [ ] **Step 2: Create the host module (skeleton)**

```nix
{ config, pkgs, claude-code-nix, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "vaultwarden";

  system.stateVersion = "25.11";
}
```

- [ ] **Step 3: Register the host in the flake**

In `flake.nix`, inside `nixosConfigurations`, add after `nextcloud`:

```nix
        nextcloud = mkSystem "nextcloud";
        vaultwarden = mkSystem "vaultwarden";
```

- [ ] **Step 4: Verify the flake evaluates**

```
nix flake check
```

Expected: no errors.

- [ ] **Step 5: Build a VM image**

```
nixos-rebuild build-vm --flake .#vaultwarden
```

Expected: produces `./result` and `./result/bin/run-vaultwarden-vm`.

- [ ] **Step 6: (Optional) boot the VM and check basics**

```
./result/bin/run-vaultwarden-vm
```

Inside the VM (auto-logs in as root):

```
hostname        # expected: vaultwarden
```

Ctrl-A then X to exit qemu.

- [ ] **Step 7: Commit**

```
git add flake.nix machines/vaultwarden/configuration.nix machines/vaultwarden/hardware-configuration.nix
git commit -m "add vaultwarden host skeleton"
```

---

## Task 2: Enable `services.vaultwarden`

**Files:**
- Modify: `machines/vaultwarden/configuration.nix`

- [ ] **Step 1: Determine your tailnet suffix**

From any tailnet device:

```
tailscale status --json | jq -r .MagicDNSSuffix
```

Expected: something like `tail1ec6c3.ts.net`. The committed config already uses `tail1ec6c3.ts.net` to match the nextcloud config — if your suffix differs, update the `tailnet` `let` binding in `machines/vaultwarden/configuration.nix` before continuing.

- [ ] **Step 2: Add the service block**

Edit `machines/vaultwarden/configuration.nix`. Add a `let` binding above the attrset and the service block below `networking.hostName`:

```nix
let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "vaultwarden.${tailnet}";
in
{
  # ... existing entries ...

  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    backupDir = "/var/backup/vaultwarden";
    environmentFile = "/etc/vaultwarden.env";
    config = {
      DOMAIN = "https://${fqdn}";
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
      SIGNUPS_ALLOWED = false;
      INVITATIONS_ALLOWED = true;
      WEB_VAULT_ENABLED = true;
    };
  };
}
```

Notes:
- `dbBackend = "sqlite"` is the default; explicit for clarity.
- `backupDir` makes the module install a nightly `sqlite .backup` unit — cheap insurance.
- `ROCKET_ADDRESS = "127.0.0.1"` keeps vaultwarden bound to localhost; nginx is the only way in.
- `SIGNUPS_ALLOWED = false` from day one — admin invites users via `/admin`.
- `WEB_VAULT_ENABLED = true` keeps the web UI available for emergency access without a client.
- `adminpassFile`-style options don't exist for vaultwarden; the secret goes in the env file (Task 6).

- [ ] **Step 3: Verify**

```
nix flake check && nixos-rebuild build --flake .#vaultwarden
```

Expected: success. The missing `/etc/vaultwarden.env` is read at activation time, not at eval, so build succeeds.

- [ ] **Step 4: Commit**

```
git add machines/vaultwarden/configuration.nix
git commit -m "vaultwarden: enable services.vaultwarden with sqlite backend"
```

---

## Task 3: Add nginx reverse proxy + TLS placeholder

**Files:**
- Modify: `machines/vaultwarden/configuration.nix`

- [ ] **Step 1: Add the nginx block and firewall opening**

Add after the `services.vaultwarden` block:

```nix
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${fqdn} = {
      forceSSL = true;
      sslCertificate = "/var/lib/tailscale-cert/cert.pem";
      sslCertificateKey = "/var/lib/tailscale-cert/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:8222";
        proxyWebsockets = true;
      };
      locations."/notifications/hub" = {
        proxyPass = "http://127.0.0.1:8222";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
```

Why a separate `/notifications/hub` location: vaultwarden's live-sync uses a WebSocket on that path. `proxyWebsockets = true` adds the `Upgrade` / `Connection` headers nginx needs to pass it through. The top-level `/` location also enables WebSockets so non-hub upgrades work too; the explicit hub location is belt-and-suspenders.

`forceSSL = true` redirects HTTP→HTTPS, even though we never open 80; this keeps the config defensive if 80 leaks somewhere.

- [ ] **Step 2: Verify**

```
nix flake check && nixos-rebuild build --flake .#vaultwarden
```

Expected: success. The missing cert files are read by nginx at startup, not at eval, so build succeeds.

- [ ] **Step 3: Commit**

```
git add machines/vaultwarden/configuration.nix
git commit -m "vaultwarden: nginx reverse proxy with tls on tailscale0:443"
```

---

## Task 4: Add `tailscale cert` issuance & weekly renewal

**Files:**
- Modify: `machines/vaultwarden/configuration.nix`

- [ ] **Step 1: Add the cert systemd service and timer**

Add after the `networking.firewall` line:

```nix
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for vaultwarden";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail
      mkdir -p /var/lib/tailscale-cert
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file /var/lib/tailscale-cert/cert.pem \
        --key-file /var/lib/tailscale-cert/key.pem \
        ${fqdn}
      chown -R nginx:nginx /var/lib/tailscale-cert
      chmod 0644 /var/lib/tailscale-cert/cert.pem
      chmod 0600 /var/lib/tailscale-cert/key.pem
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

Notes:
- The **service** has no `wantedBy = multi-user.target`. It's started by the timer (or manually). This is intentional: at first boot, `tailscale up` hasn't run yet — letting the service fire at boot would create a failure cascade that blocks subsequent activations.
- The **timer** has `Persistent = true` so a missed weekly fire (e.g., box was off) catches up at next boot.
- `RandomizedDelaySec = "1h"` avoids hammering tailscale's ACME proxy at the exact same moment as other tailnet hosts using the same pattern.
- The script reloads nginx after a successful renewal so it picks up the new cert without dropping connections.

- [ ] **Step 2: Verify**

```
nix flake check && nixos-rebuild build --flake .#vaultwarden
```

Expected: success.

- [ ] **Step 3: Commit**

```
git add machines/vaultwarden/configuration.nix
git commit -m "vaultwarden: weekly tailscale cert renewal via oneshot+timer"
```

---

## Task 5: Add `vaultwarden:9100` to the monitor scrape targets

**Files:**
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Append the new target**

```nix
  scrapeTargets = [
    "monitor:9100"
    "gateway:9100"
    "nass:9100"
    "dev:9100"
    "fragrance-app:9100"
    "nextcloud:9100"
    "vaultwarden:9100"
  ];
```

- [ ] **Step 2: Verify**

```
nix flake check && nixos-rebuild build --flake .#monitor
```

- [ ] **Step 3: Commit**

```
git add machines/monitor/configuration.nix
git commit -m "monitor: scrape node_exporter on vaultwarden"
```

---

## Task 6: VM smoke test

The TLS cert won't exist in the VM (no tailscale auth), so nginx's vhost will fail. That's expected. We're verifying vaultwarden itself starts.

- [ ] **Step 1: Build and boot the VM**

```
nixos-rebuild build-vm --flake .#vaultwarden
./result/bin/run-vaultwarden-vm
```

- [ ] **Step 2: Inside the VM, sanity-check services**

```
systemctl --no-pager --failed
```

Expected: at most `nginx.service` failed (no cert). Everything else should be clean.

```
systemctl --no-pager status vaultwarden
```

Expected: `active (running)`, listening on 127.0.0.1:8222.

```
curl -sI http://127.0.0.1:8222/alive
```

Expected: `HTTP/1.1 200 OK`.

Ctrl-A then X to exit.

- [ ] **Step 3: No code change → no commit**

If `vaultwarden.service` is failing inside the VM, the config is wrong — fix the relevant earlier task before continuing.

---

## Task 7: Deploy

- [ ] **Step 1: Generate real hardware-configuration on the target**

SSH to the vaultwarden VM (after Proxmox provisions it and you've installed NixOS):

```
sudo nixos-generate-config --show-hardware-config
```

Copy the output into `machines/vaultwarden/hardware-configuration.nix`. Commit:

```
git add machines/vaultwarden/hardware-configuration.nix
git commit -m "vaultwarden: real hardware-configuration for $(hostname -s)"
```

- [ ] **Step 2: Generate and stage the admin token**

On the vaultwarden host:

```
sudo install -d -m 0700 /etc/vaultwarden.env.d   # not used; just a reminder this isn't /etc
TOKEN=$(head -c 48 /dev/urandom | base64)
printf 'ADMIN_TOKEN=%s\n' "$TOKEN" \
  | sudo install -m 0400 -o vaultwarden -g vaultwarden /dev/stdin /etc/vaultwarden.env
echo "Save this token in your existing password manager BEFORE proceeding:"
echo "$TOKEN"
unset TOKEN
```

(Optional: use Argon2id PHC instead — see the spec's "Admin token generation" section.)

- [ ] **Step 3: First-time switch**

```
cd /etc/nixos && sudo nixos-rebuild switch --flake .#vaultwarden
```

Expected: build succeeds, services activate. `nginx.service` will likely be in a failed state — that's expected because the TLS cert doesn't exist yet.

- [ ] **Step 4: Authenticate to the tailnet**

```
sudo tailscale up
```

Follow the URL in a browser to authenticate the new node. Confirm with:

```
tailscale status
```

Expected: this host listed, status `idle`.

- [ ] **Step 5: Issue the initial cert and start nginx**

```
sudo systemctl start tailscale-cert.service
sudo systemctl status tailscale-cert.service --no-pager
```

Expected: completed successfully. Check the files exist:

```
ls -l /var/lib/tailscale-cert/
```

Expected: `cert.pem` (mode 644) and `key.pem` (mode 600), both owned by `nginx:nginx`.

```
sudo systemctl restart nginx
sudo systemctl status nginx --no-pager
```

Expected: `active (running)`, no errors.

- [ ] **Step 6: Smoke-test from a tailnet device**

From your laptop (already on the tailnet):

```
curl -sI https://vaultwarden.<tailnet>.ts.net/alive | head -1
```

Expected: `HTTP/2 200`. Cert should validate without `-k`.

Browse to `https://vaultwarden.<tailnet>.ts.net/` — Bitwarden web vault login UI loads.

- [ ] **Step 7: Register the first user**

Vaultwarden has `SIGNUPS_ALLOWED = false` by default. To register the first account:

1. SSH back to vaultwarden, edit `machines/vaultwarden/configuration.nix`, flip `SIGNUPS_ALLOWED = true`.
2. `cd /etc/nixos && sudo nixos-rebuild switch --flake .#vaultwarden`
3. Register your account in the web vault.
4. Flip `SIGNUPS_ALLOWED = false` back. `git restore` or re-edit.
5. `sudo nixos-rebuild switch --flake .#vaultwarden` again.

Alternative: use the `/admin` panel (authenticate with `ADMIN_TOKEN`) to invite users via email — but that requires SMTP, which is out of scope for v1.

- [ ] **Step 8: Verify monitoring**

On `monitor`:

```
cd /etc/nixos && sudo nixos-rebuild switch --flake .#monitor
```

Then visit `http://monitor:9090/targets` and confirm `vaultwarden:9100` shows **UP**.

- [ ] **Step 9: No code change → no commit**

If everything is green, you're done. Make sure your password file with the master password is somewhere you can recover from (a separate physical password manager, a sealed envelope, etc.) — losing it means losing the vault.

---

## Post-deployment checks (informational)

- `sudo systemctl list-timers tailscale-cert` — confirms the timer is armed.
- `sudo ls -l /var/backup/vaultwarden/` — after first night, should have a SQLite dump.
- `sudo systemctl status vaultwarden vaultwarden-backup` — both should be healthy.
- Prometheus targets page on `monitor` — `vaultwarden:9100` UP.
- Cert validity: `openssl s_client -connect vaultwarden.<tailnet>.ts.net:443 -servername vaultwarden.<tailnet>.ts.net </dev/null 2>/dev/null | openssl x509 -noout -dates`.

## Rollback

NixOS keeps prior generations:

```
sudo nixos-rebuild switch --rollback
```

If the cert renewal is what broke, just stop the timer (`sudo systemctl stop tailscale-cert.timer`) and reissue manually with `sudo systemctl start tailscale-cert.service` — the old cert remains valid for up to 90 days.

## Out of scope (do NOT do as part of this plan)

- SMTP setup for password-reset / email invites
- Off-site backup of `/var/backup/vaultwarden`
- Public hostname via `gateway` / Caddy
- Vaultwarden-specific Prometheus metrics
- Two-factor enforcement policy
- Org/group provisioning
