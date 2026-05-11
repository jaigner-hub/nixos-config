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
    };

    settings = {
      trusted_domains = [
        "nextcloud.<tailnet>.ts.net"
      ];
      default_phone_region = "US";
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

  system.stateVersion = "25.11";
}
