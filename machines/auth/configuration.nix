{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "auth.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "auth";

  # Self-hosted ntfy. Listens on loopback; nginx terminates TLS using the
  # tailscale-issued cert (same pattern as monitor's gatus vhost).
  #
  # auth-default-access = "deny-all" forces every publish/subscribe to carry
  # a valid token. Admin user + tokens are bootstrapped out-of-band via the
  # ntfy CLI on first deploy — they live in /var/lib/ntfy-sh/user.db, which
  # ntfy manages itself.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${fqdn}";
      listen-http = "127.0.0.1:2586";
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";
      behind-proxy = true;
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

      locations."/" = {
        proxyPass = "http://127.0.0.1:2586";
        proxyWebsockets = true;
      };
    };
  };

  # tailscale0 is trusted via common/base.nix (all ports open). Open 443
  # on the tailnet for nginx.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  # First-deploy gotcha: this unit must be manually started once
  # (`sudo systemctl start tailscale-cert`) before nginx will find the
  # cert files. The timer keeps it renewed weekly after that.
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for auth (ntfy)";
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

  system.stateVersion = "25.11";
}
