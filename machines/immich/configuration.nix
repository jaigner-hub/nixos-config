{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "immich.${tailnet}";
  publicFqdn = "immich.youtalklikeafag.com";
  tunnelId = "a427442e-27ac-49ab-84b9-6d9002ec4533";
  certDir = "/var/lib/tailscale-cert";
  dataDir = "/mnt/immich-data";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "immich";

  # Stable UID/GID so files written over NFS have consistent ownership on
  # both sides. Must match the immich user declared on the nas.
  users.groups.immich = {
    gid = 5001;
  };
  users.users.immich = {
    uid = 5001;
  };

  fileSystems.${dataDir} = {
    device = "nass:/mnt/storage/immich";
    fsType = "nfs4";
    options = [
      "nofail"
      "x-systemd.automount"
      "x-systemd.device-timeout=10"
      "_netdev"
    ];
  };

  # Immich: self-hosted photo backup. The NixOS module wires up Postgres
  # (with the pgvecto.rs extension for vector search), Redis, the API
  # server, and the machine-learning sidecar. The library — originals,
  # thumbnails, encoded video, and ML model cache — lives on the NAS via
  # NFS so it shares the mergerfs pool with everything else.
  services.immich = {
    enable = true;
    host = "127.0.0.1";
    port = 2283;
    mediaLocation = dataDir;
  };

  # Make sure the NFS mount is up before immich tries to touch its library.
  systemd.services.immich-server = {
    after = [ "mnt-immich\\x2ddata.mount" ];
    requires = [ "mnt-immich\\x2ddata.mount" ];
  };
  systemd.services.immich-machine-learning = {
    after = [ "mnt-immich\\x2ddata.mount" ];
    requires = [ "mnt-immich\\x2ddata.mount" ];
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

      # Mobile uploads can include multi-GB videos; disable the cap.
      extraConfig = ''
        client_max_body_size 0;
        proxy_request_buffering off;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:2283";
        proxyWebsockets = true;
      };
    };
  };

  # Public access via Cloudflare Tunnel. The outbound cloudflared daemon
  # holds a connection to Cloudflare's edge and forwards requests to
  # immich on loopback; TLS terminates at the edge. The tailnet path
  # (nginx + tailscale-cert above) stays in place as a fallback and is
  # required for upload payloads >100 MB (Cloudflare Free's per-request
  # limit).
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
        ${publicFqdn} = "http://127.0.0.1:2283";
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for immich";
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

  # Daily Postgres dump into the NFS-mounted library. The NAS's restic
  # backup of /mnt/storage/immich runs 90 minutes later (04:30) and sweeps
  # this up, so one restore brings back both originals and DB. Same
  # pattern as the nextcloud host.
  systemd.services.immich-db-backup = {
    description = "Dump Immich Postgres DB to NFS for offsite backup";
    after = [ "postgresql.service" "mnt-immich\\x2ddata.mount" ];
    requires = [ "postgresql.service" "mnt-immich\\x2ddata.mount" ];
    serviceConfig = {
      Type = "oneshot";
      User = "immich";
      Group = "immich";
    };
    script = ''
      set -euo pipefail
      backupDir=${dataDir}/.db-backup
      mkdir -p "$backupDir"
      ${config.services.postgresql.package}/bin/pg_dump \
        --clean --no-owner --no-privileges immich \
        | ${pkgs.gzip}/bin/gzip > "$backupDir/immich.sql.gz.tmp"
      mv "$backupDir/immich.sql.gz.tmp" "$backupDir/immich.sql.gz"
    '';
  };

  systemd.timers.immich-db-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
  };

  system.stateVersion = "25.11";
}
