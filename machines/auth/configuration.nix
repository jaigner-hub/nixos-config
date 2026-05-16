{ config, pkgs, lib, claude-code-nix, mkNtfyOnFailure, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  ntfyFqdn = "auth.${tailnet}";
  idFqdn = "id.${tailnet}";
  certFqdns = [ ntfyFqdn idFqdn ];
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

  networking.hostName = "auth";

  # Self-hosted ntfy. Listens on loopback; nginx terminates TLS using the
  # tailscale-issued cert for ntfyFqdn.
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://${ntfyFqdn}";
      listen-http = "127.0.0.1:2586";
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";
      behind-proxy = true;
    };
  };

  # Pocket-ID. Single-binary OIDC IdP, SQLite-backed. The encryption key
  # at /etc/pocket-id/encryption-key is provisioned out-of-band on first
  # boot (see Task 2). Without it, pocket-id fails to start — that's the
  # expected first-deploy state and recovers on the manual restart in Task 2.
  services.pocket-id = {
    enable = true;
    settings = {
      APP_URL = "https://${idFqdn}";
      TRUST_PROXY = true;
      PORT = 3000;
      ANALYTICS_DISABLED = true;
    };
    credentials.ENCRYPTION_KEY = "/etc/pocket-id/encryption-key";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;

    virtualHosts.${ntfyFqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/${ntfyFqdn}/cert.pem";
      sslCertificateKey = "${certDir}/${ntfyFqdn}/key.pem";
      locations."/" = {
        proxyPass = "http://127.0.0.1:2586";
        proxyWebsockets = true;
      };
    };

    virtualHosts.${idFqdn} = {
      forceSSL = true;
      sslCertificate = "${certDir}/${idFqdn}/cert.pem";
      sslCertificateKey = "${certDir}/${idFqdn}/key.pem";
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  # Issue tailscale certs for every FQDN this host serves. Each lands at
  # ${certDir}/<fqdn>/{cert,key}.pem so nginx vhosts can reference their
  # own cert independently. First deploy needs a manual
  # `systemctl start tailscale-cert` — the timer keeps them renewed weekly
  # after that.
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS certs for ${lib.concatStringsSep ", " certFqdns}";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      ${lib.concatMapStringsSep "\n" (f: ''
        mkdir -p ${certDir}/${f}
        ${pkgs.tailscale}/bin/tailscale cert \
          --cert-file ${certDir}/${f}/cert.pem \
          --key-file ${certDir}/${f}/key.pem \
          ${f}
      '') certFqdns}
      chown -R nginx:nginx ${certDir}
      find ${certDir} -name cert.pem -exec chmod 0644 {} +
      find ${certDir} -name key.pem -exec chmod 0600 {} +
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

  # Daily restic backup of pocket-id's SQLite store + config to B2.
  # Secrets at /etc/restic/{password,b2.env} (same convention as monitor/nas).
  # The B2 application key for this repo is scoped to the pocket-id/ prefix only.
  services.restic.backups.pocket-id = {
    paths = [ "/var/lib/pocket-id" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/pocket-id";
    passwordFile = "/etc/restic/password";
    environmentFile = "/etc/restic/b2.env";
    initialize = true;
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 6"
    ];
  };

  # OnFailure hooks. ntfy is the publisher and the subscriber's primary
  # signal — if pocket-id breaks, the operator needs to know fast (every
  # SSO-integrated app loses login the moment Pocket-ID is unavailable).
  systemd.services."ntfy-failed-tailscale-cert" =
    mkNtfyOnFailure {
      topic = "homelab-warn";
      title = "auth: tailscale-cert failed";
    } "tailscale-cert.service";
  systemd.services.tailscale-cert.onFailure = [ "ntfy-failed-tailscale-cert.service" ];

  systemd.services."ntfy-failed-pocket-id" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "auth: pocket-id failed";
    } "pocket-id.service";
  systemd.services.pocket-id.onFailure = [ "ntfy-failed-pocket-id.service" ];

  systemd.services."ntfy-failed-restic-pocket-id" =
    mkNtfyOnFailure {
      topic = "homelab-critical";
      title = "auth: restic backup (pocket-id) failed";
    } "restic-backups-pocket-id.service";
  systemd.services.restic-backups-pocket-id.onFailure = [ "ntfy-failed-restic-pocket-id.service" ];

  system.stateVersion = "25.11";
}
