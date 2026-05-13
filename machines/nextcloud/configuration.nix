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
    gid = 5000;
  };
  users.users.nextcloud = {
    isSystemUser = true;
    group = "nextcloud";
    uid = 5000;
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
    package = pkgs.nextcloud32;
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
        "nextcloud.tail1ec6c3.ts.net"
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

  # Daily Postgres dump into the NFS-mounted data dir. The NAS's restic
  # backup of /mnt/storage/nextcloud runs an hour later and sweeps this up,
  # so a single restic restore brings back both files and DB.
  #
  # Runs as the nextcloud Linux user (peer auth → nextcloud PG role).
  # No superuser needed thanks to --no-owner --no-privileges.
  # No maintenance mode toggle: for personal homelab use at a quiet hour,
  # the risk of a torn dump is small. Wrap pg_dump with
  # `${pkgs.nextcloud32-occ}/bin/nextcloud-occ maintenance:mode --on/--off`
  # if you ever need fully consistent snapshots.
  systemd.services.nextcloud-db-backup = {
    description = "Dump Nextcloud Postgres DB to NFS for offsite backup";
    after = [ "postgresql.service" "mnt-nextcloud\\x2ddata.mount" ];
    requires = [ "postgresql.service" "mnt-nextcloud\\x2ddata.mount" ];
    serviceConfig = {
      Type = "oneshot";
      User = "nextcloud";
      Group = "nextcloud";
    };
    script = ''
      set -euo pipefail
      backupDir=/mnt/nextcloud-data/.db-backup
      mkdir -p "$backupDir"
      ${config.services.postgresql.package}/bin/pg_dump \
        --clean --no-owner --no-privileges nextcloud \
        | ${pkgs.gzip}/bin/gzip > "$backupDir/nextcloud.sql.gz.tmp"
      mv "$backupDir/nextcloud.sql.gz.tmp" "$backupDir/nextcloud.sql.gz"
    '';
  };

  systemd.timers.nextcloud-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  system.stateVersion = "25.11";
}
