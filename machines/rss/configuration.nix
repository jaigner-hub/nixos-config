{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "rss.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
  b2Bucket = "Backup-jaigner-homelab";
  b2Endpoint = "s3.us-east-005.backblazeb2.com";
  backupDir = "/var/backups/miniflux";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "rss";

  # Miniflux: single-binary Go RSS reader, Postgres backend (auto-provisioned
  # by the module). Bound to loopback; nginx terminates TLS and proxies in.
  # Admin user seeded from the creds file on first start; provision before
  # first activation or the unit will fail with a missing EnvironmentFile.
  #   printf 'ADMIN_USERNAME=admin\nADMIN_PASSWORD=<pw>\n' \
  #     | sudo install -m 600 -o root -g root /dev/stdin /etc/miniflux-admin-creds
  services.miniflux = {
    enable = true;
    adminCredentialsFile = "/etc/miniflux-admin-creds";
    config = {
      LISTEN_ADDR = "127.0.0.1:8080";
      BASE_URL = "https://${tailnetFqdn}";
      LOG_FORMAT = "json";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${tailnetFqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/cert.pem";
      sslCertificateKey = "${certDir}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for rss";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      set -euo pipefail
      mkdir -p ${certDir}
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file ${certDir}/cert.pem \
        --key-file ${certDir}/key.pem \
        ${tailnetFqdn}
      chown -R nginx:nginx ${certDir}
      chmod 0644 ${certDir}/cert.pem
      chmod 0600 ${certDir}/key.pem
      ${pkgs.systemd}/bin/systemctl reload-or-restart nginx.service || true
    '';
  };

  systemd.timers.tailscale-cert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  # Ensure the backup dir exists with the right ownership before either the
  # dump or restic try to use it.
  systemd.tmpfiles.rules = [
    "d ${backupDir} 0750 postgres postgres -"
  ];

  # Daily pg_dump of the miniflux DB into the backup dir. Atomic rename so a
  # half-written dump never replaces a good one. Runs as the `postgres` user
  # so it can connect via the default peer-auth unix socket.
  systemd.services.miniflux-db-backup = {
    description = "Dump miniflux Postgres DB for offsite backup";
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
    };
    script = ''
      set -euo pipefail
      ${config.services.postgresql.package}/bin/pg_dump \
        --clean --no-owner --no-privileges miniflux \
        | ${pkgs.gzip}/bin/gzip > ${backupDir}/miniflux.sql.gz.tmp
      mv ${backupDir}/miniflux.sql.gz.tmp ${backupDir}/miniflux.sql.gz
    '';
  };

  systemd.timers.miniflux-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  # Daily encrypted restic snapshot of the dump dir to Backblaze B2.
  # Runs roughly 90 minutes after the db-backup timer (same pattern as
  # immich) so the dump is always fresh when restic sweeps it up.
  services.restic.backups.rss = {
    paths = [ backupDir ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/rss";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "*-*-* 04:30:00";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  system.stateVersion = "25.11";
}
