{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "adguard2.${tailnet}";
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

  networking.hostName = "adguard2";

  # AdGuard binds 0.0.0.0:53 for DNS. systemd-resolved's stub listener on
  # 127.0.0.53:53 would collide, so disable the stub. Resolved itself stays
  # enabled for its bus API; local lookups route through AdGuard via 127.0.0.1.
  services.resolved.settings.Resolve.DNSStubListener = false;
  networking.nameservers = [ "127.0.0.1" "1.1.1.1" ];

  # Sibling of `adguard`. Each instance keeps its own state (config + filters
  # + stats DB) so they're independent — clients should be pointed at both
  # via DHCP so one going down doesn't take DNS with it. Blocklists and
  # upstreams are kept in sync via this declared config; admin-UI tweaks
  # made via mutableSettings will *not* propagate to the other instance.
  services.adguardhome = {
    enable = true;
    openFirewall = false;
    mutableSettings = true;
    settings = {
      # Admin user (same as `adguard`). Without this AdGuard ships with
      # `users: []` which leaves the admin UI completely unauthenticated
      # to anyone on the tailnet. Hash is bcrypt, safe to commit.
      users = [
        {
          name = "jeff";
          password = "$2b$10$VEJAfkz3u3EGTPYQFxz6hOptf1nJe1.7Q4DaaN4nSZbdqzgN2IDoG";
        }
      ];

      http = {
        address = "127.0.0.1:3000";
      };

      dns = {
        bind_hosts = [ "0.0.0.0" ];
        port = 53;

        upstream_dns = [
          # Domain-specific upstream: route tailnet MagicDNS queries to the
          # tailscale resolver. Without this, Go-based services like Alloy
          # (which read /etc/resolv.conf directly and bypass NSS) cannot
          # resolve sibling hosts like `monitor.tail1ec6c3.ts.net` even though
          # CLI tools work fine via NSS → systemd-resolved → tailscale link.
          "[/tail1ec6c3.ts.net/]100.100.100.100"
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

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];
  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for adguard2";
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

  # Daily encrypted backup of AdGuard state to B2. Stored under a separate
  # path from `adguard` so the two repos don't collide.
  #
  # Back up the real DynamicUser state dir, not the /var/lib/AdGuardHome
  # symlink to it — restic stores a top-level symlink as a symlink rather
  # than following it. See the adguard host for the full explanation.
  services.restic.backups.adguard = {
    paths = [ "/var/lib/private/AdGuardHome" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/adguard2";
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
