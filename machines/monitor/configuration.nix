{ config, pkgs, claude-code-nix, mkNtfyOnFailure, ... }:

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
    "immich:9100"
    "auth:9100"
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
      # prometheus-pve-exporter (below) is a blackbox-style exporter: each
      # scrape targets a Proxmox host, but the request goes to the exporter
      # which queries that host's API and returns pve_* metrics. The relabel
      # swap moves the host into ?target= and rewrites __address__ to the
      # local exporter. Dashboard 15983 expects these metrics.
      {
        job_name = "pve";
        static_configs = [
          { targets = [ "10.0.0.55" ]; }
        ];
        metrics_path = "/pve";
        params = {
          module = [ "default" ];
          cluster = [ "1" ];
          node = [ "1" ];
        };
        relabel_configs = [
          { source_labels = [ "__address__" ]; target_label = "__param_target"; }
          { source_labels = [ "__param_target" ]; target_label = "instance"; }
          { target_label = "__address__"; replacement = "127.0.0.1:9221"; }
        ];
      }
    ];
  };

  # Proxmox metrics for dashboard 15983. The exporter talks to the Proxmox
  # API via a PVEAuditor token; credentials live in
  # /etc/prometheus-pve-exporter.yml (mode 0600 root:root), loaded via
  # systemd LoadCredential so DynamicUser still applies. Provision:
  #   sudo install -m 600 -o root -g root <src> /etc/prometheus-pve-exporter.yml
  services.prometheus.exporters.pve = {
    enable = true;
    port = 9221;
    configFile = "/etc/prometheus-pve-exporter.yml";
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
        # Fully-qualified tailnet hostname here so Grafana's OAuth
        # redirect_uri (root_url + /login/generic_oauth) matches the URL
        # the browser is actually on. With the short alias `monitor:3000`,
        # Pocket-ID would reject the redirect_uri.
        root_url = "http://monitor.${tailnet}:3000/";
      };
      analytics.reporting_enabled = false;

      # Secret read at startup from /etc/grafana-secret-key (not in repo).
      # Provision with (must be readable by the grafana service user):
      #   sudo install -m 600 -o grafana -g grafana /dev/stdin /etc/grafana-secret-key \
      #     <<<"$(head -c 64 /dev/urandom | base64)"
      security.secret_key = "$__file{/etc/grafana-secret-key}";

      # SSO via Pocket-ID over the tailnet. CLIENT_ID and CLIENT_SECRET
      # land via /etc/grafana-oidc.env (loaded as EnvironmentFile=) so
      # they stay out of the Nix store. Grafana's env-var override syntax
      # replaces any value of the corresponding INI key.
      "auth.generic_oauth" = {
        enabled = true;
        name = "Pocket-ID";
        client_id = "set-by-environment-file";
        client_secret = "set-by-environment-file";
        scopes = "openid profile email";
        auth_url = "https://auth.${tailnet}/authorize";
        token_url = "https://auth.${tailnet}/api/oidc/token";
        api_url = "https://auth.${tailnet}/api/oidc/userinfo";
        use_pkce = true;
        allow_sign_up = true;
        auto_login = false;
        # Single-operator homelab: every SSO user is Org Admin. The JMESPath
        # `to_string('Admin')` always evaluates to "Admin" — using a function
        # call instead of the bare literal `'Admin'` matters because Grafana's
        # INI parser strips outer single quotes from values, leaving bare
        # `Admin` which JMESPath then treats as a userinfo field lookup
        # (returns nothing → falls back to Viewer). Wrapping in to_string()
        # keeps the value's first/last chars off the quote-strip path.
        role_attribute_path = "to_string('Admin')";
      };
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

  # Grafana picks up GF_AUTH_GENERIC_OAUTH_CLIENT_ID/SECRET from this file
  # at service start, overriding the placeholder values in
  # services.grafana.settings. Provisioned out-of-band — see
  # /etc/grafana-oidc.env (mode 0600 grafana:grafana).
  systemd.services.grafana.serviceConfig.EnvironmentFile = "/etc/grafana-oidc.env";

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

      # Alert delivery via ntfy. The token is loaded from /etc/gatus.env at
      # service start (see systemd.services.gatus.serviceConfig.EnvironmentFile
      # below). $NTFY_TOKEN is expanded by Gatus at runtime, not by Nix.
      alerting = {
        ntfy = {
          url = "https://nass.${tailnet}";
          topic = "homelab-warn";
          token = "$NTFY_TOKEN";
          default-alert = {
            failure-threshold = 3;
            success-threshold = 2;
            send-on-resolved = true;
          };
        };
      };

      endpoints = [
        {
          name = "adguard-ui";
          group = "homelab";
          url = "https://adguard.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "adguard-dns";
          group = "homelab";
          url = "tcp://adguard:53";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "adguard2-ui";
          group = "homelab";
          url = "https://adguard2.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "adguard2-dns";
          group = "homelab";
          url = "tcp://adguard2:53";
          interval = "1m";
          conditions = [ "[CONNECTED] == true" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "vaultwarden";
          group = "homelab";
          url = "https://vaultwarden.${tailnet}/alive";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "nextcloud";
          group = "homelab";
          url = "http://nextcloud/status.php";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[BODY].installed == true" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "paperless";
          group = "homelab";
          url = "https://paperless.${tailnet}/";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[CERTIFICATE_EXPIRATION] > 168h" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "jellyfin";
          group = "homelab";
          url = "http://nass:8096/health";
          interval = "1m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "grafana";
          group = "internal";
          url = "http://localhost:3000/api/health";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[BODY].database == ok" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "prometheus";
          group = "internal";
          url = "http://localhost:9090/-/healthy";
          interval = "1m";
          conditions = [ "[STATUS] == 200" ];
          alerts = [ { type = "ntfy"; } ];
        }
        {
          name = "ntfy";
          group = "internal";
          url = "https://nass.${tailnet}/v1/health";
          interval = "1m";
          conditions = [ "[STATUS] == 200" "[BODY].healthy == true" ];
          alerts = [ { type = "ntfy"; } ];
        }
      ];
    };
  };

  # The nixpkgs services.gatus module doesn't expose environmentFile, so set
  # it via a systemd unit override. /etc/gatus.env holds NTFY_TOKEN, mode 0600
  # root:root, provisioned out-of-band.
  systemd.services.gatus.serviceConfig.EnvironmentFile = "/etc/gatus.env";

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

  # ntfy failure notifications. Grafana backup is critical (config + dashboards
  # are the only state worth keeping here — metrics are regenerable). tailscale-cert
  # is warn-tier: a renewal flake won't break anything until the cert is within a
  # week of expiry, which gives plenty of recovery time.
  systemd.services."ntfy-failed-restic-grafana" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "monitor: restic backup (grafana) failed";
    } "restic-backups-grafana.service";
  systemd.services.restic-backups-grafana.onFailure = [ "ntfy-failed-restic-grafana.service" ];

  systemd.services."ntfy-failed-tailscale-cert" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "monitor: tailscale-cert failed";
    } "tailscale-cert.service";
  systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];

  systemd.services."ntfy-failed-pve-exporter" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "monitor: prometheus-pve-exporter failed";
    } "prometheus-pve-exporter.service";
  systemd.services.prometheus-pve-exporter.onFailure = [ "ntfy-failed-pve-exporter.service" ];

  system.stateVersion = "25.11";
}
