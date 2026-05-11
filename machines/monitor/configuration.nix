{ config, pkgs, claude-code-nix, ... }:

let
  # Hosts to scrape node_exporter on. Names resolve over Tailscale MagicDNS.
  scrapeTargets = [
    "monitor:9100"
    "gateway:9100"
    "nass:9100"
    "dev:9100"
    "fragrance-app:9100"
    "nextcloud:9100"
  ];
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
    ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        # Expose this externally by reverse-proxying through `gateway`'s Caddy:
        #   reverse_proxy http://monitor:3000
        # and setting root_url to the public URL.
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

  system.stateVersion = "25.11";
}
