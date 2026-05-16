# SSO for the homelab

**Date:** 2026-05-16

## Problem

Each homelab app today carries its own user database and login UI. There are
six different passwords to remember (Nextcloud, Immich, Paperless, Jellyfin,
Grafana, Filebrowser), some of which I reuse out of laziness. There's no
single place to revoke a session, no audit trail, and no passkey support
anywhere — every login still goes through a password field.

Adding a self-hosted identity provider lets the apps that support OIDC defer
auth to a single passkeys-only login, and gives a path to retire the per-app
passwords as each integration lands.

## Approach

Stand up [Pocket-ID](https://pocket-id.org) on the existing `auth` host
alongside ntfy, exposed only on the tailnet via the same `nginx +
tailscale-cert` pattern. Apps with native OIDC support redirect to Pocket-ID
for authentication; Pocket-ID is the sole place WebAuthn passkeys are
registered. Apps without native OIDC support (Vaultwarden user-side, AdGuard,
Filebrowser, Gatus) stay on their existing auth — not every login has to flow
through SSO for SSO to be useful.

### Why Pocket-ID over Authelia / Keycloak / Authentik

- **Authentik** is the obvious pick if we wanted a feature-complete IdP, but
  it's a Django + PostgreSQL + Celery stack. It would more than double the
  resource footprint of `auth` and add a worker tier we don't need.
- **Keycloak** is a Java app on a similar scale; same problem, more sprawl.
- **Authelia** is leaner but is primarily a forward-auth proxy for apps that
  don't speak OIDC. Our problem is the opposite: most apps we care about
  *already* speak OIDC, so the proxy layer is wasted complexity.
- **Pocket-ID** is a single Go binary with a SQLite store. It's OIDC-only,
  passkeys-only by default, and was built specifically for a homelab-sized
  user base. Upstream `services.pocket-id` is already in nixpkgs.

The downside is that Pocket-ID doesn't do forward-auth, so any future
non-OIDC app we want behind SSO will need an `oauth2-proxy` sidecar or a
different solution. That's an acceptable trade for the simpler v1.

### Why tailnet-only, not public

Same reasoning as ntfy: every host that hits Pocket-ID is on the tailnet, and
the operator already runs Tailscale on every device. Public exposure would
add an attack surface (the IdP is the highest-value target in a homelab) and
no capability we need.

A consequence: the WebAuthn relying-party ID gets bound to
`id.tail1ec6c3.ts.net`. Passkeys are scoped to that exact origin — if we
later move Pocket-ID to a public domain, every registered passkey is
invalidated and has to be re-registered. v1 ships tailnet-only and accepts
that future re-registration cost.

### Why colocate on `auth`, not a new host

`auth` was provisioned specifically as the future home for SSO when ntfy
landed (see the ntfy design doc, "Why a dedicated `auth` VM"). The VM is
already running, hardware-config is real, restic isn't yet set up there but
the cost of adding it is the same regardless. A second VM would buy nothing.

## Scope

### New on `auth`

- `services.pocket-id` enabled, listening on `127.0.0.1:3000`.
- Second nginx vhost for `id.tail1ec6c3.ts.net`, terminating TLS via a
  per-FQDN tailscale cert.
- `tailscale-cert.service` refactored to issue certs for both FQDNs in one
  script. Certs land at `${certDir}/<fqdn>/{cert,key}.pem` so each vhost
  references its own files.
- `OnFailure=` hook for `pocket-id.service` via `mkNtfyOnFailure`.
- Restic backup unit for `/var/lib/pocket-id/` to the existing Backblaze B2
  bucket, under a new `pocket-id/` subpath. (Auth's first restic origin.)

### Per-app wiring

| Phase | App        | Host         | Integration                        |
|-------|------------|--------------|-------------------------------------|
| 1     | Grafana    | monitor      | built-in OIDC                       |
| 1     | Nextcloud  | nextcloud    | `oidc_login` app                    |
| 2     | Immich     | immich       | built-in OIDC                       |
| 2     | Paperless  | paperless    | `mozilla-django-oidc`               |
| 2     | Jellyfin   | nas          | `jellyfin-plugin-sso`               |

Phase 1 proves the pattern with two apps that have first-class OIDC support
and well-trodden Nix configs. Phase 2 lands once Phase 1 has run for at least
a week without surprises.

### Out of scope for v1

- **Vaultwarden user login.** Vaultwarden's OIDC support is admin-page-only;
  end users still authenticate with the master password (and have to —
  Vaultwarden is the password manager). Skipped permanently, not deferred.
- **AdGuard, Filebrowser, Gatus.** No native OIDC. Could be retrofitted later
  with `oauth2-proxy` in front, but each is already tailnet-only with
  acceptable auth (AdGuard admin user, filebrowser local user, Gatus has no
  auth and doesn't need it on the tailnet). Not worth the proxy layer in v1.
- **ntfy.** Token auth stays. ntfy *does* have recent OIDC support but
  retrofitting it would invalidate the writer tokens already deployed across
  the fleet for no functional gain.
- **Public exposure of Pocket-ID.** Deferred indefinitely; tailnet is enough.
- **Group-based authorization.** v1 is a single operator. Pocket-ID supports
  groups, but every app integration sets up admin-equivalent access for the
  one user. Multi-user / least-privilege is a later concern.

## Components

### Pocket-ID on `auth`

```nix
services.pocket-id = {
  enable = true;
  settings = {
    APP_URL = "https://id.${tailnet}";
    TRUST_PROXY = true;
    PORT = 3000;
    ANALYTICS_DISABLED = true;
  };
  # ENCRYPTION_KEY is required and must not live in the Nix store.
  credentials.ENCRYPTION_KEY = "/etc/pocket-id/encryption-key";
};
```

`ENCRYPTION_KEY` is a 32-byte hex string the operator generates once
(`openssl rand -hex 32 > /etc/pocket-id/encryption-key`, mode 0600
`pocket-id:pocket-id`) and is what derives the at-rest encryption for the
SQLite store. Rotating it invalidates every stored session and OIDC client
secret, so it gets generated once at bootstrap and never touched again. It
lives at `/etc/pocket-id/encryption-key` (out of the Nix store), referenced
through systemd `LoadCredential`.

SQLite store at `/var/lib/pocket-id/` (the module's default `dataDir`).

### tailscale-cert refactor on `auth`

The current `auth` config issues a single cert for `auth.tail1ec6c3.ts.net`
at `/var/lib/tailscale-cert/{cert,key}.pem`. We now need two certs. Refactor
to iterate over a list of FQDNs and write each cert under a per-FQDN subdir:

```nix
let
  tailnet = "tail1ec6c3.ts.net";
  certFqdns = [ "auth.${tailnet}" "id.${tailnet}" ];
  certDir = "/var/lib/tailscale-cert";
in {
  systemd.services.tailscale-cert = {
    description = "Issue/renew tailscale-issued TLS certs for ${concatStringsSep ", " certFqdns}";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      for fqdn in ${concatStringsSep " " certFqdns}; do
        mkdir -p ${certDir}/$fqdn
        ${pkgs.tailscale}/bin/tailscale cert \
          --cert-file ${certDir}/$fqdn/cert.pem \
          --key-file ${certDir}/$fqdn/key.pem \
          $fqdn
      done
      chown -R nginx:nginx ${certDir}
      find ${certDir} -name cert.pem -exec chmod 0644 {} +
      find ${certDir} -name key.pem -exec chmod 0600 {} +
      ${pkgs.systemd}/bin/systemctl reload-or-restart nginx.service || true
    '';
  };
}
```

Each nginx vhost references its own cert path:

```nix
virtualHosts."auth.${tailnet}" = {
  sslCertificate = "${certDir}/auth.${tailnet}/cert.pem";
  sslCertificateKey = "${certDir}/auth.${tailnet}/key.pem";
  # ...
};
virtualHosts."id.${tailnet}" = {
  sslCertificate = "${certDir}/id.${tailnet}/cert.pem";
  sslCertificateKey = "${certDir}/id.${tailnet}/key.pem";
  forceSSL = true;
  locations."/" = {
    proxyPass = "http://127.0.0.1:3000";
    proxyWebsockets = true;
  };
};
```

**Migration note:** the existing single-FQDN cert at
`${certDir}/{cert,key}.pem` becomes unused. The refactored unit creates the
new per-FQDN subdirs on first run, so `nginx` will fail to reload until
`systemctl start tailscale-cert` lands the new files. Same gotcha as the
first-deploy bootstrap of `auth` originally — `project_tailscale_cert.md`
already covers it.

### Failure handling

```nix
systemd.services."ntfy-failed-pocket-id" =
  mkNtfyOnFailure {
    topic = "homelab-critical";
    title = "auth: pocket-id failed";
  } "pocket-id.service";
systemd.services.pocket-id.onFailure = [ "ntfy-failed-pocket-id.service" ];
```

`homelab-critical` because a downed IdP knocks the whole SSO surface offline
once Phase 1 lands. Pre-Phase-1 it's just an unused service; the topic still
makes sense as the eventual default.

### Backup

`auth` doesn't currently run restic. Pocket-ID's state is small (sqlite +
config), and adding restic here is the right time to do it.

```nix
services.restic.backups.pocket-id = {
  paths = [ "/var/lib/pocket-id" ];
  repository = "b2:<bucket>:auth/pocket-id";  # bucket name out-of-band
  passwordFile = "/etc/restic-pocket-id.password";
  environmentFile = "/etc/restic-pocket-id.env";  # B2 keyID + appKey
  timerConfig = {
    OnCalendar = "daily";
    RandomizedDelaySec = "30m";
    Persistent = true;
  };
  pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
};

systemd.services."ntfy-failed-restic-pocket-id" =
  mkNtfyOnFailure {
    topic = "homelab-critical";
    title = "auth: restic-backups-pocket-id failed";
  } "restic-backups-pocket-id.service";
systemd.services.restic-backups-pocket-id.onFailure =
  [ "ntfy-failed-restic-pocket-id.service" ];
```

B2 credentials at `/etc/restic-pocket-id.{password,env}` provisioned
out-of-band (same pattern as nass's existing restic units). New B2
application key scoped to the `auth/` prefix only.

### Per-app OIDC client config

Each Phase 1 / Phase 2 app needs:

1. An OIDC client registered in Pocket-ID's admin UI. Returns a
   `client_id` and `client_secret`.
2. A `/etc/<app>-oidc.env` file on the target host (mode `0600 root:root`)
   carrying both values plus the discovery URL, provisioned out-of-band.
3. A small NixOS module change on the target host wiring the env file in via
   `services.<app>` options or `systemd.services.<app>.serviceConfig.EnvironmentFile`.

Concrete shape per app, to be expanded in the implementation plan:

- **Grafana**: `services.grafana.settings.auth.generic_oauth` populated
  with placeholders, real client_id/secret injected via `EnvironmentFile=`
  on `grafana.service` (the standard Nix idiom for Grafana secrets).
- **Nextcloud**: install the `oidc_login` app, configure via `occ` or via
  `services.nextcloud.settings`. Discovery URL points at Pocket-ID's
  `.well-known/openid-configuration`.
- **Immich**: `services.immich.settings.oauth` block.
- **Paperless**: `PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect`
  plus the standard django-allauth env vars.
- **Jellyfin**: install `jellyfin-plugin-sso` via the plugin manager (no Nix
  packaging upstream), configure in the Jellyfin admin UI.

## Bootstrap

First deploy (`auth` host). The first `colmena apply` will deploy a
Pocket-ID service that fails to start because the encryption key file
doesn't exist yet — that's expected and recovers automatically once the
key is in place.

1. `colmena apply --on auth` — activates Pocket-ID (will fail to start),
   the new vhost, and creates the `pocket-id` system user/group.
2. On the host, create the encryption key (32 random bytes, hex-encoded):
   ```bash
   sudo install -d -m 0700 -o pocket-id -g pocket-id /etc/pocket-id
   openssl rand -hex 32 | sudo tee /etc/pocket-id/encryption-key
   sudo chmod 0600 /etc/pocket-id/encryption-key
   sudo chown pocket-id:pocket-id /etc/pocket-id/encryption-key
   ```
3. `sudo systemctl start tailscale-cert` to issue both certs into the new
   per-FQDN subdirs.
4. `sudo systemctl restart pocket-id nginx` so both pick up the new state.
5. Open `https://id.tail1ec6c3.ts.net/setup` in a browser. Pocket-ID exposes
   a one-time admin setup flow on first launch (exact mechanism — token in
   journal vs. open-until-claimed setup page — verified at plan time).
   Register the first passkey and set the admin email.
6. In the admin UI, create one OIDC client per Phase 1 app (Grafana,
   Nextcloud). Note client_id and client_secret.
7. Drop each app's `/etc/<app>-oidc.env` onto the right host (mode
   `0600 root:root`).
8. Deploy the Phase 1 app changes; verify SSO works end-to-end before
   touching Phase 2.

Capture in memory after rollout:
- `project_pocket_id_bootstrap.md` — first-deploy gotcha (encryption key +
  setup token + per-app client secrets), mirroring the existing
  `project_ntfy_bootstrap.md` and `project_tailscale_cert.md`.

## Future considerations (deliberately deferred)

- **Public exposure.** Would require moving the relying-party ID, which
  invalidates passkeys. Path: add a cloudflared ingress (existing pattern),
  set Pocket-ID's `APP_URL` to the public hostname, re-register passkeys.
  Don't do this unless there's a concrete reason.
- **Group-based authorization.** If a second user ever joins, set up groups
  in Pocket-ID and use per-app role mapping. Until then, every client is
  effectively admin.
- **Forward-auth for non-OIDC apps.** If we later want AdGuard/Filebrowser
  behind SSO, the path is `oauth2-proxy` per app, not switching IdPs.
- **MaxMind GeoIP enrichment.** Pocket-ID can log auth attempts with city
  data via MaxMind. Skipped — single-operator, all logins from known IPs.
