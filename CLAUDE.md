# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Multi-machine NixOS flake managing a small homelab. Hosts: `nas`, `dev`, `monitor`, `nextcloud`, `vaultwarden`, `adguard`, `adguard2`, `paperless`, `immich`. All machines share `common/base.nix` and are wired up through `flake.nix` via a `mkSystem` helper. The same host list is exposed as a [Colmena](https://colmena.cli.rs/) hive for fleet-wide deploys.

## Common commands

Run from `/etc/nixos` (or any checkout). The `#<host>` selector picks one of the hosts listed above.

- Apply config on the current machine: `sudo nixos-rebuild switch --flake .#<host>`
- Dry-build without activating: `sudo nixos-rebuild build --flake .#<host>`
- Build a throwaway VM for a host (produces `./result` symlink and a `*.qcow2` runner): `nixos-rebuild build-vm --flake .#<host>` then `./result/bin/run-<host>-vm`. The `vmVariant` in `common/base.nix` autologins root with an empty password.
- Validate the flake: `nix flake check`
- Update inputs (`nixpkgs`, `claude-code-nix`): `nix flake update`

### Fleet deploys with Colmena

Drives every host in the hive from one machine. Run from anywhere with `nix` installed; targets connect over SSH as `jeff` (key-only, passwordless wheel).

- **`scripts/deploy.sh`** — probes which hosts are reachable, then deploys to those. Pass host names to limit (e.g. `scripts/deploy.sh adguard nas`). This is the day-to-day command.
- Raw colmena:
  - List hive nodes: `nix run nixpkgs#colmena -- eval -E '{ nodes, ... }: builtins.attrNames nodes'`
  - Build every host without pushing: `nix run nixpkgs#colmena -- build`
  - Deploy to one host: `nix run nixpkgs#colmena -- apply --on nas`
  - Deploy with non-default semantics (`boot`, `test`, `dry-activate` instead of the default `switch`): `nix run nixpkgs#colmena -- apply boot`

Target hostnames default to the directory name (resolved via Tailscale MagicDNS). The `nas` directory targets the `nass` hostname — overridden in `flake.nix:targetHostFor` and mirrored in `scripts/deploy.sh:SSH_TARGET`. Add `--impure` if the working tree is dirty.

### Proxmox hypervisor management

The VMs above all run on a single Proxmox host at `10.0.0.55:8006`. Two things give visibility into it without web-UI clicking:

- **Read-only metrics (always-on):** `prometheus-pve-exporter` on `monitor` scrapes the PVE API and feeds Prometheus / Grafana dashboard 15983. Use this for historical/at-a-glance memory & CPU. Token is `pve-exporter@pve!exporter` with `PVEAuditor`. See [[project-pve-exporter-perms]] memory for the auth quirk.
- **Active management (token-gated):** `scripts/pve` wraps the PVE API using `~/.config/proxmox/credentials` (mode 600, never in repo). Token is `claude@pve!mgmt` with a custom `ClaudeMgmt` role: `VM.Audit, Sys.Audit, Datastore.Audit, VM.Config.Memory, VM.Config.CPU, VM.PowerMgmt, VM.Snapshot, VM.Snapshot.Rollback` on `/` — can resize memory/CPU, power-cycle, snapshot+rollback, but **cannot create/delete VMs, modify disks/network, or access the console.** Common usage:
  - `scripts/pve list` — VM table with allocated vs used memory
  - `scripts/pve config <vmid>` — full QEMU config of one VM
  - `scripts/pve set-memory <vmid> <MB>` — change config (next boot)
  - `scripts/pve power <vmid> <start|stop|shutdown|reboot>`
  - `scripts/pve snapshot <vmid> <name> [description]`
  - `scripts/pve api <METHOD> <path> [curl args]` — raw call

Memory config changes are queued until the next VM start — `qm` does not hotplug memory on these VMs (no `balloon` set).

#### Bootstrapping a new host

First-time deploy requires a manual step because `colmena` needs `jeff` in `nix.settings.trusted-users` and passwordless `sudo` on the target, both of which only land *after* the new config is activated. Bootstrap:

1. From the host's console (or SSH): `nixos-generate-config --show-hardware-config` and replace `machines/<host>/hardware-configuration.nix` with that output (the committed placeholder uses `by-label` paths that won't exist on cloned VMs).
2. `sudo nixos-rebuild boot --flake github:jaigner-hub/nixos-config#<host>` then reboot. Using `boot` (not `switch`) avoids live-restarting `boot.mount`, which can hang when the disk layout changes.
3. After it comes back up, `scripts/deploy.sh <host>` works going forward.
4. If the host runs `services.cloudflared`: the first deploy will activate but the `cloudflared-tunnel-<uuid>` unit will fail until you `sudo mkdir -p /etc/cloudflared` and `scp` the tunnel credentials JSON into `/etc/cloudflared/<uuid>.json` (mode `0600`, owner `root:root` — the unit uses `DynamicUser=true` + `LoadCredential=`, so root reads the file before privilege drop), then `systemctl restart` the unit. See `docs/superpowers/plans/2026-05-14-cloudflare-tunnel.md` for the full bootstrap.

`putio-sync.py` (run on `nas` only) supports `--dry-run` and `--seed` flags; it reads its token from `/etc/putio-sync.env` (via the systemd unit), `PUTIO_TOKEN`, or `~/.config/putio-sync/config.json`.

## Architecture

- `flake.nix` — `mkSystem` helper builds each `nixosSystem`, threading the `claude-code-nix` input through `specialArgs`. The host list lives once in the `hostNames` let-binding and feeds both `nixosConfigurations` (via `mkSystem`) and `colmena` (via `mkColmenaNode`). Add a host by creating `machines/<name>/{configuration,hardware-configuration}.nix` and appending `<name>` to `hostNames`.
- `common/base.nix` — shared baseline: flakes enabled, locale/timezone, the `jeff` user with a single authorized SSH key, OpenSSH, `claude-code-nix` package, and the VM-variant root autologin override. Everything common to all hosts belongs here, not in a per-host file.
- `machines/<name>/configuration.nix` — host-specific module. Each one imports `../../common/base.nix` and its sibling `hardware-configuration.nix`, sets `networking.hostName`, and adds host-specific services/packages.
- `machines/<name>/hardware-configuration.nix` — **placeholders**. The committed files describe a generic virtio disk for VM builds. Before deploying to real hardware, replace with the output of `nixos-generate-config --show-hardware-config` on the target. Do not "fix" the placeholder to match a specific machine in this repo — it intentionally stays generic so `build-vm` works for every host.
- `scripts/putio-sync.py` — Python script embedded into the `nas` configuration via `pkgs.writeScriptBin (builtins.readFile ...)`. Edits to this file take effect on the next `nixos-rebuild`; there is no separate install step. It shells out as the `jellyfin` user for filesystem operations and tracks synced files by put.io file ID in `/mnt/storage/.putio-sync-manifest.json` so local renames don't cause re-downloads.

### Host-specific notes

- `nas` — Jellyfin + Samba over a mergerfs union of `/mnt/hdd1` (21.8 TB) + `/mnt/hdd2` (4.5 TB) mounted at `/mnt/storage`. Also hosts `services.filebrowser` (public via cloudflared at `files.youtalklikeafag.com`), serves the Nextcloud and Immich data directories over NFSv4 to those hosts on the tailnet, runs the `putio-sync` systemd timer every 15 minutes (secrets in `/etc/putio-sync.env`), and is the origin for daily restic backups of Nextcloud, Immich, Filebrowser, and ntfy state to Backblaze B2. Also hosts self-hosted ntfy (`https://nass.tail1ec6c3.ts.net`) behind nginx + tailscale-cert, receiving systemd `OnFailure=` alerts from every host via `common/ntfy-notify.nix` plus uptime alerts from Gatus on `monitor` — three topics (`homelab-critical`/`-warn`/`-info`) with severity set per-subscription on the phone. Writer-token copies live at `/etc/ntfy-token` on every host and `/etc/gatus.env` on `monitor`. Hostname is `nass` (intentional, not a typo of the directory name).
- `dev` — Docker-enabled workstation with Python/Node/MariaDB-client toolchain. `jeff` is added to the `docker` group here.
- `auth` — SSO host: Pocket-ID (`https://auth.tail1ec6c3.ts.net`) behind nginx + tailscale-cert, providing OIDC for Grafana and Nextcloud (Phase 1 of SSO). Daily restic backup of `/var/lib/private/pocket-id` to Backblaze B2. The Pocket-ID encryption key at `/etc/pocket-id/encryption-key` and OIDC client secrets are provisioned out-of-band; ntfy used to live here but moved to `nass` so Pocket-ID could own the `auth` FQDN root.

## Conventions

- New shared options go in `common/base.nix`; per-host options go in `machines/<name>/configuration.nix`. Avoid duplicating settings across machine files.
- When adding a flake input that a machine module needs to consume, thread it through `mkSystem`'s `specialArgs` (follow the `claude-code-nix` pattern) rather than relying on `inputs` being globally available.
- Secrets (`/etc/putio-sync.env`, etc.) are referenced by path from the Nix configs but are provisioned out-of-band — do not commit them.
