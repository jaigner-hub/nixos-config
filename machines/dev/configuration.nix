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
