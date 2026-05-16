{ config, pkgs, lib, claude-code-nix, mkNtfyOnFailure, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  fqdn = "auth.${tailnet}";
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

  # Pocket-ID. Single-binary OIDC IdP, SQLite-backed. The encryption key
  # at /etc/pocket-id/encryption-key is provisioned out-of-band on first
  # boot (see Task 2). Without it, pocket-id fails to start — that's the
  # expected first-deploy state and recovers on the manual restart in Task 2.
  #
  # WebAuthn relying-party ID is bound to this FQDN. If APP_URL ever
  # changes, every registered passkey is invalidated.
  services.pocket-id = {
    enable = true;
    settings = {
      APP_URL = "https://${fqdn}";
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

  # See `project_tailscale_cert.md`: this must be started manually
  # (`sudo systemctl start tailscale-cert`) on first deploy before nginx
  # finds the cert. Weekly timer keeps it renewed afterwards.
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for ${fqdn} (pocket-id)";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
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

  # Daily restic backup of pocket-id's SQLite store + config to B2.
  # Secrets at /etc/restic/{password,b2.env} (same convention as nass/monitor).
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

  # OnFailure hooks. Pocket-ID is critical — every SSO-integrated app loses
  # login the moment it goes down — so its failure pages out immediately.
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
