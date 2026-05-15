{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  # Tailscale only issues certs for the node's own MagicDNS name, so we
  # serve gatus at https://monitor.<tailnet>/ rather than a custom subdomain.
  fqdn = "monitor.${tailnet}";
  certDir = "/var/lib/tailscale-cert";
  # Hosts to scrape node_exporter on. NixOS hosts resolve over Tailscale MagicDNS;
  # the Proxmox hypervisor isn't on the tailnet, so it's reached by LAN IP.
  scrapeTargets = [
    "monitor:9100"
    "nass:9100"
    "dev:9100"
    "nextcloud:9100"
    "vaultwarden:9100"
    "adguard:9100"
    "adguard2:9100"
    "paperless:9100"
    "10.0.0.55:9100"
  ];
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

  networking.hostName = "monitor";

  services.prometheus = {
    enable = true;
    port = 9090;
    listenAddress = "0.0.0.0";
    retentionTime = "30d";

    scrapeConfigs = [
      {
        job_name = "node";
        static_configs = [
          { targets = scrapeTargets; }
        ];
      }
      {
        job_name = "prometheus";
        static_configs = [
          { targets = [ "localhost:9090" ]; }
        ];
      }
      {
        job_name = "gatus";
        static_configs = [
          { targets = [ "localhost:8080" ]; }
        ];
      }
    ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        root_url = "http://monitor:3000/";
      };
      analytics.reporting_enabled = false;

      # Secret read at startup from /etc/grafana-secret-key (not in repo).
      # Provision with (must be readable by the grafana service user):
      #   sudo install -m 600 -o grafana -g grafana /dev/stdin /etc/grafana-secret-key \
      #     <<<"$(head -c 64 /dev/urandom | base64)"
      security.secret_key = "$__file{/etc/grafana-secret-key}";
    };

    provision = {
      enable = true;
      datasources.settings.datasources = [
        {
          name = "Prometheus";
          type = "prometheus";
          access = "proxy";
          url = "http://localhost:9090";
          isDefault = true;
        }
      ];
    };
  };

  # Uptime monitoring for fleet services. Web UI at https://${fqdn}/,
  # Prometheus metrics scraped from /metrics (job_name = "gatus" above).
  services.gatus = {
    enable = true;
    settings = {
      web = {
        address = "127.0.0.1";
        port = 8080;
      };
      metrics = true;

      endpoints = [
        {
          name = "adguard-ui";
          group = "homelab";
          url = "https://adguard.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
        }
        {
          name = "adguard-dns";
          group = "homelab";
          url = "tcp://adguard:53";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
        }
        {
          name = "adguard2-ui";
          group = "homelab";
          url = "https://adguard2.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
        }
        {
          name = "adguard2-dns";
          group = "homelab";
          url = "tcp://adguard2:53";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
        }
        {
          name = "vaultwarden";
          group = "homelab";
          url = "https://vaultwarden.${tailnet}/alive";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
        }
        {
          name = "nextcloud";
          group = "homelab";
          url = "http://nextcloud/status.php";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[BODY].installed == true" ];
        }
        {
          name = "paperless";
          group = "homelab";
          url = "https://paperless.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
        }
        {
          name = "jellyfin";
          group = "homelab";
          url = "http://nass:8096/health";
          interval = "1m";
          conditions = [ "[STATUS] == 200" ];
        }
        {
          name = "grafana";
          group = "internal";
          url = "http://localhost:3000/api/health";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[BODY].database == ok" ];
        }
        {
          name = "prometheus";
          group = "internal";
          url = "http://localhost:9090/-/healthy";
          interval = "1m";
          conditions = [ "[STATUS] == 200" ];
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
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;
      };
    };
  };

  # tailscale0 is trusted via common/base.nix (all ports open). Open 443 on
  # tailnet for the Gatus web UI.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  # See `project_tailscale_cert.md` memory note: this must be started manually
  # the first time (`sudo systemctl start tailscale-cert`) before nginx will
  # find the cert files. The timer keeps it renewed weekly after that.
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for monitor (gatus)";
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

  # Daily encrypted backup of Grafana dashboards/config to B2.
  # Prometheus metrics are intentionally excluded — too large, regenerable
  # from the underlying exporters. Secrets at /etc/restic/{password,b2.env}.
  services.restic.backups.grafana = {
    paths = [ "/var/lib/grafana" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/grafana";
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
