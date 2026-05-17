# SSO Phase 2: Immich + Paperless

**Date:** 2026-05-17

## Problem

Phase 1 stood up Pocket-ID on `auth.tail1ec6c3.ts.net` and put Grafana
(`monitor`) and Nextcloud (`nextcloud`) behind it. Two homelab apps still
carry their own login UI and password store:

- **Immich** on `immich` — photo backup, used daily from a phone.
- **Paperless** on `paperless` — document management, also accessed from
  phone (uploads via shortcut).

Both ship with native OIDC support — Immich since v1.91, Paperless since
v2.0 via django-allauth — so wiring them up is a config exercise, not a
plugin one. Doing this now (a) gets the per-app passwords retired, (b)
unifies the phone-side login flow with the desktop one, and (c) closes
out the original SSO charter for everything with first-class OIDC.

Jellyfin, the third app named in the original Phase 2, is **deferred to
Phase 3**. Its OIDC story is plugin-only (`jellyfin-plugin-sso`), the
plugin isn't packaged in nixpkgs, and the failure modes are different
enough that bundling it here would muddy a clean Phase 2 spec.

## Approach

Same shape as Phase 1, applied per app:

1. Create an OIDC client for the app in Pocket-ID's admin UI.
2. Restrict the client to the existing `admin` group (the single-operator
   pattern carried over from Phase 1; `IsGroupRestricted` + an explicit
   allow-list keeps the session-cache logout/login gotcha consistent).
3. Drop a `/etc/<app>-oidc.{env,json}` file on the target host
   (mode `0600`, owned by the service user) carrying the client_id and
   client_secret. Provisioned out-of-band — never committed.
4. Update the host's NixOS module to enable OIDC in the app's settings
   block and reference the secret file via the module's native
   `secretsFile` / `environmentFile` option.

The two apps differ enough in their config surfaces that the per-app
sections below describe each one in detail. The shared bits are the
Pocket-ID client setup and the group restriction.

### Why not bundle Jellyfin

Three concrete reasons:

- **Plugin model.** `jellyfin-plugin-sso` is installed at runtime via
  Jellyfin's plugin manager UI, not declared in Nix. That means the
  config doesn't live in the repo, which breaks the pattern Phase 1 and
  the rest of this fleet rely on.
- **Mapping ambiguity.** Jellyfin's existing user has watch state, a
  PIN, kid-friendly client restrictions, etc. The first OIDC login
  creates a new user; reconciling these isn't free and isn't the same
  problem as Immich/Paperless.
- **Lower urgency.** Jellyfin is consumed via dedicated apps (Android
  TV, Roku, web). The passkey win from SSO is biggest on apps with
  daily browser-side login. Jellyfin's the lowest-value SSO target of
  the three.

Phase 3 will pick this up separately. Skipping it here keeps Phase 2
tight: two apps, one pattern, one spec.

### Why hold the "disable regular login" toggle

Both Immich (`disableLoginForm`) and Paperless
(`PAPERLESS_DISABLE_REGULAR_LOGIN`) can force OIDC-only. **Don't flip
either during Phase 2 rollout.** Keep the password forms reachable for
the first 1–2 weeks. Reasons:

- If Pocket-ID is down, the homelab still needs an admin path into both
  apps. Pocket-ID's own `OnFailure` ntfy alerts are the signal that the
  IdP is sick; locking the apps out adds blast radius for free.
- The mobile flows are the most fragile part — Immich mobile's
  `mobileRedirectUri` shim is the kind of thing that breaks silently on
  app updates. Password fallback lets us notice without losing access.

Once Phase 2 has run clean for 1–2 weeks, flipping both is a one-line
change per app and can land in a separate commit.

### Why map by email, not sub

Both apps will be configured to use `email` as the unique mapping claim
(Immich: `mobileRedirectUri` + `useEmailAsUsername` style behavior;
Paperless: `EMAIL_AUTHENTICATION` via allauth). The reason is that the
existing local accounts (`jeff` on Immich, `admin` on Paperless) already
have an email field set, and email is the only attestable field they
share with the OIDC userinfo response. Using `sub` would require manual
DB updates to attach the OIDC sub to the existing account; using email
lets the first OIDC login attach naturally.

Trade-off: if the email address ever changes in Pocket-ID, the OIDC
identity decouples from the local account. For a single-operator
homelab this is acceptable; rotate-aware identity mapping is a Phase 3+
concern (alongside group-based authorization).

## Scope

### Updated in repo

- `machines/immich/configuration.nix` — add `services.immich.settings.oauth`
  block (with placeholder client_id/secret), `services.immich.secretsFile =
  "/etc/immich-oidc.json"`, and the mobile-redirect shim flags.
- `machines/paperless/configuration.nix` — add
  `services.paperless.settings.PAPERLESS_APPS` plus the openid_connect
  allauth settings, and `services.paperless.environmentFile =
  "/etc/paperless-oidc.env"` for the JSON-blob env var carrying the
  client secret.

### Out-of-repo artifacts

- `/etc/immich-oidc.json` on `immich` (mode `0600 immich:immich`),
  carrying:
  ```json
  {
    "oauth": {
      "clientId": "<IMMICH_CLIENT_ID>",
      "clientSecret": "<IMMICH_CLIENT_SECRET>"
    }
  }
  ```
- `/etc/paperless-oidc.env` on `paperless` (mode `0600 paperless:paperless`),
  carrying:
  ```
  PAPERLESS_SOCIALACCOUNT_PROVIDERS={"openid_connect":{"APPS":[{"provider_id":"pocket-id","name":"Pocket-ID","client_id":"<PAPERLESS_CLIENT_ID>","secret":"<PAPERLESS_CLIENT_SECRET>","settings":{"server_url":"https://auth.tail1ec6c3.ts.net/.well-known/openid-configuration"}}]}}
  ```
  (The entire provider config is one env var because the client_secret
  lives inside it; splitting non-secret fields out and `jq`-merging at
  service start would buy nothing.)

### Per-app callback URLs

Each app needs one callback per origin it's reachable on (tailnet +
public, matching the existing `cloudflared`+`tailscale-cert` topology),
plus — for Immich only — the HTTPS shim URL the mobile app
round-trips through:

| App       | Callback URLs                                                                 |
|-----------|--------------------------------------------------------------------------------|
| Immich    | `https://immich.tail1ec6c3.ts.net/auth/login`<br>`https://immich.youtalklikeafag.com/auth/login`<br>`https://immich.youtalklikeafag.com/api/oauth/mobile-redirect` (mobile shim) |
| Paperless | `https://paperless.tail1ec6c3.ts.net/accounts/oidc/pocket-id/login/callback/`<br>`https://paperless.youtalklikeafag.com/accounts/oidc/pocket-id/login/callback/` |

Immich's browser callback is `/auth/login` — the SPA reads the `?code=`
query param and finishes the exchange. The third URL is the
mobile-redirect shim documented under Components → Immich; Pocket-ID
treats it as a normal HTTPS callback and the Immich server JS-redirects
from there to the custom-scheme deep link.

Paperless follows django-allauth's URL scheme:
`/accounts/oidc/<provider_id>/login/callback/` where `provider_id` is
the literal `pocket-id` string set in
`PAPERLESS_SOCIALACCOUNT_PROVIDERS`.

### Out of scope

- **Jellyfin.** Phase 3.
- **Forcing OIDC-only login.** Deferred 1–2 weeks per app (see above).
- **Role/permission mapping from Pocket-ID claims.** Both apps land the
  first OIDC user with whatever default permissions the app gives.
  Manual promotion via the app's own admin UI (Immich) or `loaddata`
  shell (Paperless) attaches the OIDC identity to the existing admin
  account; no JMESPath role mapping like Grafana needed.
- **`role_attribute_path`-style claims-to-role wiring.** Neither app
  supports this in the Grafana sense. Multi-user authorization will
  show up as a Phase 4+ concern when (if) a second user joins.
- **Auto-launch SSO (skip the login form).** Stays off — same reasoning
  as the disable-regular-login toggle above.

## Components

### Immich on `immich`

Immich's OIDC config has two halves:

1. Non-secret config goes in `services.immich.settings.oauth`:
   ```nix
   services.immich.settings.oauth = {
     enabled = true;
     issuerUrl = "https://auth.tail1ec6c3.ts.net";
     # clientId + clientSecret overlaid from secretsFile
     scope = "openid email profile";
     buttonText = "Login with Pocket-ID";
     autoRegister = true;
     autoLaunch = false;
     mobileOverrideEnabled = true;
     mobileRedirectUri =
       "https://immich.youtalklikeafag.com/api/oauth/mobile-redirect";
   };
   ```

2. Secret values overlaid via `secretsFile`:
   ```nix
   services.immich.secretsFile = "/etc/immich-oidc.json";
   ```

   The module merges this JSON into the resolved settings at service
   start, keeping the secret out of `/nix/store`.

**Why the mobile-redirect shim:** Immich's Android/iOS app uses a custom
URL scheme (`app.immich:///oauth-callback`) for the OIDC callback.
Pocket-ID will not accept a non-HTTPS URL in the client's callback list
(reasonable — custom-scheme deep links are spoofable). Setting
`mobileOverrideEnabled = true` makes the Immich server expose
`/api/oauth/mobile-redirect`, an HTTPS endpoint that the mobile app
configures Pocket-ID to redirect to; the endpoint then issues an
HTML/JS redirect to the deep link. The custom scheme is never seen by
Pocket-ID — only `https://immich.youtalklikeafag.com/...` is.

The Pocket-ID client's callback list must therefore include the
mobile-redirect URL **in addition to** the regular `/auth/login` URLs.

**Existing account reconciliation:** the first OIDC login will trigger
`autoRegister = true` and create a new Immich user with the email from
the userinfo response. If that email matches the existing local
`jeff@…` account, Immich attaches the OIDC identity to it (one of the
upstream code paths). If not, two accounts exist and the second has to
be merged manually via the admin UI. Plan to verify this end-to-end
during bootstrap before declaring the task done.

### Paperless on `paperless`

Paperless-ngx uses django-allauth for social login. The plumbing has
three pieces in `services.paperless.settings`:

```nix
services.paperless.settings = {
  # ... existing settings unchanged ...

  PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";

  # Let the first OIDC login auto-create the local account (allauth
  # otherwise stops at a manual "complete signup" form).
  PAPERLESS_SOCIAL_AUTO_SIGNUP = "True";

  # Match OIDC users to existing local users by email (rather than
  # asking the user to "connect this OIDC account to your existing
  # local account" on first login).
  PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = "none";
  PAPERLESS_ACCOUNT_AUTHENTICATION_METHOD = "username_email";
};

services.paperless.environmentFile = "/etc/paperless-oidc.env";
```

The big env var `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (carrying the client
secret) lives in the env file. Paperless reads it at startup and
django-allauth registers the provider.

**provider_id pinning:** The `provider_id` inside the JSON
(`"pocket-id"`) is the literal slug allauth uses for the URL path —
`/accounts/oidc/pocket-id/login/callback/`. This must match the
Callback URL registered in Pocket-ID exactly. Don't change one without
the other.

**Existing account reconciliation:** same email-based attach pattern as
Immich, courtesy of `PAPERLESS_SOCIAL_AUTO_SIGNUP=True` plus
`PAPERLESS_ACCOUNT_EMAIL_VERIFICATION=none`. If reconciliation fails
during bootstrap, the fix is a Django shell:
```
sudo -u paperless paperless-manage shell -c \
  "from allauth.socialaccount.models import SocialAccount; \
   from django.contrib.auth import get_user_model; \
   u = get_user_model().objects.get(username='admin'); \
   sa = SocialAccount.objects.get(uid='<OIDC_SUB>', provider='openid_connect'); \
   sa.user = u; sa.save()"
```
(Spec-mentioned as a fallback; the auto-flow should make this
unnecessary.)

### Pocket-ID client config (both apps)

For each app, in Pocket-ID admin → Clients → Add Client:

- Name: `Immich` / `Paperless`
- Callback URLs: per table above (Immich gets three entries — two
  regular + one mobile-redirect; Paperless gets two)
- Public Client: **no** (both keep the secret server-side)
- Federated Identity: **no**
- Allowed User Groups: `admin` (existing single-operator group from
  Phase 1)

PKCE is automatic for confidential clients in Pocket-ID v2.x; no toggle.

### Failure handling

Neither service is on the SSO critical path the way Pocket-ID itself is.
But both already have `OnFailure=` hooks on warning topics (Immich:
cloudflared + tailscale-cert; Paperless: none currently). Adding
OIDC-specific failure detection would require a custom probe — the
service can be `active` while OIDC is broken. Skip this in Phase 2;
Gatus's existing `https://{immich,paperless}.tail1ec6c3.ts.net/` probes
catch the gross-failure case.

## Bootstrap

Per app. Order doesn't matter, but Immich is the more battle-tested
OIDC integration and the mobile-redirect shim is the most novel piece —
doing it first surfaces any Pocket-ID quirks before the simpler
Paperless integration.

### Immich

1. Pocket-ID admin UI → Add Client (`Immich`), enter the three callback
   URLs, restrict to `admin` group. Note client_id and client_secret.
2. Create `/etc/immich-oidc.json` on `immich` with the JSON shape above
   (mode `0600 immich:immich`).
3. Update `machines/immich/configuration.nix` with the
   `settings.oauth` block + `secretsFile`. Build + deploy.
4. Browser flow: open `https://immich.youtalklikeafag.com/auth/login`,
   click "Login with Pocket-ID", finish passkey, confirm landing in
   the existing `jeff` library (not a fresh empty account).
5. Mobile flow: open Immich app on phone, "Login with OAuth", confirm
   the deep-link round-trip lands you in the library.

### Paperless

1. Pocket-ID admin UI → Add Client (`Paperless`), enter the two
   callback URLs, restrict to `admin` group. Note client_id and
   client_secret.
2. Create `/etc/paperless-oidc.env` on `paperless` with the JSON-blob
   env var above (mode `0600 paperless:paperless`).
3. Update `machines/paperless/configuration.nix` with the OIDC
   settings + `environmentFile`. Build + deploy.
4. Browser flow: open `https://paperless.youtalklikeafag.com/`,
   click "Login with Pocket-ID" (allauth surfaces the provider as a
   button below the password form), finish passkey, confirm landing
   in the existing `admin` account.

Capture in auto-memory after rollout if anything non-obvious shows up.
The Phase 1 memories (`project_pocket_id_bootstrap.md`,
`project_grafana_oidc_role_mapping.md`) already cover the IdP-side
gotchas; per-app surprises during Phase 2 should get their own files
(`project_immich_oidc_mobile_redirect.md` is the likely one).

## Future considerations (deliberately deferred)

- **Phase 3: Jellyfin via `jellyfin-plugin-sso`.** Separate spec. Will
  need a sidecar-style declarative install or upstream Nix packaging of
  the plugin.
- **Force OIDC-only login on both apps.** Defer 1–2 weeks per app after
  successful bootstrap.
- **Role/permission mapping from Pocket-ID claims.** Out of scope until
  a second user exists.
- **Cleaning up `passwordFile` / `adminpassFile` references in repo.**
  Both Immich's and Paperless's existing bootstrap pages stay valid as
  long as regular login is enabled; revisit when forcing OIDC-only.
