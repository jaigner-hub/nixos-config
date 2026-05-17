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

  system.stateVersion = "25.11";
}
