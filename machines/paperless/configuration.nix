{ config, pkgs, claude-code-nix, ... }:

let
  tailnet = "tail1ec6c3.ts.net";
  tailnetFqdn = "paperless.${tailnet}";
  publicFqdn = "paperless.youtalklikeafag.com";
  tunnelId = "dc41e600-a029-4bee-88a7-f58a4ac3b031";
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

  networking.hostName = "paperless";

  # Paperless-ngx: document management with OCR + full-text search. The
  # NixOS module wires up redis + the django app + the consumer + the
  # scheduler as separate systemd units. SQLite is the default backend;
  # fine for a single-user homelab. Files live under /var/lib/paperless.
  services.paperless = {
    enable = true;
    address = "127.0.0.1";
    port = 28981;

    # Initial admin user. Provision the password file out-of-band before
    # first start (paperless reads it on first boot to seed the user):
    #   echo -n 'mypass' | sudo install -m 600 -o paperless -g paperless \
    #     /dev/stdin /etc/paperless-admin-pass
    passwordFile = "/etc/paperless-admin-pass";

    settings = {
      PAPERLESS_URL = "https://${publicFqdn}";
      PAPERLESS_OCR_LANGUAGE = "eng";
      PAPERLESS_TIME_ZONE = "America/Chicago";
      # Trust the reverse proxy; without this, CSRF rejects uploads.
      # Both nginx (tailnet) and cloudflared (public) connect from loopback.
      PAPERLESS_TRUSTED_PROXIES = "127.0.0.1";

      # OIDC via Pocket-ID. PAPERLESS_APPS *appends* to django's
      # INSTALLED_APPS — safe to set alongside paperless's own apps. The
      # provider config (with the client_secret) lives in
      # PAPERLESS_SOCIALACCOUNT_PROVIDERS, loaded from environmentFile
      # below so the secret stays out of the Nix store.
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";

      # First OIDC login auto-creates the local account (allauth
      # otherwise stops on a "complete signup" form).
      PAPERLESS_SOCIAL_AUTO_SIGNUP = "True";

      # Match OIDC users to existing local users by email so the first
      # OIDC login attaches to the existing `admin` account instead of
      # forking a new one. EMAIL_VERIFICATION=none skips allauth's
      # confirmation email step (we don't have outbound SMTP).
      PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = "none";
      PAPERLESS_ACCOUNT_AUTHENTICATION_METHOD = "username_email";
    };

    # Carries PAPERLESS_SOCIALACCOUNT_PROVIDERS — the whole provider JSON
    # blob including client_secret. Mode 0600 paperless:paperless on the
    # host. The value MUST be single-quoted: `KEY='{...json...}'`. systemd's
    # EnvironmentFile parser strips the outer quotes, and the
    # paperless-manage wrapper `source`s the same file from bash — without
    # single quotes, bash interprets the `{}` and `""` and mangles the JSON,
    # breaking every CLI invocation (`paperless-manage shell` etc).
    environmentFile = "/etc/paperless-oidc.env";
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

      # Multi-page PDF scans can easily blow past the default 1M cap.
      extraConfig = ''
        client_max_body_size 100M;
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:28981";
        proxyWebsockets = true;
      };
    };
  };

  # Public access via Cloudflare Tunnel. The outbound cloudflared daemon
  # holds a connection to Cloudflare's edge and forwards requests to
  # paperless on loopback; TLS terminates at the edge. The tailnet path
  # (nginx + tailscale-cert above) stays in place as a fallback and is
  # required for uploads >100 MB (Cloudflare Free's per-request limit).
  #
  # Credentials provisioned out-of-band at /etc/cloudflared/<uuid>.json
  # (root:root 0600). The nixpkgs module uses DynamicUser + LoadCredential,
  # so systemd reads the file as root before privilege drop. After the
  # first deploy: `sudo mkdir -p /etc/cloudflared && sudo install -m 600
  # -o root -g root <src> /etc/cloudflared/${tunnelId}.json` then restart
  # the unit.
  services.cloudflared = {
    enable = true;
    tunnels.${tunnelId} = {
      credentialsFile = "/etc/cloudflared/${tunnelId}.json";
      default = "http_status:404";
      ingress = {
        ${publicFqdn} = "http://127.0.0.1:28981";
      };
    };
  };

  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 443 ];

  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS cert for paperless";
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
        ${tailnetFqdn}
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

  # Daily encrypted backup of paperless state to B2: the SQLite DB, the
  # original PDFs, the OCR'd archive copies, the thumbnails, and the
  # search index. The consume/ drop folder is excluded — anything in
  # there is in-flight and will get re-ingested anyway.
  services.restic.backups.paperless = {
    paths = [ "/var/lib/paperless" ];
    exclude = [ "/var/lib/paperless/consume" ];
    repository = "s3:https://${b2Endpoint}/${b2Bucket}/paperless";
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
