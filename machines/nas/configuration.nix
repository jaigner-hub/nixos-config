{ config, pkgs, claude-code-nix, ... }:

let
  pythonWithPackages = pkgs.python3.withPackages (ps: with ps; [
    requests
  ]);
  syncScript = pkgs.writeScriptBin "putio-sync" (builtins.readFile ../../scripts/putio-sync.py);
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
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
    gid = 5000;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 5000;
    description = "Nextcloud data owner (NFS UID/GID parity)";
  };

  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/storage/nextcloud 100.64.0.0/10(rw,sync,no_subtree_check,no_root_squash)
    '';
  };

  services.nfs.settings = {
    nfsd.vers3 = false;
    nfsd.vers4 = true;
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

  # Daily encrypted backup of Nextcloud data (files + nightly DB dump) to B2.
  # The DB dump is produced on the nextcloud host's nextcloud-db-backup timer
  # at 03:00 into /mnt/storage/nextcloud/.db-backup/, so this fires at 04:00
  # to ensure the dump is captured in the same snapshot.
  #
  # Backing up here (where the files live) avoids pulling all Nextcloud data
  # back over NFS just to ship it offsite.
  #
  # Secrets at /etc/restic/{password,b2.env}, same format as on vaultwarden.
  services.restic.backups.nextcloud = {
    paths = [ "/mnt/storage/nextcloud" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/nextcloud";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  system.stateVersion = "25.11";
}
