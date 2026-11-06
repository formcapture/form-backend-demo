# Keycloak Checks

[`scripts/check-keycloak.sh`](../scripts/check-keycloak.sh) checks whether a Keycloak realm is set up the way form-backend and PostgREST need it. It is the counterpart of the database check [`scripts/check-db-permissions.sh`](../scripts/check-db-permissions.sh) ([docs](database-permission-checks-native.md)) and uses the same output format, statuses, log file and exit codes.

The script only reads. Against a live Keycloak it sends GET requests to the Admin API and requests one service token, exactly as form-backend does.

---

## 1. What form-backend needs from Keycloak

| Purpose | Keycloak object | form-backend / PostgREST setting |
|---------|-----------------|----------------------------------|
| Service token for PostgREST | **confidential client** with service account (demo: `postgrest-client`) | `POSTGREST_JWT_CLIENT_ID`, `POSTGREST_KEYCLOAK_CLIENT_SECRET` |
| Database role in that token | **client role** on that client, assigned to its service account, named exactly like the DB role (demo: `formbackend`) | PostgREST `jwt-role-claim-key = .resource_access."<client>".roles[0]` |
| Token signature check in PostgREST | realm signing keys (JWKS) | PostgREST `jwt-secret` (`PGRST_JWT_SECRET`) |
| User login in the form app | **public client** with standard flow (demo: `form-backend-app`); keycloak-js runs in the browser | `KC_CLIENT_APP_ID`, `KC_PUBLIC_URL`, `KC_REALM` |
| User permissions | **client roles** of the app client (demo: `fountains_editor`), usually via groups | `access.read` / `access.write` in the form configs |
| User token check in form-backend | realm public key **and** token issuer | `KC_PUBLIC_KEY`, `KC_PUBLIC_URL` (issuer must be `KC_PUBLIC_URL/realms/<realm>`; form-backend ≤ 4.0.0: `KC_AUTH_SERVER_URL`, see section 5) |
| Service token request from form-backend | token endpoint, may be internal | `KC_AUTH_SERVER_URL`, e.g. `http://keycloak:8080/auth` |
| Login inside the Masterportal (embedit iframe) | realm security headers: `frame-ancestors` must allow the portal origin | – |

Both clients need their client roles in the **access token** as `resource_access.<client>.roles`. Keycloak does this with the default client scope `roles` (mapper "client roles").

Names can differ in every installation. Pass them as options (`--realm`, `--app-client`, `--postgrest-client`, `--db-role`); the roles used by the forms are read from `--form-configs`.

---

## 2. Realm file or live system?

| | Realm file (`--realm-file`) | Live system (`--url` + admin credentials) |
|---|---|---|
| Needs | an export of the realm | network access and a read-only admin account |
| Clients, roles, scopes, groups, headers | yes | yes |
| Service account and its roles | yes (direct roles) | yes (effective roles, incl. composites) |
| Users holding roles | only in a full export | yes, incl. group member counts |
| Token issuer vs. form-backend (L01) | only with `--url` | yes |
| Public key, JWKS vs. PostgREST (L02, L03) | only with `--url` | yes |
| Real service token (L04) | only with `--url` and `KC_CLIENT_SECRET` | yes (secret read from Keycloak, never printed) |
| Token of a test user (U01) | no | yes (`--test-user`) |

**Recommendation:** use the live system where possible. It checks the effective configuration, and real tokens, and it catches the issuer and key problems that a file cannot show. Use a realm file when nobody can give you admin access. Combine it with `--url`, because the public checks (L01–L03) need no credentials.

How to get a realm file:
- **Admin console:** Realm settings → Action → Partial export, with "Include groups and roles" and "Include clients". Contains the service account, but no normal users. Secrets are masked.
- **Server:** `kc.sh export --realm <realm> --file realm.json` (full export, includes users). Run it on a stopped or separate instance as described in the Keycloak docs.

The admin account for the live mode needs these `realm-management` client roles in the checked realm: `view-realm`, `view-clients`, `view-users`. With an admin of the `master` realm, use `--admin-realm master` (the default).

---

## 3. Running it

```bash
# live: credentials from the environment, or asked once (password without echo)
export KC_ADMIN_USER=admin
./scripts/check-keycloak.sh --url https://auth.example.org/auth --realm masterportal \
  --form-configs /opt/form-backend/form_configs \
  --postgrest-conf /etc/postgrest/postgrest.conf \
  --public-url https://auth.example.org/auth \
  --public-key "$KC_PUBLIC_KEY" \
  --app-url https://app.example.org/form-backend/app/ \
  --portal-url https://app.example.org/portal/ \
  --test-user some.editor

# realm file, plus the public checks against the running Keycloak
./scripts/check-keycloak.sh --realm-file realm-export.json --url https://auth.example.org/auth \
  --form-configs ./form_configs --postgrest-conf ./postgrest.conf \
  --public-url https://auth.example.org/auth --app-url https://app.example.org/form-backend/app/

# realm file only (offline)
./scripts/check-keycloak.sh --realm-file realm-export.json --form-configs ./form_configs
```

- `--url` is the Keycloak base URL including the context path (`/auth` in the demo).
- `--public-url` and `--public-key` are the values from **form-backend's** environment (`KC_PUBLIC_URL`, `KC_PUBLIC_KEY`). `--public-key @file` reads it from a file. For form-backend ≤ 4.0.0, pass `KC_AUTH_SERVER_URL` as `--public-url`, because those versions check the issuer against it (section 5).
- Instead of a user, the admin login can use a client: `KC_ADMIN_CLIENT_ID` / `KC_ADMIN_CLIENT_SECRET`.
- For the service token without Admin API: `KC_CLIENT_SECRET` (environment only).
- Self-signed certificates: `CURL_CA_BUNDLE=/path/to/ca.pem`.
- Statuses, exit codes (`0` PASS, `1` WARN, `2` FAIL/ERROR, `3` usage/connection) and the log file (`--log`, default `./keycloak-check-<timestamp>.log`) work as in the database script. Secrets and passwords are never written to the console or log.

---

## 4. The checks

### Realm

| ID | Severity | Checks |
|----|----------|--------|
| R01 | FAIL | Realm is enabled |
| R02 | WARN | `Require SSL` is not `none` |
| R03 | WARN | Token signature algorithm is RS256 (what `KC_PUBLIC_KEY` and the PostgREST JWKS are set up for) |
| R04 | FAIL | The login page may be framed by the Masterportal (`--portal-url`): `frame-ancestors` in the realm's Content-Security-Policy, or `X-Frame-Options`. Otherwise the login inside the embedit iframe fails |
| R05 | WARN | The Keycloak status iframe may be framed by the app (`--app-url`), needed by keycloak-js `checkLoginIframe` |

### Service token client (`--postgrest-client`)

| ID | Severity | Checks |
|----|----------|--------|
| C01 | FAIL | Client exists and is enabled |
| C02 | FAIL | Confidential, authenticator "Client Id and Secret" (form-backend sends `client_id` + `client_secret`) |
| C03 | FAIL | Service accounts enabled |
| C04 | FAIL | Client role `--db-role` exists |
| C05 | FAIL | The service account has that role. **Without it there is no error:** the token has no role, and PostgREST silently runs as the anonymous role (reads work, writes fail) |
| C06 | FAIL | The service account has **exactly one** role on the client. PostgREST takes `roles[0]`, and the order is not guaranteed |
| C07 | FAIL | Client roles are written to the access token (`resource_access.<client>.roles`) |
| C08 | FAIL | PostgREST `jwt-role-claim-key` reads the roles of this client (from `--postgrest-conf` or `--role-claim-key`) |
| C09 | WARN | Only the service account holds the DB role: no users, groups or default roles. A user token with this role acts as `formbackend` when sent directly to PostgREST |
| C10 | WARN | No unneeded flows (browser login, password grant) on the service client |

### App client (`--app-client`)

| ID | Severity | Checks |
|----|----------|--------|
| A01 | FAIL | Client exists and is enabled |
| A02 | FAIL | Public client with standard flow (keycloak-js in the browser has no secret) |
| A03 | FAIL | A redirect URI matches the app URL including query parameters (`--app-url`) |
| A04 | FAIL | Web origins allow the app origin (`+` or the origin), otherwise token requests fail with CORS |
| A05 | FAIL | Client roles are written to the access token. Otherwise every user has no roles in form-backend |
| A06 | FAIL | Every role used in `access.read` / `access.write` of the form configs exists as a client role of this client. Realm roles are not read by form-backend |
| A07 | WARN | Every needed role is held by a group or user. Also reports roles that are part of the default roles (then every user has them) |
| A08 | INFO | Which groups (with member counts) and users hold each role |
| A09 | WARN | No password grant (direct access grants) on the public app client |
| F01 | INFO | Forms with `access` `true`: usable without login |

### Live (`--url`)

| ID | Severity | Checks |
|----|----------|--------|
| L01 | FAIL | The token issuer (OIDC discovery) equals `--public-url/realms/<realm>`. form-backend verifies user tokens against exactly this issuer |
| L02 | FAIL | `--public-key` equals the realm's current public key |
| L03 | FAIL | The PostgREST JWKS contains every current signing key of the realm (after a key rotation PostgREST answers `401 PGRST301`) |
| L04 | FAIL | The service token can be requested and carries `resource_access.<client>.roles[0] = <db role>`; also `aud` vs. PostgREST `jwt-aud` and the key id vs. the PostgREST JWKS |
| U01 | INFO/WARN/FAIL | (`--test-user`, Admin API) the user's client roles and, per form, read/write access. FAIL if form-backend would reject the token (issuer) |

---

## 5. Result on the demo setup: the issuer bug

Tested against the demo Keycloak (Keycloak 26.3, live and with realm files) and against realm files with injected faults (every check above reported its fault).

The first run against the dev setup found a real bug in **form-backend ≤ 4.0.0**:

```
FAIL  L01   token issuer matches form-backend KC_AUTH_SERVER_URL
        Keycloak issues:      https://auth.form-backend.local/auth/realms/masterportal
        form-backend expects: http://keycloak:8080/auth/realms/masterportal
```

Since February 2026 (`KC_PUBLIC_URL` was introduced, demo commits `7dfec38`/`50b6cae`), `KC_AUTH_SERVER_URL` points to the internal Keycloak URL. That is right for requesting the service token, but form-backend also used it as the expected **issuer of user tokens**, and Keycloak issues browser tokens with the public URL. The signature was valid, the issuer check failed, and every user ended up without roles: forms with `access: true` worked, role-protected forms answered "Insufficient permissions" even for editors.

The fix (form-backend branch `fix/user-token-issuer`) verifies the issuer against `KC_PUBLIC_URL`. Verified in the demo with a real login token of a user in group `/editors`:

| Request to `/form/fountains` (role `fountains_editor`) | form-backend 4.0.0 / main | with the fix |
|---|---|---|
| user token (public issuer) | 401 Insufficient permissions | **200**, `editable: true` |
| no token | 401 | 401 |
| token with the internal issuer | 401 | 401 |

With the fix, the check passes on the dev setup (25 PASS, 0 FAIL). The remaining findings are hardening warnings: browser login and password grant are enabled on `postgrest-client` (C10), and the password grant on `form-backend-app` (A09).

## 6. Limitations

- In a realm file, role holders are direct assignments only. Composite roles are not expanded, except the default roles.
- In live mode, group member counts are direct members. Members of subgroups also inherit the group's roles but are not counted.
- A03 assumes that keycloak-js redirects to the app URL with query parameters. Redirect URIs with other patterns (regex-like wildcards in the middle) are not evaluated.
- R04/R05 evaluate `frame-ancestors` and `X-Frame-Options` from the realm settings. A reverse proxy that sets its own headers, and browser restrictions on third-party cookies in iframes, are not covered.
