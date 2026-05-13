{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "paperless.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
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

  networking.hostName = "paperless";

  # Paperless-ngx: document management with OCR + full-text search. The
  # NixOS module wires up redis + the django app + the consumer + the
  # scheduler as separate systemd units. SQLite is the default backend;
  # fine for a single-user homelab. Files live under /var/lib/paperless.
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;

    # Initial admin user. Provision the password file out-of-band before
    # first start (paperless reads it on first boot to seed the user):
    #   echo -n 'mypass' | sudo install -m 600 -o paperless -g paperless \
    #     /dev/stdin /etc/paperless-admin-pass
    passwordFile = "/etc/paperless-admin-pass";

    settings = {
      PAPERLESS_URL = "https://${fqdn}";
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_TIME_ZONE = "America/Chicago";
      # Trust the reverse proxy; without this, CSRF rejects uploads.
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";
    };
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
    virtualHosts.${fqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/cert.pem";
      sslCertificateKey = "${certDir}/key.pem";

      # Multi-page PDF scans can easily blow past the default 1M cap.
      extraConfig = ''
        client_max_body_size 100M;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:28981";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for paperless";
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
        ${fqdn}
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

  # Daily encrypted backup of paperless state to B2: the SQLite DB, the
  # original PDFs, the OCR'd archive copies, the thumbnails, and the
  # search index. The consume/ drop folder is excluded — anything in
  # there is in-flight and will get re-ingested anyway.
  services.restic.backups.paperless = {
    paths = [ "/var/lib/paperless" ];
    exclude = [ "/var/lib/paperless/consume" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/paperless";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "daily";
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
