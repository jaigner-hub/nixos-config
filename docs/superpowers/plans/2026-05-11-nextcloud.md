# Nextcloud Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tailnet-only Nextcloud host to the homelab flake, with files stored on the existing `nas` mergerfs array via NFSv4 and PostgreSQL+Redis colocated on the new host.

**Architecture:** New `nextcloud` NixOS host added via the existing `mkSystem` helper in `flake.nix`. The host runs `services.nextcloud` (PostgreSQL + Redis enabled by the module), with `datadir` pointing at `/mnt/nextcloud-data` — an NFSv4 mount of `nas:/mnt/storage/nextcloud`. A pinned UID/GID (994) on both hosts keeps NFS ownership consistent. No public exposure: nginx binds 80 on `tailscale0` only.

**Tech Stack:** NixOS unstable, Nix flakes, `services.nextcloud` (nextcloud31), PostgreSQL, Redis, NFSv4.

**Spec:** `docs/superpowers/specs/2026-05-11-nextcloud-design.md`

---

## Notes for the implementer

- Run every command from `/home/enum/Projects/nixos-config` (or wherever the flake lives on the target machine — `/etc/nixos` once deployed).
- "Build" steps use `nixos-rebuild build` (no `switch`!) for tasks before final deployment. They produce a `./result` symlink and verify the closure evaluates and builds; they do not touch the running system.
- "TDD" in NixOS-config land means: the build/eval failure is your failing test, and a successful `nix flake check` + `nixos-rebuild build` is the green test. There are no unit-test frameworks here; the typechecker (Nix module system) is the test runner.
- Deployment (Task 9) is reserved for the very end and clearly separated. Do not `switch` partial work onto the live machines.
- Commit messages use the existing repo style (lowercase, short, no Conventional Commits prefixes — see `git log`).

---

## File Structure

**New files**
- `machines/nextcloud/configuration.nix` — host module (imports base, declares services)
- `machines/nextcloud/hardware-configuration.nix` — generic-virtio placeholder, replaced on real hardware

**Modified files**
- `flake.nix` — add `nextcloud = mkSystem "nextcloud";`
- `machines/nas/configuration.nix` — add `nextcloud` user/group, NFS export, firewall opening
- `machines/monitor/configuration.nix` — append `"nextcloud:9100"` to `scrapeTargets`

No other files change. `common/base.nix`, `gateway`, `dev`, `fragrance-app` are untouched.

---

## Task 1: Reserve nextcloud user/group on `nas` (UID/GID 994)

NFSv4 maps file ownership by name unless idmapd is in use; for this homelab we
rely on numeric UID/GID matching. The user has to exist on `nas` so the data
directory has the right ownership before nextcloud writes to it.

**Files:**
- Modify: `machines/nas/configuration.nix`

- [ ] **Step 1: Verify UID/GID 994 is free on `nas`**

If you have shell access to `nas` right now, run there:

```bash
getent passwd 994; getent group 994
```

Expected: both commands print nothing. If either prints a line, pick a different free number (e.g. 993) and use it consistently in every step of every task below. Note your chosen number; the rest of this plan assumes 994.

If you cannot SSH to `nas` yet, proceed with 994 and verify in Task 9 (deployment) before activating.

- [ ] **Step 2: Add the user and group declarations**

Edit `machines/nas/configuration.nix`. Inside the existing top-level attrset
(after `services.samba` and before `fileSystems."/mnt/hdd1"`), add:

```nix
  users.groups.nextcloud = {
    gid = 994;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 994;
    description = "Nextcloud data owner (NFS UID/GID parity)";
  };
```

- [ ] **Step 3: Verify the flake still evaluates**

Run: `nix flake check`
Expected: completes silently (no errors). Warnings about hardware-configuration placeholders are fine.

- [ ] **Step 4: Verify `nas` still builds**

Run: `nixos-rebuild build --flake .#nas`
Expected: produces `./result` symlink, no errors. (Note: `build` does NOT activate.)

- [ ] **Step 5: Commit**

```bash
git add machines/nas/configuration.nix
git commit -m "nas: reserve nextcloud user/group at uid/gid 994"
```

---

## Task 2: Add NFS export on `nas` for the nextcloud data directory

**Files:**
- Modify: `machines/nas/configuration.nix`

- [ ] **Step 1: Add the NFS server and export**

Edit `machines/nas/configuration.nix`. After the `users.users.nextcloud` block
from Task 1, add:

```nix
  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/nextcloud 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 2049 ];
```

Why `100.64.0.0/10`: that's Tailscale's CGNAT block. The export is therefore
reachable only from tailnet peers. `no_root_squash` is required because
nextcloud's setup unit can briefly run as root during activation.

Why `interfaces.tailscale0` rather than top-level `allowedTCPPorts`: the base
config marks `tailscale0` as the only trusted interface; this confines NFS to
tailnet traffic, not the LAN.

- [ ] **Step 2: Verify the flake still evaluates**

Run: `nix flake check`
Expected: no errors.

- [ ] **Step 3: Verify `nas` still builds**

Run: `nixos-rebuild build --flake .#nas`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add machines/nas/configuration.nix
git commit -m "nas: export /mnt/storage/nextcloud over nfsv4 on tailscale0"
```

---

## Task 3: Scaffold the `nextcloud` host (skeleton only)

This task adds the bare-minimum host so `nixos-rebuild build-vm --flake .#nextcloud`
succeeds. No nextcloud service yet.

**Files:**
- Create: `machines/nextcloud/hardware-configuration.nix`
- Create: `machines/nextcloud/configuration.nix`
- Modify: `flake.nix`

- [ ] **Step 1: Create the hardware-configuration placeholder**

Create `machines/nextcloud/hardware-configuration.nix` with:

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

This is verbatim the same placeholder used by `fragrance-app` and the other hosts.

- [ ] **Step 2: Create the host module (skeleton)**

Create `machines/nextcloud/configuration.nix` with:

```nix
{ config, pkgs, claude-code-nix, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nextcloud";

  users.groups.nextcloud = {
    gid = 994;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 994;
  };

  system.stateVersion = "25.11";
}
```

- [ ] **Step 3: Register the host in the flake**

Edit `flake.nix`. Inside the `nixosConfigurations` attrset, add a new line
between `fragrance-app` and `gateway` (alphabetical order):

```nix
        fragrance-app = mkSystem "fragrance-app";
        gateway = mkSystem "gateway";
        monitor = mkSystem "monitor";
        nas = mkSystem "nas";
        nextcloud = mkSystem "nextcloud";
```

Note: the existing file already lists the others; the only change is the
`nextcloud = mkSystem "nextcloud";` line. Place it after `nas` to keep things tidy.

- [ ] **Step 4: Verify the flake evaluates**

Run: `nix flake check`
Expected: no errors, no warnings beyond the existing ones.

- [ ] **Step 5: Build a VM image to confirm the closure works end-to-end**

Run: `nixos-rebuild build-vm --flake .#nextcloud`
Expected: produces `./result` and a `./result/bin/run-nextcloud-vm` script. No errors.

- [ ] **Step 6: (Optional but recommended) boot the VM and check basics**

Run: `./result/bin/run-nextcloud-vm`

In the VM (auto-logs in as root with empty password thanks to the `vmVariant`
override in `common/base.nix`):

```bash
hostname
# expected: nextcloud
getent passwd nextcloud
# expected: nextcloud:x:994:994::...
```

Press Ctrl-A then X to exit qemu (or close the window).

- [ ] **Step 7: Commit**

```bash
git add flake.nix machines/nextcloud/configuration.nix machines/nextcloud/hardware-configuration.nix
git commit -m "add nextcloud host skeleton"
```

---

## Task 4: Add the NFS mount on the nextcloud host

**Files:**
- Modify: `machines/nextcloud/configuration.nix`

- [ ] **Step 1: Add the fileSystems entry**

Edit `machines/nextcloud/configuration.nix`. After the `users.users.nextcloud`
block, add:

```nix
  fileSystems."/mnt/nextcloud-data" = {
    device = "nass:/mnt/storage/nextcloud";
    fsType = "nfs4";
    options = [
      "nofail"
      "x-systemd.automount"
      "x-systemd.device-timeout=10"
      "_netdev"
    ];
  };
```

Why these options:
- `nofail` — boot doesn't block on the NFS server being up.
- `x-systemd.automount` — the mount is lazily realized on first access, so
  services that depend on it can start even if the server is slow to respond.
- `x-systemd.device-timeout=10` — caps the wait at 10s.
- `_netdev` — declare it as a network filesystem so systemd orders it after `network-online.target`.

`nass` is the actual hostname of the nas machine (see `networking.hostName` in `machines/nas/configuration.nix` — intentional, not a typo of the directory name).

- [ ] **Step 2: Verify the flake evaluates and builds**

Run: `nix flake check && nixos-rebuild build --flake .#nextcloud`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add machines/nextcloud/configuration.nix
git commit -m "nextcloud: mount /mnt/nextcloud-data from nass over nfsv4"
```

---

## Task 5: Add `services.nextcloud` (postgres + redis + nginx, all local)

This is the meat of the host. The NixOS `services.nextcloud` module pulls in
nginx, PostgreSQL, and Redis automatically once we set the right flags.

**Files:**
- Modify: `machines/nextcloud/configuration.nix`

- [ ] **Step 1: Add the service block**

Edit `machines/nextcloud/configuration.nix`. After the `fileSystems` block,
add (and replace `<tailnet>` with your actual tailnet name — find it with
`tailscale status --json | jq -r .MagicDNSSuffix` from any tailnet device):

```nix
  services.nextcloud = {
    enable = true;
    package = pkgs.nextcloud31;
    hostName = "nextcloud";
    datadir = "/mnt/nextcloud-data";
    https = false;

    database.createLocally = true;
    configureRedis = true;

    config = {
      dbtype = "pgsql";
      adminuser = "jeff";
      adminpassFile = "/etc/nextcloud-admin-pass";
      trustedDomains = [
        "nextcloud"
        "nextcloud.<tailnet>.ts.net"
      ];
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 80 ];

  systemd.services.nextcloud-setup = {
    after = [ "mnt-nextcloud\\x2ddata.mount" ];
    requires = [ "mnt-nextcloud\\x2ddata.mount" ];
  };
  systemd.services.phpfpm-nextcloud = {
    after = [ "mnt-nextcloud\\x2ddata.mount" ];
    requires = [ "mnt-nextcloud\\x2ddata.mount" ];
  };
```

Notes:
- `database.createLocally = true` makes the module enable PostgreSQL and
  provision the role+database. No password file needed — peer auth on a unix socket.
- `configureRedis = true` enables a dedicated Redis instance (`services.redis.servers.nextcloud`)
  and wires it into Nextcloud's `memcache.locking` / `memcache.distributed` config.
- `https = false` because we're terminating at plain HTTP behind the tailnet boundary.
- `mnt-nextcloud\\x2ddata.mount` is the systemd-escaped form of `/mnt/nextcloud-data`
  (`\x2d` is the escape for `-`). The double backslash is the Nix string escape.
  This ordering keeps `nextcloud-setup` (which writes into `datadir`) and PHP-FPM
  from racing the automount.
- The firewall opens port 80 on the tailnet interface only; the top-level
  `allowedTCPPorts` stays empty so 80 is not reachable from any other interface.

- [ ] **Step 2: Verify the flake evaluates and builds**

Run: `nix flake check && nixos-rebuild build --flake .#nextcloud`
Expected: success. The `adminpassFile` is read only at activation time (by `nextcloud-setup`), not at eval/build time, so the missing `/etc/nextcloud-admin-pass` is fine here. If `build` fails, the error is real — investigate before continuing.

- [ ] **Step 3: Commit**

```bash
git add machines/nextcloud/configuration.nix
git commit -m "nextcloud: enable services.nextcloud with pgsql+redis on tailnet"
```

---

## Task 6: Add `nextcloud:9100` to the monitor scrape targets

**Files:**
- Modify: `machines/monitor/configuration.nix`

- [ ] **Step 1: Append the new target**

Edit `machines/monitor/configuration.nix`. The `scrapeTargets` list currently reads:

```nix
  scrapeTargets = [
    "monitor:9100"
    "gateway:9100"
    "nass:9100"
    "dev:9100"
    "fragrance-app:9100"
  ];
```

Add the new entry at the end:

```nix
  scrapeTargets = [
    "monitor:9100"
    "gateway:9100"
    "nass:9100"
    "dev:9100"
    "fragrance-app:9100"
    "nextcloud:9100"
  ];
```

- [ ] **Step 2: Verify the flake evaluates and builds**

Run: `nix flake check && nixos-rebuild build --flake .#monitor`
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add machines/monitor/configuration.nix
git commit -m "monitor: scrape node_exporter on nextcloud"
```

---

## Task 7: VM smoke test of the full nextcloud config

The NFS mount won't resolve in the VM (no nas), but `nofail` + automount means
services should still start. This catches eval/module-system bugs before they
hit real hardware.

- [ ] **Step 1: Build and boot a VM**

Run: `nixos-rebuild build-vm --flake .#nextcloud`
Expected: success.

Then: `./result/bin/run-nextcloud-vm`

- [ ] **Step 2: Inside the VM, sanity-check services**

After the VM auto-logs in as root:

```bash
# This will fail loudly if anything required is broken
systemctl --no-pager --failed
```
Expected: 0 loaded units listed as failed (or only `mnt-nextcloud\x2ddata.mount` failed because nas isn't reachable, which is fine).

```bash
systemctl --no-pager status postgresql redis-nextcloud
```
Expected: both `active (running)`.

```bash
systemctl --no-pager status nextcloud-setup
```
Expected: not started yet (it's blocked by the missing NFS mount). This is the correct behavior — proves our ordering is wired up.

```bash
systemctl --no-pager status nginx
```
Expected: `active (running)`. (Even if PHP-FPM is not up, nginx itself should start.)

Press Ctrl-A then X to exit qemu.

- [ ] **Step 3: No code change → no commit**

If anything was wrong, fix it inline (re-edit the relevant earlier task's file, re-run `nix flake check`, retry the VM). Commit fixes with a clear message describing what was broken.

---

## Task 8: Deployment dry-run on real hardware (optional, but recommended)

Skip this task if you don't yet have hardware provisioned. Otherwise, do this
before Task 9.

- [ ] **Step 1: Generate real hardware-configuration on the nextcloud target**

SSH to the target machine and run:

```bash
sudo nixos-generate-config --show-hardware-config
```

Copy the output and replace the contents of `machines/nextcloud/hardware-configuration.nix`
in this repo with it. Commit:

```bash
git add machines/nextcloud/hardware-configuration.nix
git commit -m "nextcloud: real hardware-configuration for $(hostname -s)"
```

- [ ] **Step 2: Verify it still builds**

Run: `nix flake check && nixos-rebuild build --flake .#nextcloud`
Expected: success.

- [ ] **Step 3: Push to the target**

Standard NixOS flow — `git push` the repo, `git pull` on the target, then on the target:

```bash
sudo nixos-rebuild build --flake /etc/nixos#nextcloud
```

Expected: success. We're doing `build`, not `switch`, here — Task 9 does `switch`.

---

## Task 9: Deploy in the correct order

Order matters: `nas` must export the directory before `nextcloud` mounts it.

- [ ] **Step 1: On `nas`, ensure UID/GID 994 is free**

```bash
getent passwd 994; getent group 994
```

If either prints a line, stop. Go back to Task 1 and pick a different number; re-do every UID/GID reference in the repo together.

- [ ] **Step 2: Deploy to `nas` first**

On `nas`:

```bash
cd /etc/nixos && sudo nixos-rebuild switch --flake .#nas
```

Expected: success, no rollback. Check:

```bash
systemctl status nfs-server
sudo exportfs -v
```

Expected: `nfs-server.service` active, `exportfs` lists `/mnt/storage/nextcloud`.

- [ ] **Step 3: Create the data directory on `nas` with correct ownership**

Still on `nas`:

```bash
sudo install -d -o nextcloud -g nextcloud -m 0750 /mnt/storage/nextcloud
ls -ld /mnt/storage/nextcloud
```

Expected: `drwxr-x--- 2 nextcloud nextcloud ... /mnt/storage/nextcloud`. If the numeric IDs in `ls -ldn` aren't `994:994`, stop and investigate.

- [ ] **Step 4: Provision the admin password file on `nextcloud`**

On the nextcloud target:

```bash
read -rsp "Admin password: " pw
printf '%s' "$pw" | sudo install -m 0400 -o nextcloud -g nextcloud /dev/stdin /etc/nextcloud-admin-pass
unset pw
ls -l /etc/nextcloud-admin-pass
```

Expected: `-r-------- 1 nextcloud nextcloud ... /etc/nextcloud-admin-pass`

- [ ] **Step 5: Deploy to `nextcloud`**

On the nextcloud target:

```bash
cd /etc/nixos && sudo nixos-rebuild switch --flake .#nextcloud
```

Expected: success. Verify:

```bash
mount | grep nextcloud-data
# expected: nass:/mnt/storage/nextcloud on /mnt/nextcloud-data type nfs4 ...

systemctl status phpfpm-nextcloud postgresql redis-nextcloud nginx nextcloud-setup --no-pager
# expected: all green; nextcloud-setup should show "succeeded" (oneshot)

sudo -u nextcloud nextcloud-occ status
# expected: installed: true, version: 31.x.x
```

- [ ] **Step 6: From another tailnet device, open the UI**

From your laptop:

```bash
curl -sI http://nextcloud/ | head -1
# expected: HTTP/1.1 302 Found  (or 200 — either is fine)
```

Then open `http://nextcloud/` in a browser, log in as `jeff` with the password from Step 4. Confirm the dashboard loads.

- [ ] **Step 7: Deploy to `monitor` to pick up the new scrape target**

On `monitor`:

```bash
cd /etc/nixos && sudo nixos-rebuild switch --flake .#monitor
```

Then visit `http://monitor:9090/targets` and confirm `nextcloud:9100` shows as **UP**.

- [ ] **Step 8: No code change → no commit**

If everything is green, you're done. If anything failed, debug, fix, commit the fix with a descriptive message, and re-run the affected deploy step.

---

## Post-deployment checks (informational)

- `sudo -u nextcloud nextcloud-occ status` — confirms Nextcloud is installed and at the expected version.
- `ls -ln /mnt/nextcloud-data` (on `nextcloud`) — top-level entries should be owned by UID 994. If they show as `nobody`, NFS idmapping/UID matching is broken — go back and check that `users.users.nextcloud.uid = 994` is set identically on both hosts.
- Prometheus target page on `monitor` — `nextcloud:9100` should be UP.

## Rollback

NixOS keeps prior generations. To roll back any host:

```bash
sudo nixos-rebuild switch --rollback
```

Or, to pin to a known-good generation:

```bash
sudo nix-env --profile /nix/var/nix/profiles/system --list-generations
sudo /nix/var/nix/profiles/system-<N>-link/bin/switch-to-configuration switch
```

Rolling back the `nas` deploy will tear down the NFS export, which will make
the nextcloud mount fail — that's a desired property if something is wrong
on nas, since it pulls the rug out before bad state propagates.

## Out of scope (do NOT do as part of this plan)

- TLS for nextcloud
- Public hostname via `gateway`
- Backups
- Nextcloud-specific Prometheus metrics
- Installing optional Nextcloud apps (Calendar, Contacts, Talk, Office)
- Moving AppData off NFS to local disk (potential future perf work)
