# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

Multi-machine NixOS flake managing a small homelab. Three hosts are defined: `nas`, `dev`, and `fragrance-app`. All machines share `common/base.nix` and are wired up through `flake.nix` via a `mkSystem` helper.

## Common commands

Run from `/etc/nixos`. The `#<host>` selector picks one of `nas`, `dev`, `fragrance-app`.

- Apply config on the current machine: `sudo nixos-rebuild switch --flake .#<host>`
- Dry-build without activating: `sudo nixos-rebuild build --flake .#<host>`
- Build a throwaway VM for a host (produces `./result` symlink and a `*.qcow2` runner): `nixos-rebuild build-vm --flake .#<host>` then `./result/bin/run-<host>-vm`. The `vmVariant` in `common/base.nix` autologins root with an empty password.
- Validate the flake: `nix flake check`
- Update inputs (`nixpkgs`, `claude-code-nix`): `nix flake update`

`putio-sync.py` (run on `nas` only) supports `--dry-run` and `--seed` flags; it reads its token from `/etc/putio-sync.env` (via the systemd unit), `PUTIO_TOKEN`, or `~/.config/putio-sync/config.json`.

## Architecture

- `flake.nix` — single `mkSystem` helper builds each `nixosSystem`, threading the `claude-code-nix` input through `specialArgs` so every machine module receives it as a function argument. Add a host by creating `machines/<name>/{configuration,hardware-configuration}.nix` and adding it to `nixosConfigurations`.
- `common/base.nix` — shared baseline: flakes enabled, locale/timezone, the `jeff` user with a single authorized SSH key, OpenSSH, `claude-code-nix` package, and the VM-variant root autologin override. Everything common to all hosts belongs here, not in a per-host file.
- `machines/<name>/configuration.nix` — host-specific module. Each one imports `../../common/base.nix` and its sibling `hardware-configuration.nix`, sets `networking.hostName`, and adds host-specific services/packages.
- `machines/<name>/hardware-configuration.nix` — **placeholders**. The committed files describe a generic virtio disk for VM builds. Before deploying to real hardware, replace with the output of `nixos-generate-config --show-hardware-config` on the target. Do not "fix" the placeholder to match a specific machine in this repo — it intentionally stays generic so `build-vm` works for every host.
- `scripts/putio-sync.py` — Python script embedded into the `nas` configuration via `pkgs.writeScriptBin (builtins.readFile ...)`. Edits to this file take effect on the next `nixos-rebuild`; there is no separate install step. It shells out as the `plex` user for filesystem operations and tracks synced files by put.io file ID in `/mnt/storage/.putio-sync-manifest.json` so local renames don't cause re-downloads.

### Host-specific notes

- `nas` — Jellyfin + Samba over a mergerfs union of `/mnt/hdd1` + `/mnt/hdd2` mounted at `/mnt/storage`. The `putio-sync` systemd timer fires every 15 minutes and reads secrets from `/etc/putio-sync.env` (not in the repo). Hostname is `nass` (intentional, not a typo of the directory name).
- `dev` — Docker-enabled workstation with Python/Node/MariaDB-client toolchain. `jeff` is added to the `docker` group here.
- `fragrance-app` — Django app served by gunicorn over a unix socket at `/run/fragrance-app/gunicorn.sock`, fronted by nginx on 80/443. A dedicated `fragrance-app` system user owns `/srv/fragrance-app`; the venv lives at `/srv/fragrance-app/venv` and the WSGI entrypoint is `fragrance_app.wsgi:application`. MariaDB is provisioned declaratively with database `fragrance_app`. Runtime env comes from `/etc/fragrance-app.env` (not in the repo). nginx is added to the app's group so it can read `static/` and `media/`.

## Conventions

- New shared options go in `common/base.nix`; per-host options go in `machines/<name>/configuration.nix`. Avoid duplicating settings across machine files.
- When adding a flake input that a machine module needs to consume, thread it through `mkSystem`'s `specialArgs` (follow the `claude-code-nix` pattern) rather than relying on `inputs` being globally available.
- Secrets (`/etc/putio-sync.env`, `/etc/fragrance-app.env`, etc.) are referenced by path from the Nix configs but are provisioned out-of-band — do not commit them.
