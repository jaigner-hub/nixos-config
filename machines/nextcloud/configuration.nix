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

  system.stateVersion = "25.11";
}
