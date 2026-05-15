# Filebrowser on NAS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Filebrowser to the `nas` host serving `/mnt/storage`, exposed publicly at `files.youtalklikeafag.com` via a per-host Cloudflare Tunnel, with a single admin user (`jeff`) seeded from `/etc/filebrowser-password`.

**Architecture:** Upstream `services.filebrowser` listens on `127.0.0.1:8334`, served externally by an outbound `cloudflared` tunnel (same pattern as the four existing service tunnels). The upstream module's tmpfiles rule that would chmod `/mnt/storage` to `0700` is force-overridden so Samba/NFS/Jellyfin continue to work. State at `/var/lib/filebrowser` (BoltDB + share-link metadata) is backed up nightly to B2 via the existing restic credentials on the host.

**Tech Stack:** NixOS flake, `services.filebrowser`, `services.cloudflared`, `services.restic.backups`, Cloudflare Tunnels, B2, Colmena deploys.

**Spec:** `docs/superpowers/specs/2026-05-15-filebrowser-nas-design.md`

---

## File Structure

- Modify: `machines/nas/configuration.nix` — add the `lib` function arg, add `publicFqdn` and `tunnelId` to the let-binding, add `services.filebrowser`, a tmpfiles override, an ExecStartPre admin-seed script, a `services.cloudflared` block, and a `services.restic.backups.filebrowser` block.

No new files. No edits to `common/base.nix` (filebrowser is host-specific). No edits to `flake.nix` (nas host already registered).

## Pre-flight assumptions (verify before starting)

- `/etc/filebrowser-password` exists on the nas host, mode `0600`, owner `root:root`, single line containing the desired admin password. User has confirmed this is provisioned.
- `/etc/restic/password` and `/etc/restic/b2.env` already exist on nas (reused by the existing `restic.backups.nextcloud` and `restic.backups.immich` blocks).
- Workstation has `~/.cloudflared/cert.pem` (origin certificate from the four prior tunnel creates).
- Cloudflare account holds the `youtalklikeafag.com` zone.

If any of these are missing, the implementation will not complete. Stop and provision out-of-band first.

---

## Task 1: Bootstrap the Cloudflare tunnel

Runs on the **workstation**, one-time, before any nas config changes. The tunnel UUID produced here is needed in Task 3.

**Files:** none changed.

- [ ] **Step 1: Create the tunnel**

Run on the workstation:

```bash
cloudflared tunnel create filebrowser
```

Expected output:

```
Tunnel credentials written to /home/<user>/.cloudflared/<UUID>.json
...
Created tunnel filebrowser with id <UUID>
```

Record the UUID. It will appear in three places in the rest of the plan: in the nix config, in the credentials filename on nas, and in the systemd unit name.

- [ ] **Step 2: Route DNS for the public hostname**

```bash
cloudflared tunnel route dns filebrowser files.youtalklikeafag.com
```

Expected output (or similar):

```
Added CNAME files.youtalklikeafag.com which will route to this tunnel tunnelID=<UUID>
```

If the CNAME already exists from a previous attempt, Cloudflare returns an error and prints the existing target. If that target matches `<UUID>.cfargotunnel.com`, treat as success.

- [ ] **Step 3: Confirm the credentials file**

```bash
ls -l ~/.cloudflared/<UUID>.json
```

Expected: file exists, mode `-rw-------` (0600 on the workstation by default from cloudflared).

Do **not** copy this anywhere yet, and do **not** commit it. It's needed in Task 7.

## Task 2: Add filebrowser service to nas config

**Files:**
- Modify: `machines/nas/configuration.nix`

This task adds the filebrowser service, the tmpfiles override, the admin-seed `ExecStartPre`, and the restic backup. Cloudflared comes in Task 3 so that after this task lands and deploys, filebrowser serves on loopback and we can verify it before exposing it publicly.

- [ ] **Step 1: Add `lib` to the function arguments**

Edit `machines/nas/configuration.nix`:

Old:

```nix
{ config, pkgs, claude-code-nix, ... }:
```

New:

```nix
{ config, lib, pkgs, claude-code-nix, ... }:
```

`lib` is needed for `lib.mkForce` in step 3 of this task.

- [ ] **Step 2: Add `publicFqdn` to the let-binding**

Old (lines 3-10):

```nix
let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ../../scripts/putio-sync.py);
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
in
```

New:

```nix
let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ../../scripts/putio-sync.py);
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
  publicFqdn = "files.youtalklikeafag.com";
in
```

(`tunnelId` is added in Task 3 to keep the diff in this task focused on filebrowser-only changes.)

- [ ] **Step 3: Add the filebrowser service block, tmpfiles override, and admin-seed ExecStartPre**

Insert immediately before the `# Daily encrypted backup of Nextcloud data ...` comment (currently line 140 — between the `systemd.timers.putio-sync` block and the `services.restic.backups.nextcloud` block):

```nix
  # Filebrowser: lightweight web UI for browsing /mnt/storage and
  # generating share links for external recipients. Listens on
  # loopback only; cloudflared (added below) handles public ingress.
  services.filebrowser = {
    enable = true;
    settings = {
      address = "127.0.0.1";
      port = 8334;
      root = "/mnt/storage";
    };
  };

  # The upstream filebrowser module emits a tmpfiles rule that chmods
  # settings.root to filebrowser:filebrowser 0700. For us that root is
  # /mnt/storage, which Samba/Jellyfin/NFS/restic all read — locking
  # it to one user would break every other service on this host.
  # Override the single offending rule (the existing 0755 root:root
  # tmpfiles rule already declared above stays in effect).
  systemd.tmpfiles.settings.filebrowser."/mnt/storage" = lib.mkForce {};

  # Seed/refresh the filebrowser admin user from /etc/filebrowser-password
  # on every start. First boot: `users update` fails (no user yet) → the
  # `||` branch runs `users add jeff <pw> --perm.admin --scope /mnt/storage`
  # to create the admin. Subsequent boots: `users update` succeeds and
  # re-syncs the password from the file, so rotating means edit the file
  # and `systemctl restart filebrowser`.
  #
  # The `+` prefix on ExecStartPre runs this as root (necessary to read
  # /etc/filebrowser-password, which is mode 0600 root:root). The main
  # filebrowser process still runs as the filebrowser system user.
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
```

- [ ] **Step 4: Add the filebrowser restic backup**

Insert immediately after the closing `};` of `services.restic.backups.immich` (currently line 187) and before `system.stateVersion`:

```nix
  # Daily encrypted backup of filebrowser state (BoltDB at
  # /var/lib/filebrowser/database.db, which holds the admin user record
  # and all generated share links). Reuses the restic password + B2
  # env file already in place for the nextcloud/immich backups.
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
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };
```

(05:00 is chosen to follow the nextcloud (04:00) and immich (04:30) restic runs, keeping all NAS backups in a single quiet window.)

## Task 3: Add cloudflared ingress

**Files:**
- Modify: `machines/nas/configuration.nix`

- [ ] **Step 1: Add `tunnelId` to the let-binding**

Replace `<UUID>` with the tunnel UUID captured in Task 1.

Old:

```nix
  publicFqdn = "files.youtalklikeafag.com";
in
```

New:

```nix
  publicFqdn = "files.youtalklikeafag.com";
  tunnelId = "<UUID>";
in
```

- [ ] **Step 2: Add the `services.cloudflared` block**

Insert immediately after the filebrowser block (before the restic.backups.nextcloud block), so the cloudflared config sits next to the service it fronts:

```nix
  # Public access via Cloudflare Tunnel. The outbound cloudflared
  # daemon holds a connection to Cloudflare's edge and forwards requests
  # to filebrowser on loopback; TLS terminates at the edge. LAN access
  # via Samba on this host stays direct and is unaffected.
  #
  # Credentials provisioned out-of-band at /etc/cloudflared/<uuid>.json
  # (root:root 0600). The nixpkgs module uses DynamicUser + LoadCredential,
  # so systemd reads the file as root before privilege drop. After the
  # first deploy: `sudo mkdir -p /etc/cloudflared && sudo install -m 600
  # -o root -g root <src> /etc/cloudflared/${tunnelId}.json` then restart
  # the unit.
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:8334";
      };
    };
  };
```

## Task 4: Validate the config locally

**Files:** none changed.

- [ ] **Step 1: Run `nix flake check`**

From the repo root on the workstation:

```bash
nix flake check
```

Expected: completes without errors. Warnings about unused inputs are fine.

If this fails with a syntax error, fix the typo in `machines/nas/configuration.nix` and re-run.

- [ ] **Step 2: Build the nas system closure without deploying**

```bash
nix run nixpkgs#colmena -- build --on nas
```

Expected: builds successfully and prints a `/nix/store/...` derivation path. No activation happens — this is a syntax/eval/build check only.

If this fails with an option-not-found error like `services.filebrowser.settings.database`, the nixpkgs pin doesn't expose that option; in that case omit `db = config.services.filebrowser.settings.database;` and hardcode `db = "/var/lib/filebrowser/database.db";` in the seed `let`-binding instead.

## Task 5: Deploy to nas

**Files:** none changed.

- [ ] **Step 1: Deploy**

```bash
scripts/deploy.sh nas
```

Expected: the script probes reachability, then `colmena apply --on nas` runs to completion. The `filebrowser.service` unit will be created and started, but the `cloudflared-tunnel-<UUID>.service` unit will fail-closed (credentials file missing) — this is the documented first-deploy gotcha.

- [ ] **Step 2: Verify filebrowser is running on loopback**

```bash
ssh jeff@nass systemctl status filebrowser
```

Expected: `active (running)`. The `ExecStartPre` should have run successfully (look for `Starting Filebrowser...` followed by no errors).

- [ ] **Step 3: Verify the admin user was seeded**

```bash
ssh jeff@nass 'sudo journalctl -u filebrowser -n 50 --no-pager'
```

Expected: on first deploy, you'll see the `users update jeff` invocation failing silently (stderr suppressed via `2>/dev/null`) and then `users add jeff ...` succeeding. On subsequent restarts you'll see only the `users update` succeeding.

- [ ] **Step 4: Hit filebrowser over loopback**

```bash
ssh jeff@nass curl -sI http://127.0.0.1:8334/
```

Expected: `HTTP/1.1 200 OK` (filebrowser serves a login redirect or the SPA shell). If it returns a connection-refused, the unit didn't bind; investigate `systemctl status` and `journalctl -u filebrowser`.

- [ ] **Step 5: Confirm the cloudflared unit failed (expected)**

```bash
ssh jeff@nass systemctl status cloudflared-tunnel-<UUID>.service
```

Expected: `failed` with a message about the credentials file not being found. This is the documented gotcha and is resolved in Task 7.

## Task 6: Commit the config-only filebrowser changes

**Files:** none changed.

- [ ] **Step 1: Stage and commit**

From the repo root:

```bash
git add machines/nas/configuration.nix
git commit -m "$(cat <<'EOF'
nas: add filebrowser serving /mnt/storage

Loopback-only filebrowser instance with admin user seeded from
/etc/filebrowser-password on every start. The upstream module's
tmpfiles chmod of settings.root to 0700 is force-overridden so
Samba/NFS/Jellyfin/restic keep working.

Public access via cloudflared follows in the next commit; B2 backup
of /var/lib/filebrowser ships alongside the existing NAS restic jobs.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

The commit message bundles the cloudflared block referenced in the comment even though the actual cloudflared block lands later in this same workflow — the comment is forward-looking, matching how the existing tunneled hosts read.

Actually if Task 3's cloudflared block has already been added in the same working tree (which it will have, per the plan order), this single commit covers all the config changes. If you prefer two commits (filebrowser-only, then cloudflared on top), revert Task 3's edits before this commit and re-apply them in Task 8. Default: one commit.

Expected: commit lands cleanly. `git log --oneline -3` shows the new commit on top.

## Task 7: Install the tunnel credentials on nas

**Files:** none changed. Credentials file lives outside the repo.

- [ ] **Step 1: Ensure /etc/cloudflared exists on nas**

```bash
ssh jeff@nass 'sudo mkdir -p /etc/cloudflared && sudo chmod 0755 /etc/cloudflared'
```

(The nixpkgs cloudflared module does not create this directory; we have to.)

- [ ] **Step 2: Copy the credentials JSON to nas**

From the workstation, replace `<UUID>` with the tunnel UUID from Task 1:

```bash
scp ~/.cloudflared/<UUID>.json jeff@nass:/tmp/<UUID>.json
```

Expected: the file copies. The workstation copy remains intact and stays out of the repo.

- [ ] **Step 3: Install into /etc/cloudflared with correct perms**

```bash
ssh jeff@nass 'sudo install -m 600 -o root -g root /tmp/<UUID>.json /etc/cloudflared/<UUID>.json && rm /tmp/<UUID>.json'
```

Expected: file at `/etc/cloudflared/<UUID>.json` with `-rw-------` root:root. The `/tmp` copy is removed.

- [ ] **Step 4: Restart the tunnel unit**

```bash
ssh jeff@nass sudo systemctl restart cloudflared-tunnel-<UUID>.service
```

Expected: unit enters `active (running)` within a couple of seconds. Check:

```bash
ssh jeff@nass systemctl status cloudflared-tunnel-<UUID>.service
```

Expected: `active (running)`, recent log lines should include `Registered tunnel connection` (typically four, one per Cloudflare edge POP).

## Task 8: Verify public access end-to-end

**Files:** none changed.

- [ ] **Step 1: DNS resolves**

From the workstation:

```bash
dig +short files.youtalklikeafag.com
```

Expected: a CNAME to `<UUID>.cfargotunnel.com` and then a couple of Cloudflare anycast IPs.

- [ ] **Step 2: Public HTTPS responds**

```bash
curl -sI https://files.youtalklikeafag.com/
```

Expected: a `200 OK` or a redirect to the login page (filebrowser serves an SPA; the exact response depends on its current build). NOT a `404` (which would indicate the ingress matched the `http_status:404` default rule, meaning cloudflared isn't seeing the hostname).

- [ ] **Step 3: Log in as jeff via browser**

In a browser, open `https://files.youtalklikeafag.com/`. Log in with username `jeff` and the password in `/etc/filebrowser-password` on nas. Confirm:
- The file tree at `/mnt/storage` is visible.
- The `nextcloud` and `immich` subdirectories are present but unreadable (their `0700` perms shut filebrowser out — intended).
- Other subdirectories on `/mnt/storage` are readable.

- [ ] **Step 4: Create a share link**

In the UI, right-click any file → **Share** → set an optional password/expiry → copy the link. Open the link in a private/incognito window (no session) and confirm the file downloads.

If the share link returns a 404 or "tunnel error 1033", investigate:
- `journalctl -u filebrowser -n 100` on nas
- `journalctl -u cloudflared-tunnel-<UUID> -n 100` on nas

## Task 9: Push to GitHub

**Files:** none changed.

- [ ] **Step 1: Push**

```bash
git push origin main
```

This is critical for this repo: `system.autoUpgrade` on every host pulls from `github:jaigner-hub/nixos-config#<host>` at 04:59 daily. If the commit from Task 6 isn't on `origin/main`, tomorrow's auto-upgrade will revert nas to a pre-filebrowser state.

Expected: push succeeds. `git log origin/main..main` returns empty (no commits ahead).

## Self-Review

Before handing this plan to an executor, walk it once more:

1. **Spec coverage:**
   - Filebrowser service on /mnt/storage → Task 2
   - tmpfiles override to avoid breaking siblings → Task 2 step 3
   - Single admin user seeded from password file → Task 2 step 3 (ExecStartPre)
   - Public via cloudflared at files.youtalklikeafag.com → Task 3 + Task 7
   - Restic backup of /var/lib/filebrowser → Task 2 step 4
   - Bootstrap procedure (tunnel + DNS + creds install) → Tasks 1, 7
   - All non-goals (no WebDAV, no anonymous browsing, no tailnet vhost, no multi-user in nix) → not implemented, by design
   - Failure modes documented → covered in inline comments and Task 8 troubleshooting
2. **Placeholder scan:** `<UUID>` appears in Task 1 and is consistently used downstream — intentional, must be filled at execution time from Task 1's output. No TBDs.
3. **Type consistency:** `publicFqdn`, `tunnelId`, port `8334`, path `/mnt/storage` are consistent across all tasks. `files.youtalklikeafag.com` matches in DNS, nix config, and verification.

Plan ready for execution.
