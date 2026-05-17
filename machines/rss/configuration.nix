{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "rss.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
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

  system.stateVersion = "25.11";
}
