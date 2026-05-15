{ config, pkgs, claude-code-nix, ... }:

let
  publicFqdn = "nextcloud.youtalklikeafag.com";
  tunnelId = "d35e5eb5-4734-453e-b5ea-ddf4506b5d3c";
in
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
        publicFqdn
      ];
      default_phone_region = "US";
    };
  };

  # Public access via Cloudflare Tunnel. The outbound cloudflared daemon
  # holds a connection to Cloudflare's edge and forwards requests to
  # nextcloud on loopback; TLS terminates at the edge. Tailnet access
  # over `*.ts.net` still goes direct to port 80 on this host.
  #
  # Credentials provisioned out-of-band at /etc/cloudflared/<uuid>.json
  # (root:root 0600). The nixpkgs module uses DynamicUser + LoadCredential,
  # so systemd reads the file as root before privilege drop. After the
  # first deploy: `sudo mkdir -p /etc/cloudflared && sudo install -m 600
  # -o root -g root <src> /etc/cloudflared/${tunnelId}.json` then restart
  # the unit.
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:80";
      };
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
