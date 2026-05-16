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

Stand up [Pocket-ID](https://pocket-id.org) on the existing `auth` host at
`https://auth.tail1ec6c3.ts.net`, exposed only on the tailnet via the same
`nginx + tailscale-cert` pattern. Apps with native OIDC support redirect to
Pocket-ID for authentication; Pocket-ID is the sole place WebAuthn passkeys
are registered. Apps without native OIDC support (Vaultwarden user-side,
AdGuard, Filebrowser, Gatus) stay on their existing auth — not every login
has to flow through SSO for SSO to be useful.

### Tailscale cert constraint and the ntfy move

Discovered during the first deploy: Tailscale's `tailscale cert` command
only issues a cert for the machine's own MagicDNS name. There is no support
for additional hostnames or aliases on a single node. Pocket-ID requires
the root of an HTTPS-capable FQDN (no path-prefix mode), and ntfy is the
same — so they cannot share `auth.tail1ec6c3.ts.net`, and the originally
planned `id.tail1ec6c3.ts.net` cannot be issued.

Resolution: ntfy moves off `auth` to `nass.tail1ec6c3.ts.net` (the NAS,
which had no competing nginx vhost), and Pocket-ID takes over the `auth`
FQDN. Migration touches `common/ntfy-notify.nix` (URL change) and is
otherwise transparent to consumers — every fleet host picks up the new URL
on its next rebuild. The ntfy `user.db` rsyncs over to nass to preserve
writer tokens.

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
`auth.tail1ec6c3.ts.net`. Passkeys are scoped to that exact origin — if we
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
- Single nginx vhost for `auth.tail1ec6c3.ts.net`, replacing the prior
  ntfy vhost on the same FQDN. Cert continues to be issued via
  `tailscale-cert` at `/var/lib/tailscale-cert/{cert,key}.pem` — single
  FQDN, no refactor needed.
- `services.ntfy-sh` removed from auth.
- `OnFailure=` hook for `pocket-id.service` via `mkNtfyOnFailure`.
- Restic backup unit for `/var/lib/pocket-id/` to the existing Backblaze B2
  bucket, under a new `pocket-id/` subpath. (Auth's first restic origin.)

### New on `nass` (ntfy migration)

- `services.ntfy-sh` enabled, listening on `127.0.0.1:2586`.
- New nginx vhost for `nass.tail1ec6c3.ts.net` (nass's first tailnet
  HTTPS vhost) using the standard `tailscale-cert` pattern.
- Restic backup unit for `/var/lib/ntfy-sh/` to B2 under `ntfy/`.
- `OnFailure=` hooks for `ntfy-sh.service`, `tailscale-cert.service`,
  and `restic-backups-ntfy.service`.

### Updated elsewhere

- `common/ntfy-notify.nix`: `ntfyUrl` switched from
  `https://auth.tail1ec6c3.ts.net` to `https://nass.tail1ec6c3.ts.net`. Every
  fleet host picks this up on next rebuild.
- `monitor` Gatus config: ntfy alerting URL and the internal ntfy health
  endpoint repointed to `nass.tail1ec6c3.ts.net`.

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
    APP_URL = "https://auth.${tailnet}";
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

### tailscale-cert on `auth` and `nass`

Each host runs the standard single-FQDN `tailscale-cert` pattern (see the
existing pattern on `monitor`): one oneshot systemd unit writes
`/var/lib/tailscale-cert/{cert,key}.pem` for the host's MagicDNS name, a
weekly timer renews. nginx references those two paths.

`auth`'s existing tailscale-cert unit needs no changes — it already issues
for `auth.tail1ec6c3.ts.net`, which is now the Pocket-ID hostname.

`nass` gets the pattern added from scratch (it had no tailnet HTTPS vhost
before). Same first-deploy gotcha as every other host using this pattern
(`project_tailscale_cert.md`): the cert files only exist after a manual
`sudo systemctl start tailscale-cert` on first deploy; nginx will fail to
start until then.

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
config), and adding restic here is the right time to do it. Same goes for
`nass`'s new ntfy backup — `user.db` is small but recovery-critical (losing
it forces a rotate-everywhere on writer tokens).

```nix
# On auth
services.restic.backups.pocket-id = {
  paths = [ "/var/lib/pocket-id" ];
  repository = "s3:https://${b2Endpoint}/${b2Bucket}/pocket-id";
  passwordFile = "/etc/restic/password";
  environmentFile = "/etc/restic/b2.env";
  initialize = true;
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
    title = "auth: restic backup (pocket-id) failed";
  } "restic-backups-pocket-id.service";
systemd.services.restic-backups-pocket-id.onFailure =
  [ "ntfy-failed-restic-pocket-id.service" ];
```

`nass`'s new ntfy backup follows the same shape pointed at the `ntfy/`
prefix in the same bucket. Both reuse the standard
`/etc/restic/{password,b2.env}` credential paths already present on
those hosts.

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
5. Open `https://auth.tail1ec6c3.ts.net/setup` in a browser. Pocket-ID's
   setup page is open-until-claimed: the first browser to submit the form
   becomes the admin. Register the first passkey and set the admin email.
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
