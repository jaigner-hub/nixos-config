{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

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
    device = "nass.tail1ec6c3.ts.net:/mnt/storage/nextcloud";
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

    # user_oidc bridges Nextcloud's session/account model to an OIDC provider
    # (Pocket-ID, here). The app is pulled from upstream releases at deploy
    # time and dropped into Nextcloud's app directory; extraAppsEnable runs
    # `occ app:enable` for it on every nextcloud-setup run. The provider
    # itself is registered out-of-band via `occ user_oidc:provider` once,
    # against the Pocket-ID client created in the admin UI.
    extraApps = {
      user_oidc = pkgs.fetchNextcloudApp {
        url = "https://github.com/nextcloud-releases/user_oidc/releases/download/v8.10.1/user_oidc-v8.10.1.tar.gz";
        sha256 = "1zb6yrfalw2s0zbnxdqpnxlhvjmrrjv3i5461dag80i337zd3kj9";
        license = "agpl3Plus";
      };
    };
    extraAppsEnable = true;

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

      # Allow Nextcloud's PHP HTTP client to hit Pocket-ID at auth.tail1ec6c3.ts.net.
      # Nextcloud's default SSRF defense blocks .ts.net (and other "local") hostnames;
      # without this, user_oidc's discovery fetch returns "host violates local
      # access rules" and the OIDC flow can't bootstrap.
      allow_local_remote_servers = true;

      # Nextcloud's upstream is plain HTTP on loopback; TLS terminates at
      # the Cloudflare edge. Without these overrides Nextcloud detects
      # `http` from the local request and emits http:// URLs in responses,
      # which trips the browser client's "server URL doesn't start with
      # HTTPS" check during login.
      overwriteprotocol = "https";
      overwritehost = publicFqdn;
      "overwrite.cli.url" = "https://${publicFqdn}";

      # cloudflared connects from loopback, so without this Nextcloud sees
      # every request as coming from 127.0.0.1 and the brute-force throttle
      # bans that single "IP" — locking everyone out. Trusting the local
      # proxy makes Nextcloud honor the X-Forwarded-For header cloudflared
      # populates with the real client IP.
      trusted_proxies = [ "127.0.0.1" "::1" ];
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

  # ntfy failure notification. The DB dump feeds nas's restic-backups-nextcloud
  # at 04:00 — if this fails, the next-morning backup snapshot is missing the DB.
  systemd.services."ntfy-failed-nextcloud-db-backup" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "nextcloud: db-backup failed";
    } "nextcloud-db-backup.service";
  systemd.services.nextcloud-db-backup.onFailure = [ "ntfy-failed-nextcloud-db-backup.service" ];

  system.stateVersion = "25.11";
}
