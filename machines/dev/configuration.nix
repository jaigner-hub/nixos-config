{ config, pkgs, claude-code-nix, ... }:

{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "dev";

  users.users.jeff.extraGroups = [ "docker" ];

  virtualisation.docker.enable = true;

  # FHS compatibility for a dev box running third-party tooling. NixOS has no
  # /bin/bash or /usr/bin/python, which breaks vendored scripts (e.g. zrag's
  # helper scripts) and prebuilt dynamically-linked binaries.
  #   - envfs: FUSE-populates /bin and /usr/bin from PATH on demand, so
  #     `#!/bin/bash` / `#!/usr/bin/env python` shebangs resolve.
  #   - nix-ld: provides the dynamic-linker shim so prebuilt ELF binaries
  #     (pip/npm native blobs, downloaded CLIs) run without patchelf.
  # Intentionally dev-only — the servers stay strict NixOS.
  services.envfs.enable = true;
  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs; [
    neovim

    python3
    python3Packages.pip
    python3Packages.virtualenv

    nodejs_20

    mariadb.client

    docker-compose

    gcc
    gnumake
    gdb
    pkg-config

    libmysqlclient
    libffi
    openssl
    zlib
  ];

  system.stateVersion = "25.11";
}
