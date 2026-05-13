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
    "vaultwarden:9100"
    "adguard:9100"
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
