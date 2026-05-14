# Cloudflare Tunnel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose nextcloud, vaultwarden, immich, and paperless to the public internet under a real domain via Cloudflare Tunnel. Tailnet access stays unchanged.

**Architecture:** Per-host `cloudflared` daemon (managed by the upstream `services.cloudflared` nixpkgs module) holds an outbound connection to Cloudflare and proxies requests to the app's loopback port. TLS terminates at the Cloudflare edge. nginx + `tailscale-cert` stays untouched as the admin/tailnet path.

**Tech Stack:** NixOS unstable, `services.cloudflared`, Cloudflare DNS + Zero Trust tunnels.

**Spec:** `docs/superpowers/specs/2026-05-14-cloudflare-tunnel-design.md`

---

## Notes for the implementer

- Run Nix commands from `/home/enum/Projects/nixos-config`. The `cloudflared` CLI runs from your laptop (or anywhere with the binary + internet).
- "Build" steps use `nixos-rebuild build --flake .#<host>` — produces `./result`, doesn't touch any live machine.
- Deploys use `scripts/deploy.sh <host>` (probes reachability, then `colmena apply --on <host>`).
- Commit messages follow the existing style: lowercase, short, host-prefixed (`vaultwarden: ...`). No Conventional Commits.
- The hosts are accessed over the tailnet (`vaultwarden.tail1ec6c3.ts.net`, etc.); SSH as user `jeff`.
- Cloudflared credentials are secrets — never commit any `~/.cloudflared/*.json` file.

### Placeholders to substitute throughout the plan

Before each task, the implementer must know these values. Some are user-supplied; some come out of intermediate steps.

| Token              | Substitute with                                                                 |
|--------------------|---------------------------------------------------------------------------------|
| `<PUBLIC_DOMAIN>`  | The Cloudflare-managed domain the user owns (ask if unknown).                   |
| `<VAULT_UUID>`     | Tunnel UUID printed when Task 2 step 1 creates the vaultwarden tunnel.          |
| `<NEXTCLOUD_UUID>` | Tunnel UUID printed when Task 3 step 1 creates the nextcloud tunnel.            |
| `<IMMICH_UUID>`    | Tunnel UUID printed when Task 4 step 1 creates the immich tunnel.               |
| `<PAPERLESS_UUID>` | Tunnel UUID printed when Task 5 step 1 creates the paperless tunnel.            |

The UUIDs land in `~/.cloudflared/<uuid>.json` on the workstation; the filename is the UUID. You can also list them with `cloudflared tunnel list`.

---

## File Structure

**Modified files**
- `machines/vaultwarden/configuration.nix` — add `services.cloudflared` block; switch `DOMAIN` to public FQDN.
- `machines/nextcloud/configuration.nix` — add `services.cloudflared`; append public hostname to `trusted_domains`.
- `machines/immich/configuration.nix` — add `services.cloudflared`.
- `machines/paperless/configuration.nix` — add `services.cloudflared`; set `PAPERLESS_URL` and update `PAPERLESS_TRUSTED_PROXIES`.
- `CLAUDE.md` — document the first-deploy credentials-file gotcha.

**Out-of-repo artifacts** (provisioned out-of-band, never committed)
- `/etc/cloudflared/<UUID>.json` on each of the four hosts.

**No new files.** The nixpkgs `services.cloudflared` module does the rest.

---

## Task 1: One-time `cloudflared` CLI bootstrap

Authorize the local `cloudflared` against the user's Cloudflare account. Done once per workstation, regardless of how many hosts.

**Files:** none.

- [ ] **Step 1: Confirm `cloudflared` is available**

Run: `nix run nixpkgs#cloudflared -- --version`
Expected: prints a version (e.g. `cloudflared version 2024.x.x`).

If you prefer it permanently available: add `cloudflared` to your workstation's package list. Not strictly required — `nix run nixpkgs#cloudflared --` works everywhere below in place of `cloudflared`.

- [ ] **Step 2: Authorize against Cloudflare**

Run: `cloudflared tunnel login`
Expected: a browser opens. Log in to Cloudflare, select `<PUBLIC_DOMAIN>` from the zones list, and authorize. The CLI writes `~/.cloudflared/cert.pem`.

This grants the local CLI permission to create tunnels and DNS records under `<PUBLIC_DOMAIN>`. The cert is sensitive — keep it on the workstation only.

- [ ] **Step 3: Verify the cert landed**

Run: `ls -la ~/.cloudflared/cert.pem`
Expected: a file ~2-3 KB exists.

No commit — these are workstation-only artifacts outside the repo.

---

## Task 2: Vaultwarden public tunnel

Add cloudflared to the vaultwarden host, switch its canonical URL to the public FQDN, deploy, and verify both public and tailnet paths work.

**Files:**
- Modify: `machines/vaultwarden/configuration.nix`

- [ ] **Step 1: Create the tunnel**

Run: `cloudflared tunnel create vaultwarden`
Expected output (UUID will differ):
```
Tunnel credentials written to /home/<you>/.cloudflared/<VAULT_UUID>.json.
Created tunnel vaultwarden with id <VAULT_UUID>
```
Record `<VAULT_UUID>` for the steps below.

- [ ] **Step 2: Create the DNS CNAME**

Run: `cloudflared tunnel route dns vaultwarden vaultwarden.<PUBLIC_DOMAIN>`
Expected: `Added CNAME vaultwarden.<PUBLIC_DOMAIN> which will route to this tunnel ...`

- [ ] **Step 3: Edit `machines/vaultwarden/configuration.nix`**

Open `machines/vaultwarden/configuration.nix`. Replace the existing `let` block at the top with this expanded version (adding `publicFqdn` and `tunnelId`):

```nix
let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "vaultwarden.${tailnet}";
  publicFqdn = "vaultwarden.<PUBLIC_DOMAIN>";
  tunnelId = "<VAULT_UUID>";
  certDir = "/var/lib/tailscale-cert";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
in
```

Then update the existing `fqdn` references in the file. The current file uses `fqdn` in two places:
- The `services.vaultwarden.config.DOMAIN` line
- The `services.nginx.virtualHosts.${fqdn}` block and `tailscale-cert` script

Change them to refer to `tailnetFqdn` for nginx/cert (tailnet path) and `publicFqdn` for the `DOMAIN` setting (canonical URL).

Concretely:

Replace:
```nix
  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    backupDir = "/var/backup/vaultwarden";
    environmentFile = "/etc/vaultwarden.env";
    config = {
      DOMAIN = "https://${fqdn}";
```
With:
```nix
  services.vaultwarden = {
    enable = true;
    dbBackend = "sqlite";
    backupDir = "/var/backup/vaultwarden";
    environmentFile = "/etc/vaultwarden.env";
    config = {
      DOMAIN = "https://${publicFqdn}";
```

Replace:
```nix
    virtualHosts.${fqdn} = {
```
With:
```nix
    virtualHosts.${tailnetFqdn} = {
```

Replace (inside the `tailscale-cert` script):
```nix
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file ${certDir}/cert.pem \
        --key-file ${certDir}/key.pem \
        ${fqdn}
```
With:
```nix
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file ${certDir}/cert.pem \
        --key-file ${certDir}/key.pem \
        ${tailnetFqdn}
```

Finally, add the cloudflared block. Insert it after the `services.vaultwarden = { ... };` block and before `services.nginx`:

```nix
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
```

- [ ] **Step 4: Verify the build succeeds**

Run: `sudo nixos-rebuild build --flake .#vaultwarden`
Expected: builds `./result` symlink with no errors. Vaultwarden won't appear in the closure of your laptop, but `nixos-rebuild build` validates the whole module graph.

If the build fails with `attribute 'cloudflared' missing` or similar, the upstream module path may differ on the pinned nixpkgs commit — verify with `nix eval .#nixosConfigurations.vaultwarden.options.services.cloudflared.enable.description` and adjust.

- [ ] **Step 5: Commit the Nix change**

```bash
git add machines/vaultwarden/configuration.nix
git commit -m "vaultwarden: route public traffic via cloudflare tunnel"
```

- [ ] **Step 6: Deploy to vaultwarden**

Run: `scripts/deploy.sh vaultwarden`
Expected: colmena builds, copies the closure, and switches. `cloudflared-tunnel-<VAULT_UUID>.service` will appear in the unit list but **will fail** on the first start because the credentials JSON isn't on the host yet. That's expected — we install it next.

- [ ] **Step 7: Copy the credentials file to the host**

```bash
scp ~/.cloudflared/<VAULT_UUID>.json jeff@vaultwarden:/tmp/<VAULT_UUID>.json
ssh jeff@vaultwarden 'sudo install -m 600 -o cloudflared -g cloudflared \
  /tmp/<VAULT_UUID>.json /etc/cloudflared/<VAULT_UUID>.json && \
  rm /tmp/<VAULT_UUID>.json'
```

Expected: no errors. The `cloudflared` user/group exist because the deploy in step 6 created them.

- [ ] **Step 8: Restart the cloudflared unit**

Run: `ssh jeff@vaultwarden 'sudo systemctl restart cloudflared-tunnel-<VAULT_UUID>.service'`
Expected: no output.

- [ ] **Step 9: Verify the service is healthy**

Run: `ssh jeff@vaultwarden 'sudo systemctl status cloudflared-tunnel-<VAULT_UUID>.service --no-pager'`
Expected: `Active: active (running)`. The journal should show lines like `Registered tunnel connection` (cloudflared connects to multiple CF edge regions for HA).

If you see `failed to read credentials`, check `/etc/cloudflared/<VAULT_UUID>.json` perms (`ls -la /etc/cloudflared/`).

- [ ] **Step 10: Verify the public URL responds**

Run: `curl -sI https://vaultwarden.<PUBLIC_DOMAIN>`
Expected: `HTTP/2 200` or a redirect (`HTTP/2 302`). Should *not* be a 502 Bad Gateway or a connection timeout.

Open `https://vaultwarden.<PUBLIC_DOMAIN>` in a browser; the Vaultwarden login page should load with a green padlock (TLS via Cloudflare's edge cert).

- [ ] **Step 11: Verify the tailnet path still works**

Run: `curl -sI https://vaultwarden.tail1ec6c3.ts.net`
Expected: `HTTP/2 200` or `HTTP/2 302`. Login over tailnet still works; tailscale-cert vhost is untouched.

- [ ] **Step 12: Verify login + sync from a client**

Open the Bitwarden browser extension or mobile app. Change the server URL to `https://vaultwarden.<PUBLIC_DOMAIN>` if previously set to the tailnet host. Log in. Confirm a vault entry syncs.

This is the real end-to-end test: public URL serving the app, websockets for `/notifications/hub` working, no mixed-content errors.

---

## Task 3: Nextcloud public tunnel

Same shape as Task 2 but for nextcloud. The nextcloud module is more particular about hostnames — it has a `trusted_domains` allowlist that has to include the public FQDN, plus a `hostName` setting that drives generated URLs.

**Files:**
- Modify: `machines/nextcloud/configuration.nix`

- [ ] **Step 1: Create the tunnel**

Run: `cloudflared tunnel create nextcloud`
Expected: prints `<NEXTCLOUD_UUID>` and credentials path.

- [ ] **Step 2: Create the DNS CNAME**

Run: `cloudflared tunnel route dns nextcloud nextcloud.<PUBLIC_DOMAIN>`
Expected: confirmation.

- [ ] **Step 3: Edit `machines/nextcloud/configuration.nix`**

Add a `let` binding at the top of the file (the current file has no `let` block — add one between the function args and the opening `{`):

```nix
{ config, pkgs, claude-code-nix, ... }:

let
  publicFqdn = "nextcloud.<PUBLIC_DOMAIN>";
  tunnelId = "<NEXTCLOUD_UUID>";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];
  # ... (rest unchanged until the changes below)
}
```

Then update `services.nextcloud.settings.trusted_domains`. Find:

```nix
    settings = {
      trusted_domains = [
        "nextcloud.tail1ec6c3.ts.net"
      ];
      default_phone_region = "US";
    };
```

Change to:

```nix
    settings = {
      trusted_domains = [
        "nextcloud.tail1ec6c3.ts.net"
        publicFqdn
      ];
      default_phone_region = "US";
    };
```

Add the cloudflared block. Insert it after the `services.nextcloud = { ... };` block and before the existing `networking.firewall...` line:

```nix
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:80";
      };
    };
  };
```

Note: nextcloud runs on port 80 (not 443) on this host — `services.nextcloud.https = false` is set, and nginx is internal. The cloudflared upstream points at that.

- [ ] **Step 4: Verify the build succeeds**

Run: `sudo nixos-rebuild build --flake .#nextcloud`
Expected: clean build.

- [ ] **Step 5: Commit the Nix change**

```bash
git add machines/nextcloud/configuration.nix
git commit -m "nextcloud: route public traffic via cloudflare tunnel"
```

- [ ] **Step 6: Deploy**

Run: `scripts/deploy.sh nextcloud`
Expected: succeeds; cloudflared unit fails awaiting credentials.

- [ ] **Step 7: Copy credentials**

```bash
scp ~/.cloudflared/<NEXTCLOUD_UUID>.json jeff@nextcloud:/tmp/<NEXTCLOUD_UUID>.json
ssh jeff@nextcloud 'sudo install -m 600 -o cloudflared -g cloudflared \
  /tmp/<NEXTCLOUD_UUID>.json /etc/cloudflared/<NEXTCLOUD_UUID>.json && \
  rm /tmp/<NEXTCLOUD_UUID>.json'
```

- [ ] **Step 8: Restart cloudflared**

Run: `ssh jeff@nextcloud 'sudo systemctl restart cloudflared-tunnel-<NEXTCLOUD_UUID>.service'`

- [ ] **Step 9: Verify service health**

Run: `ssh jeff@nextcloud 'sudo systemctl status cloudflared-tunnel-<NEXTCLOUD_UUID>.service --no-pager'`
Expected: `Active: active (running)` with edge connections registered.

- [ ] **Step 10: Verify public URL**

Run: `curl -sI https://nextcloud.<PUBLIC_DOMAIN>`
Expected: `HTTP/2 302` (redirect to login).

Open in a browser. The Nextcloud login page should render. If you see `Access through untrusted domain`, the `trusted_domains` edit didn't take effect — re-check step 3.

- [ ] **Step 11: Verify tailnet path**

Run: `curl -sI https://nextcloud.tail1ec6c3.ts.net`
Expected: `HTTP/2 302`. Tailnet access still works.

- [ ] **Step 12: Test file upload from a client**

Open the Nextcloud desktop or mobile client. Set the server URL to `https://nextcloud.<PUBLIC_DOMAIN>`. Log in. Upload a file. Confirm sync.

---

## Task 4: Immich public tunnel

Mobile uploads are the main reason to expose immich. Pay attention: cellular uploads can be large, so the cloudflared upstream needs to pass through to a nginx (which already has `client_max_body_size 0` and `proxy_request_buffering off`) — *or* we point cloudflared at immich's port directly. Direct is simpler; Cloudflare Free has a 100 MB upload limit per request, so a separate nginx wouldn't help with that anyway. Cellular video uploads >100 MB will need to fall back to the tailnet path until Cloudflare allows larger.

**Files:**
- Modify: `machines/immich/configuration.nix`

- [ ] **Step 1: Create the tunnel**

Run: `cloudflared tunnel create immich`
Expected: prints `<IMMICH_UUID>`.

- [ ] **Step 2: Create the DNS CNAME**

Run: `cloudflared tunnel route dns immich immich.<PUBLIC_DOMAIN>`
Expected: confirmation.

- [ ] **Step 3: Edit `machines/immich/configuration.nix`**

The existing `let` block already exists. Add `publicFqdn` and `tunnelId`:

Replace:
```nix
let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "immich.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
  dataDir = "/mnt/immich-data";
in
```
With:
```nix
let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "immich.${tailnet}";
  publicFqdn = "immich.<PUBLIC_DOMAIN>";
  tunnelId = "<IMMICH_UUID>";
  certDir = "/var/lib/tailscale-cert";
  dataDir = "/mnt/immich-data";
in
```

Rename `fqdn` to `tailnetFqdn` throughout the rest of the file:
- `services.nginx.virtualHosts.${fqdn}` → `services.nginx.virtualHosts.${tailnetFqdn}`
- The `tailscale cert ... ${fqdn}` line → `${tailnetFqdn}`

Add the cloudflared block. Insert it after the `services.nginx = { ... };` block and before `networking.firewall...`:

```nix
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:2283";
      };
    };
  };
```

- [ ] **Step 4: Verify the build**

Run: `sudo nixos-rebuild build --flake .#immich`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add machines/immich/configuration.nix
git commit -m "immich: route public traffic via cloudflare tunnel"
```

- [ ] **Step 6: Deploy**

Run: `scripts/deploy.sh immich`

- [ ] **Step 7: Copy credentials**

```bash
scp ~/.cloudflared/<IMMICH_UUID>.json jeff@immich:/tmp/<IMMICH_UUID>.json
ssh jeff@immich 'sudo install -m 600 -o cloudflared -g cloudflared \
  /tmp/<IMMICH_UUID>.json /etc/cloudflared/<IMMICH_UUID>.json && \
  rm /tmp/<IMMICH_UUID>.json'
```

- [ ] **Step 8: Restart cloudflared**

Run: `ssh jeff@immich 'sudo systemctl restart cloudflared-tunnel-<IMMICH_UUID>.service'`

- [ ] **Step 9: Verify service health**

Run: `ssh jeff@immich 'sudo systemctl status cloudflared-tunnel-<IMMICH_UUID>.service --no-pager'`
Expected: active running.

- [ ] **Step 10: Verify public URL**

Run: `curl -sI https://immich.<PUBLIC_DOMAIN>`
Expected: `HTTP/2 200` or `HTTP/2 302`.

Open in browser: Immich login should render.

- [ ] **Step 11: Verify tailnet path**

Run: `curl -sI https://immich.tail1ec6c3.ts.net`
Expected: `HTTP/2 200`.

- [ ] **Step 12: Test upload from the mobile app**

In the Immich app, change the server URL to `https://immich.<PUBLIC_DOMAIN>`. Sign in. Trigger a backup of a small photo. Confirm it appears in the timeline.

---

## Task 5: Paperless public tunnel

Paperless cares about CSRF — it'll reject POSTs (uploads, settings changes) if the request's effective URL doesn't match `PAPERLESS_URL`. Both `PAPERLESS_URL` and `PAPERLESS_TRUSTED_PROXIES` need to change.

**Files:**
- Modify: `machines/paperless/configuration.nix`

- [ ] **Step 1: Create the tunnel**

Run: `cloudflared tunnel create paperless`
Expected: prints `<PAPERLESS_UUID>`.

- [ ] **Step 2: Create the DNS CNAME**

Run: `cloudflared tunnel route dns paperless paperless.<PUBLIC_DOMAIN>`
Expected: confirmation.

- [ ] **Step 3: Edit `machines/paperless/configuration.nix`**

Update the existing `let` block:

Replace:
```nix
let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "paperless.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
in
```
With:
```nix
let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "paperless.${tailnet}";
  publicFqdn = "paperless.<PUBLIC_DOMAIN>";
  tunnelId = "<PAPERLESS_UUID>";
  certDir = "/var/lib/tailscale-cert";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
in
```

Rename `fqdn` to `tailnetFqdn` in nginx + tailscale-cert references (`virtualHosts.${fqdn}` and the `tailscale cert ... ${fqdn}` line).

Update the paperless settings. Replace:
```nix
    settings = {
      PAPERLESS_URL = "https://${fqdn}";
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_TIME_ZONE = "America/Chicago";
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";
    };
```
With:
```nix
    settings = {
      PAPERLESS_URL = "https://${publicFqdn}";
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_TIME_ZONE = "America/Chicago";
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";
    };
```

(`PAPERLESS_TRUSTED_PROXIES` stays `127.0.0.1` because both nginx and cloudflared connect from loopback.)

Add the cloudflared block. Insert it after `services.nginx = { ... };` and before `networking.firewall...`:

```nix
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:28981";
      };
    };
  };
```

- [ ] **Step 4: Verify the build**

Run: `sudo nixos-rebuild build --flake .#paperless`
Expected: clean build.

- [ ] **Step 5: Commit**

```bash
git add machines/paperless/configuration.nix
git commit -m "paperless: route public traffic via cloudflare tunnel"
```

- [ ] **Step 6: Deploy**

Run: `scripts/deploy.sh paperless`

- [ ] **Step 7: Copy credentials**

```bash
scp ~/.cloudflared/<PAPERLESS_UUID>.json jeff@paperless:/tmp/<PAPERLESS_UUID>.json
ssh jeff@paperless 'sudo install -m 600 -o cloudflared -g cloudflared \
  /tmp/<PAPERLESS_UUID>.json /etc/cloudflared/<PAPERLESS_UUID>.json && \
  rm /tmp/<PAPERLESS_UUID>.json'
```

- [ ] **Step 8: Restart cloudflared**

Run: `ssh jeff@paperless 'sudo systemctl restart cloudflared-tunnel-<PAPERLESS_UUID>.service'`

- [ ] **Step 9: Verify service health**

Run: `ssh jeff@paperless 'sudo systemctl status cloudflared-tunnel-<PAPERLESS_UUID>.service --no-pager'`
Expected: active running.

- [ ] **Step 10: Verify public URL**

Run: `curl -sI https://paperless.<PUBLIC_DOMAIN>`
Expected: `HTTP/2 200` or `HTTP/2 302`. The login page should render in a browser.

- [ ] **Step 11: Verify tailnet path**

Run: `curl -sI https://paperless.tail1ec6c3.ts.net`
Expected: `HTTP/2 200`.

- [ ] **Step 12: Test a document upload over the public URL**

Log in to `https://paperless.<PUBLIC_DOMAIN>`. Drag-drop a small PDF onto the consume area (or upload via the UI). Confirm it ingests without a CSRF error. CSRF rejection here means `PAPERLESS_URL` doesn't match the actual request URL — re-check step 3.

---

## Task 6: Document the bootstrap gotcha

Future-you (and future-claude) need to know that adding a new cloudflared host requires the credentials JSON to be installed out-of-band before the unit will start. Same flavor as the existing `tailscale-cert` note.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a bootstrap note to `CLAUDE.md`**

Open `CLAUDE.md`. Find the "Bootstrapping a new host" section (under "Fleet deploys with Colmena"). Add a new bullet under the existing steps, after the `scripts/deploy.sh <host>` line:

Replace:
```markdown
3. After it comes back up, `scripts/deploy.sh <host>` works going forward.
```

With:
```markdown
3. After it comes back up, `scripts/deploy.sh <host>` works going forward.
4. If the host runs `services.cloudflared`: the first deploy will activate but the `cloudflared-tunnel-<uuid>` unit will fail until you `scp` the tunnel credentials JSON into `/etc/cloudflared/<uuid>.json` (mode `0600`, owner `cloudflared:cloudflared`) and `systemctl restart` the unit. See `docs/superpowers/plans/2026-05-14-cloudflare-tunnel.md` for the full bootstrap.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: note cloudflared first-deploy credentials gotcha"
```

- [ ] **Step 3: Add a memory entry**

Create `/home/enum/.claude/projects/-home-enum-Projects-nixos-config/memory/project_cloudflare_tunnel.md` with:

```markdown
---
name: project-cloudflare-tunnel
description: cloudflared first-deploy gotcha — credentials JSON must be installed out-of-band before the unit will start
metadata:
  type: project
---

Hosts with `services.cloudflared` need the tunnel credentials JSON installed at `/etc/cloudflared/<uuid>.json` (mode `0600`, owner `cloudflared:cloudflared`) before the `cloudflared-tunnel-<uuid>` unit will start. The user is created during the deploy, so the order is: deploy → scp creds → chown → `systemctl restart`.

**Why:** Same shape as the existing tailscale-cert gotcha. The credentials file is sensitive and lives outside the repo. The systemd unit fails closed on first deploy, which is the desired safe default.

**How to apply:** When adding a new public-facing host, follow `docs/superpowers/plans/2026-05-14-cloudflare-tunnel.md`. The deploy itself works; the activation step is the credentials install. See also [[project-tailscale-cert]].
```

Then append a line to `/home/enum/.claude/projects/-home-enum-Projects-nixos-config/memory/MEMORY.md`:

```markdown
- [cloudflared first-deploy gotcha](project_cloudflare_tunnel.md) — credentials JSON must be `scp`'d to `/etc/cloudflared/` after the first deploy; matches the tailscale-cert pattern
```

(The MEMORY.md file lives outside the repo, so no commit.)

---

## Done

All four services exposed publicly under `<PUBLIC_DOMAIN>`. Tailnet paths unchanged. Bootstrap gotcha documented. The pattern is reusable for any future host that needs public exposure — copy the cloudflared block, create a tunnel, route a CNAME, drop the JSON.
