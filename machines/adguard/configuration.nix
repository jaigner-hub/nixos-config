{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "adguard.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
in
{
  imports = [
    ../../common/base.nix
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "adguard";

  # AdGuard binds 0.0.0.0:53 for DNS. systemd-resolved's stub listener on
  # 127.0.0.53:53 would collide, so disable the stub. Resolved itself stays
  # enabled for its bus API; local lookups route through AdGuard via 127.0.0.1.
  services.resolved.settings.Resolve.DNSStubListener = false;
  networking.nameservers = [ "127.0.0.1" "1.1.1.1" ];

  services.adguardhome = {
    enable = true;
    openFirewall = false;
    # First-boot setup wizard at https://${fqdn}/ creates the admin user.
    # mutableSettings=true lets the wizard's changes persist while still
    # re-applying the declared settings below on each rebuild.
    mutableSettings = true;
    settings = {
      http = {
        # Bind the web UI to loopback; nginx terminates TLS and proxies in.
        address = "127.0.0.1:3000";
      };

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        upstream_dns = [
          "https://dns.quad9.net/dns-query"
          "https://1.1.1.1/dns-query"
        ];
        bootstrap_dns = [
          "9.9.9.9"
          "149.112.112.112"
          "1.1.1.1"
        ];

        enable_dnssec = true;
      };

      filtering = {
        protection_enabled = true;
        filtering_enabled = true;
      };

      filters = [
        {
          enabled = true;
          id = 1;
          name = "AdGuard DNS filter";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
        }
        {
          enabled = true;
          id = 2;
          name = "AdAway Default Blocklist";
          url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
        }
      ];
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
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };

  # tailscale0 is trusted via common/base.nix (all ports open).
  # Open 443 for the web UI on tailnet, and 53 on the LAN interface so
  # non-tailnet clients (TVs, IoT, router) can also use this as their resolver.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for adguard";
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
