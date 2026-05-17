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
