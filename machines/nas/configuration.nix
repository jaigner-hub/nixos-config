{ config, pkgs, claude-code-nix, ... }:

let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ../../scripts/putio-sync.py);
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "nass";

  environment.systemPackages = with pkgs; [
    iotop
    jellyfin
    samba
    mergerfs
    pythonWithPackages
    gcc
    gnumake
    gdb
    unixtools.netstat
    ffmpeg-full
    smartmontools
    hdparm
    parted
    ncdu
    p7zip
  ];

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "nass";
      };
      media = {
        path = "/mnt/storage";
        browseable = "yes";
        "read only" = "no";
      };
    };
  };

  users.groups.nextcloud = {
    gid = 994;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 994;
    description = "Nextcloud data owner (NFS UID/GID parity)";
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/nextcloud 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 2049 ];

  fileSystems."/mnt/hdd1" = {
    device = "/dev/disk/by-uuid/ca1567d9-3634-4e46-acd9-545d7525371b";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=1" ];
  };

  fileSystems."/mnt/hdd2" = {
    device = "/dev/disk/by-uuid/f15c866f-d200-4b12-866f-bd36c79c626b";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=1" ];
  };

  fileSystems."/mnt/storage" = {
    device = "/mnt/hdd1:/mnt/hdd2";
    fsType = "fuse.mergerfs";
    options = [ "nofail" "x-systemd.device-timeout=1" ];
  };

  systemd.services.putio-sync = {
    description = "put.io sync";
    serviceConfig = {
      ExecStart = "${pythonWithPackages}/bin/python3 ${syncScript}/bin/putio-sync";
      Type = "oneshot";
      EnvironmentFile = "/etc/putio-sync.env";
    };
  };

  systemd.timers.putio-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
    };
  };

  system.stateVersion = "25.11";
}
