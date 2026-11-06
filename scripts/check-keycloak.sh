#!/usr/bin/env bash
#
# Keycloak checks for form-backend / PostgREST.
#
# Input: a realm export (--realm-file) or a running Keycloak (--url + admin credentials, read-only GET requests).
# With --url, public checks (issuer, public key, JWKS, service token) run in both modes.
# Needs: bash, jq, curl (curl only with --url).
#
# Exit code: 0 = all PASS, 1 = WARN only, 2 = at least one FAIL or ERROR, 3 = usage/connection error.
#
# See debug/keycloak-checks.md for details on every check.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: check-keycloak.sh [options]

Runs on any machine with bash, jq and curl that can reach Keycloak (not inside a container).
All paths below are paths on that machine. Example for the local demo: debug/keycloak-checks.md, section 3.

Source of the realm configuration (one of):
  --realm-file FILE          realm export (kc.sh export, or admin console "Partial export"
                             with groups/roles and clients)
  --url URL                  Keycloak base URL incl. context path, e.g. https://auth.example.org/auth
                             without --realm-file: configuration is read via the Admin API, credentials from
                             KC_ADMIN_USER / KC_ADMIN_PASSWORD (password grant, admin-cli) or
                             KC_ADMIN_CLIENT_ID / KC_ADMIN_CLIENT_SECRET (client credentials); asks once if unset
  --admin-realm R            realm of the admin account (default: master)
  --cacert FILE              CA certificate for Keycloak's TLS certificate, if it is not trusted system-wide
                             (local demo: nginx/certs/rootCA.pem)
  Both --realm-file and --url: configuration from the file, public live checks against the URL.

form-backend / PostgREST settings (names may differ from the demo):
  --realm R                  realm (form-backend KC_REALM); required with --url, optional with a single-realm file
  --app-client ID            client of the form-backend app (KC_CLIENT_APP_ID, default: form-backend-app)
  --postgrest-client ID      client for the service token (POSTGREST_JWT_CLIENT_ID, default: postgrest-client)
  --db-role R                database role in the service token (default: formbackend)
  --form-configs DIR         form-backend form_configs/*.json: roles used in access.read/write
  --postgrest-conf FILE      PostgREST config file (native installations): jwt-role-claim-key, jwt-aud,
                             jwt-secret (JWKS inline or @file). With Docker, PostgREST has no config file:
                             use --role-claim-key and --postgrest-jwks with the PGRST_* values instead
  --postgrest-jwks FILE      JWKS used by PostgREST (PGRST_JWT_SECRET), e.g. <(printf '%s' "$PGRST_JWT_SECRET")
  --role-claim-key KEY       PostgREST jwt-role-claim-key (PGRST_JWT_ROLE_CLAIM_KEY)
  --public-url URL           form-backend KC_PUBLIC_URL (expected issuer of user tokens = URL/realms/<realm>;
                             form-backend <= 4.0.0 checks against KC_AUTH_SERVER_URL instead: pass that value)
  --public-key KEY|@FILE     form-backend KC_PUBLIC_KEY
  --app-url URL              URL of the form-backend app, e.g. https://host/form-backend/app/
  --portal-url URL           URL of the Masterportal that embeds the app in an iframe
  --test-user NAME           (Admin API) show the roles of this user's token and the forms they may use
  --log FILE                 log file (default: ./keycloak-check-<timestamp>.log)
  --help                     show this help

Service token check: KC_CLIENT_SECRET (env) or, with Admin API access, read from Keycloak (never printed).
Certificates from a private CA (e.g. the local demo): --cacert FILE (or CURL_CA_BUNDLE=FILE)
EOF
}

# ---------------------------------------------------------------- arguments
REALM_FILE="" KC_URL="" ADMIN_REALM=master REALM=""
APP_CLIENT=form-backend-app PG_CLIENT=postgrest-client DB_ROLE=formbackend
FORM_CONFIGS="" POSTGREST_CONF="" PGRST_JWKS_FILE="" CLAIM_KEY="" PUBLIC_URL="" PUBLIC_KEY=""
APP_URL="" PORTAL_URL="" TEST_USER=""
LOG_FILE="./keycloak-check-$(date +%Y%m%d-%H%M%S).log"
CA_FILE=""

need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "option $1 needs a value" >&2; exit 3; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --realm-file)        need_arg "$@"; REALM_FILE=$2; shift 2 ;;
    --url)               need_arg "$@"; KC_URL=${2%/}; shift 2 ;;
    --admin-realm)       need_arg "$@"; ADMIN_REALM=$2; shift 2 ;;
    --realm)             need_arg "$@"; REALM=$2; shift 2 ;;
    --app-client)        need_arg "$@"; APP_CLIENT=$2; shift 2 ;;
    --postgrest-client)  need_arg "$@"; PG_CLIENT=$2; shift 2 ;;
    --db-role)           need_arg "$@"; DB_ROLE=$2; shift 2 ;;
    --form-configs)      need_arg "$@"; FORM_CONFIGS=$2; shift 2 ;;
    --postgrest-conf)    need_arg "$@"; POSTGREST_CONF=$2; shift 2 ;;
    --postgrest-jwks)    need_arg "$@"; PGRST_JWKS_FILE=$2; shift 2 ;;
    --role-claim-key)    need_arg "$@"; CLAIM_KEY=$2; shift 2 ;;
    --public-url)        need_arg "$@"; PUBLIC_URL=${2%/}; shift 2 ;;
    --public-key)        need_arg "$@"; PUBLIC_KEY=$2; shift 2 ;;
    --app-url)           need_arg "$@"; APP_URL=$2; shift 2 ;;
    --portal-url)        need_arg "$@"; PORTAL_URL=$2; shift 2 ;;
    --test-user)         need_arg "$@"; TEST_USER=$2; shift 2 ;;
    --log)               need_arg "$@"; LOG_FILE=$2; shift 2 ;;
    --cacert)            need_arg "$@"; CA_FILE=$2; shift 2 ;;
    --help)              usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 3 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 3; }
# CA for the Keycloak certificate: --cacert wins over CURL_CA_BUNDLE; both are checked up front
CURL_TLS=()
CA_FILE=${CA_FILE:-${CURL_CA_BUNDLE:-}}
if [[ -n "$CA_FILE" ]]; then
  [[ -r "$CA_FILE" ]] || { echo "CA file not readable: $CA_FILE (relative paths are resolved from $(pwd))" >&2; exit 3; }
  CA_FILE=$(cd "$(dirname "$CA_FILE")" && pwd)/$(basename "$CA_FILE")
  CURL_TLS=(--cacert "$CA_FILE")
fi
[[ -n "$REALM_FILE" || -n "$KC_URL" ]] || { echo "give --realm-file and/or --url (see --help)" >&2; exit 3; }
[[ -z "$KC_URL" ]] || command -v curl >/dev/null || { echo "--url needs curl" >&2; exit 3; }
[[ -z "$REALM_FILE" || -r "$REALM_FILE" ]] || { echo "cannot read $REALM_FILE" >&2; exit 3; }

: > "$LOG_FILE" || { echo "cannot write log file $LOG_FILE" >&2; exit 3; }
WORK=$(mktemp -d) || exit 3
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- output helpers (as in check-db-permissions.sh)
if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_YEL=$'\e[33m' C_GRN=$'\e[32m' C_DIM=$'\e[2m' C_OFF=$'\e[0m'
else
  C_RED="" C_YEL="" C_GRN="" C_DIM="" C_OFF=""
fi
log()     { printf '%s\n' "$*" | sed $'s/\e\\[[0-9;]*m//g' >> "$LOG_FILE"; }
say()     { printf '%s\n' "$*"; log "$*"; }
declare -A COUNT=([PASS]=0 [FAIL]=0 [WARN]=0 [SKIP]=0 [ERROR]=0 [INFO]=0)

# report ID STATUS TITLE [DETAILS] [HINT]
report() {
  local id=$1 status=$2 title=$3 details=${4:-} hint=${5:-} color
  COUNT[$status]=$(( ${COUNT[$status]} + 1 ))
  case "$status" in
    PASS) color=$C_GRN ;; FAIL|ERROR) color=$C_RED ;; WARN) color=$C_YEL ;; *) color=$C_DIM ;;
  esac
  printf '%s%-5s%s %-5s %s\n' "$color" "$status" "$C_OFF" "$id" "$title"
  log "$(date '+%F %T') $(printf '%-5s %-5s' "$status" "$id") $title"
  if [[ -n "$details" ]]; then
    printf '%s\n' "$details" | sed 's/^/        /'
    printf '%s\n' "$details" | sed 's/^/        /' >> "$LOG_FILE"
  fi
  if [[ -n "$hint" && "$status" != PASS ]]; then
    printf '        %s→ %s%s\n' "$C_DIM" "$hint" "$C_OFF"
    log "        → $hint"
  fi
}

# rows (object<TAB>problem<TAB>fix) → readable lines
format_rows() {
  awk -F'\t' '{ line = $1 ": " $2; if ($3 != "") line = line "\n    fix: " $3; print line }'
}

# ---------------------------------------------------------------- inputs from form-backend / PostgREST
conf_value() {  # PostgREST config: key = "value" (with \" escapes)  /  key = value
  sed -n -E -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*(#.*)?$/\1/p" \
            -e "t" -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^\"#[:space:]]+).*$/\1/p" "$POSTGREST_CONF" \
    | tail -1 | sed 's/\\"/"/g'
}

JWT_AUD="" PGRST_JWKS=""
if [[ -n "$POSTGREST_CONF" ]]; then
  [[ -r "$POSTGREST_CONF" ]] || { echo "cannot read $POSTGREST_CONF" >&2; exit 3; }
  [[ -n "$CLAIM_KEY" ]] || CLAIM_KEY=$(conf_value jwt-role-claim-key)
  JWT_AUD=$(conf_value jwt-aud)
  secret=$(conf_value jwt-secret)
  if [[ "$secret" == @* ]]; then
    [[ -r "${secret#@}" ]] && PGRST_JWKS=$(cat "${secret#@}") || PGRST_JWKS="__unreadable__ ${secret#@}"
  elif [[ -n "$secret" ]]; then
    PGRST_JWKS=$secret
  fi
fi
[[ -n "$PGRST_JWKS_FILE" ]] && PGRST_JWKS=$(cat "$PGRST_JWKS_FILE")

if [[ "$PUBLIC_KEY" == @* ]]; then PUBLIC_KEY=$(cat "${PUBLIC_KEY#@}"); fi
# normalize: no PEM header/footer, no quotes, no whitespace
norm_key() { sed -e 's/-----[A-Z ]*-----//g' | tr -d ' \n\r"'; }
[[ -n "$PUBLIC_KEY" ]] && PUBLIC_KEY=$(printf '%s' "$PUBLIC_KEY" | norm_key)

# roles used in form configs: [{form, mode, role}], forms open to everyone: [{form, mode}]
FORM_ROLES='[]' FORM_PUBLIC='[]'
if [[ -n "$FORM_CONFIGS" ]]; then
  compgen -G "$FORM_CONFIGS/*.json" >/dev/null || { echo "no *.json in $FORM_CONFIGS" >&2; exit 3; }
  FORMS=$(jq -n '[inputs | {form: (input_filename | split("/") | last | rtrimstr(".json")), access: (.access // {})}]' "$FORM_CONFIGS"/*.json) \
    || { echo "cannot parse form configs in $FORM_CONFIGS" >&2; exit 3; }
  FORM_ROLES=$(jq '[.[] | .form as $f | .access | to_entries[] | select(.key == "read" or .key == "write")
                   | .key as $m | (.value | arrays | .[]) | {form: $f, mode: $m, role: .}]' <<< "$FORMS")
  FORM_PUBLIC=$(jq '[.[] | .form as $f | .access | to_entries[] | select((.key == "read" or .key == "write") and .value == true)
                    | {form: $f, mode: .key}]' <<< "$FORMS")
fi

origin_of() { sed -E 's#^(https?://[^/]+).*#\1#' <<< "$1"; }
APP_ORIGIN="" PORTAL_ORIGIN="" KC_ORIGIN=""
[[ -n "$APP_URL" ]] && APP_ORIGIN=$(origin_of "$APP_URL")
[[ -n "$PORTAL_URL" ]] && PORTAL_ORIGIN=$(origin_of "$PORTAL_URL")
[[ -n "$KC_URL" ]] && KC_ORIGIN=$(origin_of "$KC_URL")

decode_jwt() {  # JWT payload as JSON
  local p; p=$(cut -d. -f"${2:-2}" <<< "$1" | tr '_-' '/+'); while (( ${#p} % 4 )); do p+="="; done
  base64 -d <<< "$p" 2>/dev/null
}

# ---------------------------------------------------------------- HTTP helpers
# http METHOD URL [curl args...] → body on stdout; the status code is read with $(status)
# (http runs in a command substitution, so the code goes through a file, not a variable)
http() {
  local method=$1 url=$2 out rc; shift 2
  out=$(curl -sS -m 20 "${CURL_TLS[@]}" -X "$method" -w $'\n%{http_code}' "$@" "$url" 2>&1); rc=$?
  if (( rc != 0 )); then
    echo 000 > "$WORK/status"
    out=${out%$'\n'000}   # write-out of the failed request
    case $rc in
      60) out+=$'\n'"→ the TLS certificate of $(origin_of "$url") is not trusted: pass the CA with --cacert FILE (local demo: --cacert nginx/certs/rootCA.pem)" ;;
      6)  out+=$'\n'"→ host not found: check the URL (and /etc/hosts for the local demo)" ;;
      7)  out+=$'\n'"→ connection refused: is Keycloak running and reachable from this machine?" ;;
    esac
    printf '%s' "$out"; return 1
  fi
  printf '%s' "${out##*$'\n'}" > "$WORK/status"
  printf '%s' "${out%$'\n'*}"
}
status() { cat "$WORK/status" 2>/dev/null || echo 000; }

ADMIN_TOKEN=""
admin_login() {
  local body
  if [[ -n "${KC_ADMIN_CLIENT_ID:-}" && -n "${KC_ADMIN_CLIENT_SECRET:-}" ]]; then
    body=$(http POST "$KC_URL/realms/$ADMIN_REALM/protocol/openid-connect/token" --data-urlencode "client_id=$KC_ADMIN_CLIENT_ID" \
           --data-urlencode "client_secret=$KC_ADMIN_CLIENT_SECRET" -d grant_type=client_credentials)
  else
    if [[ -z "${KC_ADMIN_USER:-}" || -z "${KC_ADMIN_PASSWORD:-}" ]]; then
      [[ -t 0 ]] || { say "${C_RED}no admin credentials:${C_OFF} set KC_ADMIN_USER/KC_ADMIN_PASSWORD or KC_ADMIN_CLIENT_ID/KC_ADMIN_CLIENT_SECRET, or use --realm-file"; exit 3; }
      [[ -n "${KC_ADMIN_USER:-}" ]] || read -rp "Keycloak admin user (realm $ADMIN_REALM): " KC_ADMIN_USER
      read -rsp "Password for $KC_ADMIN_USER: " KC_ADMIN_PASSWORD; echo
      log "admin password: entered interactively (not logged)"
    fi
    body=$(http POST "$KC_URL/realms/$ADMIN_REALM/protocol/openid-connect/token" -d client_id=admin-cli -d grant_type=password \
           --data-urlencode "username=$KC_ADMIN_USER" --data-urlencode "password=$KC_ADMIN_PASSWORD")
  fi
  ADMIN_TOKEN=$(jq -r '.access_token // empty' <<< "$body" 2>/dev/null)
  if [[ -z "$ADMIN_TOKEN" ]]; then
    # HTTP 000 = curl error (TLS, DNS, connection): show the full message incl. the hint
    if [[ "$(status)" == 000 ]]; then
      say "${C_RED}admin login failed:${C_OFF} $body"
    else
      say "${C_RED}admin login failed (HTTP $(status)):${C_OFF} $(jq -r '.error_description // .error // empty' <<< "$body" 2>/dev/null || head -c 200 <<< "$body")"
    fi
    exit 3
  fi
}

# Admin API GET; aborts on errors (the model would be incomplete)
aget() {
  local body
  body=$(http GET "$KC_URL/admin/realms/$REALM$1" -H "Authorization: Bearer $ADMIN_TOKEN")
  if [[ "$(status)" != 2* ]]; then
    # stdout of aget is usually redirected: report on stderr and in the log
    say "${C_RED}Admin API GET $1 failed (HTTP $(status)):${C_OFF} $(head -c 300 <<< "$body")" >&2
    [[ "$(status)" == 403 ]] && say "the admin account needs the realm-management roles view-realm, view-clients and view-users" >&2
    exit 3
  fi
  printf '%s' "$body"
}
uri() { jq -rn --arg v "$1" '$v | @uri'; }

# ---------------------------------------------------------------- build the model
say "form-backend Keycloak check – $(date '+%F %T')"
say "log file: $LOG_FILE"
MODEL=$WORK/model.json

if [[ -n "$REALM_FILE" ]]; then
  # a file can hold one realm, an array of realms, or {"realms": [...]}
  if ! jq -e --arg r "$REALM" '
      (if type == "array" then . elif has("realms") then .realms else [.] end) as $all
      | ($all | map(select($r == "" or .realm == $r))) as $m
      | if ($m | length) == 1 then $m[0] else error("realm not found or ambiguous") end' "$REALM_FILE" > "$WORK/realm.json" 2> "$WORK/err"; then
    say "${C_RED}cannot read realm from $REALM_FILE:${C_OFF} $(cat "$WORK/err")"; exit 3
  fi
  [[ -n "$REALM" ]] || REALM=$(jq -r .realm "$WORK/realm.json")
  jq --arg app "$APP_CLIENT" --arg pg "$PG_CLIENT" --arg dbrole "$DB_ROLE" '
    def flat: .[]? | ({path, clientRoles: (.clientRoles // {})}, (.subGroups | flat));
    . as $r
    | ($r.defaultRole.name // ("default-roles-" + ($r.realm | ascii_downcase))) as $dr
    | [($r.groups // []) | flat] as $groups
    | [($r.users // [])[] | select(.serviceAccountClientId == null)] as $users
    | ($users | length > 0) as $usersIncluded
    | def holders($cid; $role):
        { groups: [$groups[] | select((.clientRoles[$cid] // []) | index($role)) | .path],
          users:  [$users[] | select((.clientRoles[$cid] // []) | index($role)) | .username],
          members: (if $usersIncluded then
                      [$groups[] | select((.clientRoles[$cid] // []) | index($role)) | .path as $p
                       | {key: $p, value: ([$users[] | select(any(.groups[]?; . == $p or startswith($p + "/")))] | length)}]
                      | from_entries
                    else null end) };
    {
      source: "realm file",
      realm: { name: $r.realm, enabled: ($r.enabled // true), sslRequired: $r.sslRequired,
               accessTokenLifespan: $r.accessTokenLifespan, defaultSignatureAlgorithm: ($r.defaultSignatureAlgorithm // "RS256"),
               frontendUrl: ($r.attributes.frontendUrl // null),
               csp: ($r.browserSecurityHeaders.contentSecurityPolicy // null),
               xfo: ($r.browserSecurityHeaders.xFrameOptions // null) },
      clients: ($r.clients // []),
      clientScopes: ($r.clientScopes // []),
      clientRoles: ($r.roles.client // {} | with_entries(.value |= [.[] | {name, composite: (.composite // false)}])),
      defaultRoleComposites: (first($r.roles.realm[]? | select(.name == $dr) | .composites.client) // {}),
      appRoleHolders: ([(($r.roles.client[$app] // [])[] | .name) as $n | {key: $n, value: holders($app; $n)}] | from_entries),
      pgRoleHolders: holders($pg; $dbrole),
      usersIncluded: $usersIncluded,
      serviceAccount: (first($r.users[]? | select(.serviceAccountClientId == $pg))
                       | {found: true, roles: (.clientRoles[$pg] // [])}) // (if $r | has("users") then {found: false, roles: []} else null end)
    }' "$WORK/realm.json" > "$MODEL" || { say "${C_RED}cannot build model from $REALM_FILE${C_OFF}"; exit 3; }
  say "source: realm file $REALM_FILE (realm $REALM)"
else
  [[ -n "$REALM" ]] || { echo "--url without --realm-file needs --realm" >&2; exit 3; }
  admin_login
  say "source: Admin API $KC_URL (realm $REALM, admin realm $ADMIN_REALM)"
  aget "" > "$WORK/realm.json"
  aget "/clients?max=10000" > "$WORK/clients.json"
  aget "/client-scopes" > "$WORK/scopes.json"
  uuid_of() { jq -r --arg c "$1" 'first(.[] | select(.clientId == $c) | .id) // empty' "$WORK/clients.json"; }
  APP_UUID=$(uuid_of "$APP_CLIENT"); PG_UUID=$(uuid_of "$PG_CLIENT")
  DR=$(jq -r '.defaultRole.name // empty' "$WORK/realm.json")
  echo '{}' > "$WORK/croles.json"; echo '{}' > "$WORK/defcomp.json"; echo '{}' > "$WORK/appholders.json"
  echo '{"groups":[],"users":[],"members":{}}' > "$WORK/pgholders.json"; echo 'null' > "$WORK/sa.json"
  SA_ID=""
  if [[ -n "$PG_UUID" ]] && [[ $(jq -r --arg c "$PG_CLIENT" 'first(.[] | select(.clientId == $c)) | .serviceAccountsEnabled' "$WORK/clients.json") == true ]]; then
    SA=$(aget "/clients/$PG_UUID/service-account-user"); SA_ID=$(jq -r .id <<< "$SA")
    aget "/users/$SA_ID/role-mappings/clients/$PG_UUID/composite" | jq '{found: true, roles: [.[].name]}' > "$WORK/sa.json"
  elif [[ -n "$PG_UUID" ]]; then
    echo '{"found": false, "roles": []}' > "$WORK/sa.json"
  fi
  holders() {  # holders CLIENT_UUID ROLE → {groups, users, members}
    local g u members='{}' gid path n
    g=$(aget "/clients/$1/roles/$(uri "$2")/groups?max=10000")
    u=$(aget "/clients/$1/roles/$(uri "$2")/users?max=10000")
    while IFS=$'\t' read -r gid path; do
      [[ -n "$gid" ]] || continue
      n=$(aget "/groups/$gid/members?max=10000&briefRepresentation=true" | jq length)
      members=$(jq --arg p "$path" --argjson n "$n" '. + {($p): $n}' <<< "$members")
    done < <(jq -r '.[] | [.id, .path] | @tsv' <<< "$g")
    jq -n --argjson g "$g" --argjson u "$u" --argjson m "$members" --arg sa "$SA_ID" \
      '{groups: [$g[].path], users: [$u[] | select(.id != $sa) | .username], members: $m}'
  }
  for pair in "$APP_CLIENT:$APP_UUID" "$PG_CLIENT:$PG_UUID"; do
    cid=${pair%%:*}; cu=${pair#*:}; [[ -n "$cu" ]] || continue
    roles=$(aget "/clients/$cu/roles?briefRepresentation=false")
    jq --arg c "$cid" --argjson r "$roles" '. + {($c): [$r[] | {name, composite}]}' "$WORK/croles.json" > "$WORK/t" && mv "$WORK/t" "$WORK/croles.json"
    if [[ -n "$DR" ]]; then
      dc=$(aget "/roles/$(uri "$DR")/composites/clients/$cu")
      jq --arg c "$cid" --argjson d "$dc" '. + {($c): [$d[].name]}' "$WORK/defcomp.json" > "$WORK/t" && mv "$WORK/t" "$WORK/defcomp.json"
    fi
  done
  if [[ -n "$APP_UUID" ]]; then
    while read -r role; do
      [[ -n "$role" ]] || continue
      h=$(holders "$APP_UUID" "$role")
      jq --arg r "$role" --argjson h "$h" '. + {($r): $h}' "$WORK/appholders.json" > "$WORK/t" && mv "$WORK/t" "$WORK/appholders.json"
    done < <(jq -r --arg c "$APP_CLIENT" '.[$c][]?.name' "$WORK/croles.json")
  fi
  if [[ -n "$PG_UUID" ]] && jq -e --arg c "$PG_CLIENT" --arg r "$DB_ROLE" 'any(.[$c][]?; .name == $r)' "$WORK/croles.json" >/dev/null; then
    holders "$PG_UUID" "$DB_ROLE" > "$WORK/pgholders.json"
  fi
  jq -n --slurpfile r "$WORK/realm.json" --slurpfile c "$WORK/clients.json" --slurpfile s "$WORK/scopes.json" \
        --slurpfile cr "$WORK/croles.json" --slurpfile dc "$WORK/defcomp.json" --slurpfile ah "$WORK/appholders.json" \
        --slurpfile ph "$WORK/pgholders.json" --slurpfile sa "$WORK/sa.json" '
    $r[0] as $r |
    { source: "Admin API",
      realm: { name: $r.realm, enabled: $r.enabled, sslRequired: $r.sslRequired, accessTokenLifespan: $r.accessTokenLifespan,
               defaultSignatureAlgorithm: ($r.defaultSignatureAlgorithm // "RS256"), frontendUrl: ($r.attributes.frontendUrl // null),
               csp: ($r.browserSecurityHeaders.contentSecurityPolicy // null), xfo: ($r.browserSecurityHeaders.xFrameOptions // null) },
      clients: $c[0], clientScopes: $s[0], clientRoles: $cr[0], defaultRoleComposites: $dc[0],
      appRoleHolders: $ah[0], pgRoleHolders: $ph[0], usersIncluded: true, serviceAccount: $sa[0] }' > "$MODEL"
fi

say "clients: app=$APP_CLIENT postgrest=$PG_CLIENT | db role: $DB_ROLE"
[[ -n "$FORM_CONFIGS" ]] && say "roles used in form configs: $(jq -r '[.[].role] | unique | join(", ")' <<< "$FORM_ROLES")"
say ""

# ---------------------------------------------------------------- checks on the model
# check ID SEVERITY TITLE HINT <<JQ   – the jq filter prints rows (object, problem, fix) as TSV; no rows = PASS
JQ_DEFS='
def client($id): first(.clients[] | select(.clientId == $id)) // null;
def role_mapper($cid):
  .protocolMapper == "oidc-usermodel-client-role-mapper"
  and ((.config["access.token.claim"] // "true") == "true")
  and ((.config["usermodel.clientRoleMapping.clientId"] // "") as $m | $m == "" or $m == $cid)
  and (((.config["claim.name"] // "") | gsub("\\$\\{client_id\\}"; $cid)) == ("resource_access." + $cid + ".roles"));
def roles_in_token($cid; $clientdef; $scopes):
  any($clientdef.protocolMappers[]?; role_mapper($cid))
  or any(($clientdef.defaultClientScopes // [])[]; . as $s | any($scopes[]? | select(.name == $s) | .protocolMappers[]?; role_mapper($cid)));
def redirect_match($cand; $root):
  (if startswith("/") then ($root // "") + . else . end) as $u
  | if $u == "*" then true elif ($u | endswith("*")) then ($cand | startswith($u | rtrimstr("*"))) else $u == $cand end;
def frame_allowed($o):
  ((.realm.csp // "") | [splits(";\\s*")] | map(select(startswith("frame-ancestors"))) | first) as $fa
  | if $fa != null then
      ($fa | split(" ") | map(select(. != "")) | .[1:]) as $t
      | ($t | index("*") != null) or ($t | index($o) != null) or (($t | index("'"'"'self'"'"'") != null) and $o == $kcorigin)
    else
      ((.realm.xfo // "") | ascii_upcase) as $x | $x == "" or ($x == "SAMEORIGIN" and $o == $kcorigin)
    end;
'
check() {
  local id=$1 severity=$2 title=$3 hint=$4 filter out rc
  filter=$(cat)
  out=$(jq -r --arg app "$APP_CLIENT" --arg pg "$PG_CLIENT" --arg dbrole "$DB_ROLE" --arg claimkey "$CLAIM_KEY" \
          --arg appurl "$APP_URL" --arg apporigin "$APP_ORIGIN" --arg portalorigin "$PORTAL_ORIGIN" --arg kcorigin "$KC_ORIGIN" \
          --argjson formroles "$FORM_ROLES" --argjson formpublic "$FORM_PUBLIC" \
          "$JQ_DEFS $filter" "$MODEL" 2>&1); rc=$?
  if (( rc != 0 )); then
    report "$id" ERROR "$title" "check could not run: $out"
  elif [[ -z "$out" ]]; then
    report "$id" PASS "$title"
  else
    report "$id" "$severity" "$title" "$(printf '%s\n' "$out" | format_rows)" "$hint"
  fi
}

# --- realm
check R01 FAIL "realm $REALM is enabled" "enable the realm" <<'JQ'
if .realm.enabled == false then [.realm.name, "realm is disabled", ""] | @tsv else empty end
JQ

check R02 WARN "realm requires SSL" "Realm settings → General → Require SSL" <<'JQ'
if (.realm.sslRequired // "external") == "none" then [.realm.name, "sslRequired = none: tokens and passwords may travel over plain HTTP", ""] | @tsv else empty end
JQ

check R03 WARN "token signature algorithm RS256" "form-backend (KC_PUBLIC_KEY) and PostgREST (JWKS) must support the realm's algorithm" <<'JQ'
if .realm.defaultSignatureAlgorithm != "RS256" then [.realm.name, "defaultSignatureAlgorithm = " + .realm.defaultSignatureAlgorithm, ""] | @tsv else empty end
JQ

if [[ -n "$PORTAL_ORIGIN" ]]; then
check R04 FAIL "login page may be framed by the Masterportal ($PORTAL_ORIGIN)" "Realm settings → Security defenses → Content-Security-Policy: add the origin to frame-ancestors" <<'JQ'
if frame_allowed($portalorigin) | not then
  [$portalorigin, "blocked by CSP " + ((.realm.csp // "-") | tostring) + " / X-Frame-Options " + ((.realm.xfo // "-") | tostring) + ": the login in the embedit iframe fails", ""] | @tsv
else empty end
JQ
fi
if [[ -n "$APP_ORIGIN" ]]; then
check R05 WARN "Keycloak status iframe may be framed by the app ($APP_ORIGIN)" "keycloak-js checkLoginIframe needs frame-ancestors to include the app origin" <<'JQ'
if frame_allowed($apporigin) | not then
  [$apporigin, "blocked by CSP " + ((.realm.csp // "-") | tostring) + " / X-Frame-Options " + ((.realm.xfo // "-") | tostring), ""] | @tsv
else empty end
JQ
fi
if [[ -z "$PORTAL_ORIGIN$APP_ORIGIN" ]]; then
  report R04 INFO "frame headers (give --portal-url / --app-url to check)" \
    "CSP: $(jq -r '.realm.csp // "-"' "$MODEL") | X-Frame-Options: $(jq -r '.realm.xfo // "-"' "$MODEL")"
fi

# --- postgrest client (service token)
check C01 FAIL "client $PG_CLIENT exists and is enabled" "create the client or pass --postgrest-client (form-backend POSTGREST_JWT_CLIENT_ID)" <<'JQ'
client($pg) as $c
| if $c == null then [$pg, "client does not exist", ""] | @tsv
  elif $c.enabled == false then [$pg, "client is disabled", ""] | @tsv else empty end
JQ

check C02 FAIL "$PG_CLIENT is confidential with client secret" "Client authentication ON, Authenticator: Client Id and Secret" <<'JQ'
client($pg) as $c | select($c != null)
| if $c.publicClient == true then [$pg, "public client: no secret, no service account", ""] | @tsv
  elif $c.bearerOnly == true then [$pg, "bearer-only: cannot request tokens", ""] | @tsv
  elif ($c.clientAuthenticatorType // "client-secret") != "client-secret" then
    [$pg, "authenticator " + $c.clientAuthenticatorType + ": form-backend sends client_id + client_secret", ""] | @tsv
  else empty end
JQ

check C03 FAIL "$PG_CLIENT has service accounts enabled" "Client → Capability config → Service accounts roles ON" <<'JQ'
client($pg) as $c | select($c != null) | if $c.serviceAccountsEnabled != true then [$pg, "serviceAccountsEnabled is off: client_credentials grant fails", ""] | @tsv else empty end
JQ

check C04 FAIL "client role $DB_ROLE exists on $PG_CLIENT" "Client → Roles → Create role (the name must equal the database role)" <<'JQ'
select(client($pg) != null)
| if any(.clientRoles[$pg][]?; .name == $dbrole) | not then
    [$pg, "no client role " + $dbrole + " (existing: " + ([.clientRoles[$pg][]?.name] | join(", ") | if . == "" then "-" else . end) + ")", ""] | @tsv
  else empty end
JQ

if [[ $(jq -r '.serviceAccount == null' "$MODEL") == true ]]; then
  report C05 SKIP "service account of $PG_CLIENT has role $DB_ROLE" "the realm file contains no users: export with clients included, or use the Admin API"
else
check C05 FAIL "service account of $PG_CLIENT has role $DB_ROLE" "Client → Service account roles → Assign role → client $PG_CLIENT → $DB_ROLE; without it PostgREST silently uses the anonymous role" <<'JQ'
select(client($pg) != null)
| if client($pg).serviceAccountsEnabled != true then [$pg, "no service account: service accounts are disabled (C03)", ""] | @tsv
  elif .serviceAccount.found != true then ["service-account-" + $pg, "service account user not found", ""] | @tsv
  elif (.serviceAccount.roles | index($dbrole)) == null then
    ["service-account-" + $pg, "has client roles [" + (.serviceAccount.roles | join(", ")) + "], not " + $dbrole, ""] | @tsv
  else empty end
JQ

check C06 FAIL "service account has exactly one role on $PG_CLIENT" "PostgREST takes roles[0]; with several roles the order is not guaranteed – remove the others" <<'JQ'
if (.serviceAccount.roles | length) > 1 then ["service-account-" + $pg, "roles [" + (.serviceAccount.roles | join(", ")) + "]: roles[0] may be any of them", ""] | @tsv else empty end
JQ
fi

check C07 FAIL "client roles of $PG_CLIENT reach the access token" "add the default client scope \"roles\" (mapper \"client roles\", Add to access token ON) or a client role mapper on the client" <<'JQ'
client($pg) as $c | select($c != null)
| if roles_in_token($pg; $c; .clientScopes) | not then [$pg, "no client role mapper writes resource_access." + $pg + ".roles into the access token", ""] | @tsv else empty end
JQ

if [[ -n "$CLAIM_KEY" ]]; then
check C08 FAIL "PostgREST jwt-role-claim-key points to $PG_CLIENT" "jwt-role-claim-key must be .resource_access.\"<postgrest client>\".roles[0]" <<'JQ'
($claimkey | capture("^\\.resource_access\\.\"?(?<c>[^\".]+)\"?\\.roles\\[0\\]$")?.c) as $c
| if $c == null then [$claimkey, "not of the form .resource_access.\"<client>\".roles[0]: make sure a mapper writes this claim", ""] | @tsv
  elif $c != $pg then [$claimkey, "reads roles of client " + $c + ", but form-backend uses " + $pg, ""] | @tsv
  else empty end
JQ
else
  report C08 SKIP "PostgREST jwt-role-claim-key points to $PG_CLIENT" "give --postgrest-conf or --role-claim-key"
fi

check C09 WARN "$DB_ROLE is held only by the service account" "user tokens with this role act as $DB_ROLE when sent directly to PostgREST" <<'JQ'
( (.pgRoleHolders.groups[]? | [., "group has " + $pg + "/" + $dbrole, ""] | @tsv),
  (.pgRoleHolders.users[]? | [., "user has " + $pg + "/" + $dbrole, ""] | @tsv),
  (if ((.defaultRoleComposites[$pg] // []) | index($dbrole)) != null then ["default roles", "every user gets " + $pg + "/" + $dbrole, ""] | @tsv else empty end) )
JQ

check C10 WARN "$PG_CLIENT has no unneeded login flows" "only the service account (client_credentials) is needed" <<'JQ'
client($pg) as $c | select($c != null)
| ( (if $c.standardFlowEnabled == true then [$pg, "standard flow (browser login) enabled", ""] | @tsv else empty end),
    (if $c.directAccessGrantsEnabled == true then [$pg, "direct access grants (password grant) enabled", ""] | @tsv else empty end),
    (if $c.implicitFlowEnabled == true then [$pg, "implicit flow enabled", ""] | @tsv else empty end) )
JQ

# --- app client (user login)
check A01 FAIL "client $APP_CLIENT exists and is enabled" "create the client or pass --app-client (form-backend KC_CLIENT_APP_ID)" <<'JQ'
client($app) as $c
| if $c == null then [$app, "client does not exist", ""] | @tsv
  elif $c.enabled == false then [$app, "client is disabled", ""] | @tsv else empty end
JQ

check A02 FAIL "$APP_CLIENT is a public client with standard flow" "the app logs in from the browser (keycloak-js): Client authentication OFF, Standard flow ON" <<'JQ'
client($app) as $c | select($c != null)
| ( (if $c.publicClient != true then [$app, "confidential client: the browser has no secret, the code exchange fails", ""] | @tsv else empty end),
    (if $c.bearerOnly == true then [$app, "bearer-only: no login possible", ""] | @tsv else empty end),
    (if $c.standardFlowEnabled == false then [$app, "standard flow disabled: no browser login", ""] | @tsv else empty end) )
JQ

if [[ -n "$APP_URL" ]]; then
check A03 FAIL "redirect URIs of $APP_CLIENT allow $APP_URL" "Client → Valid redirect URIs: add ${APP_URL%/}/*" <<'JQ'
client($app) as $c | select($c != null)
| ($appurl + (if ($appurl | test("\\?")) then "&" else "?" end) + "formId=x&view=table") as $cand
| ( (if any($c.redirectUris[]?; redirect_match($cand; $c.rootUrl)) | not then
       [$app, "no redirect URI matches " + $cand + " (configured: " + ($c.redirectUris | join(", ")) + ")", ""] | @tsv else empty end),
    (if any($c.redirectUris[]?; . == "*") then [$app, "redirect URI \"*\" allows any target", ""] | @tsv else empty end) )
JQ

check A04 FAIL "web origins of $APP_CLIENT allow $APP_ORIGIN (CORS)" "Client → Web origins: \"+\" or the app origin" <<'JQ'
client($app) as $c | select($c != null)
| ($c.webOrigins // []) as $w
| if ($w | index("*")) != null then [$app, "web origin \"*\" allows every site", ""] | @tsv
  elif ($w | index($apporigin)) != null then empty
  elif ($w | index("+")) != null and any($c.redirectUris[]?; (if startswith("/") then ($c.rootUrl // "") + . else . end) | startswith($apporigin)) then empty
  else [$app, "neither \"+\" (with a redirect URI on " + $apporigin + ") nor " + $apporigin + " in web origins [" + ($w | join(", ")) + "]: token requests fail with CORS", ""] | @tsv end
JQ
else
  report A03 SKIP "redirect URIs / web origins of $APP_CLIENT" "give --app-url"
fi

check A05 FAIL "client roles of $APP_CLIENT reach the access token" "form-backend reads resource_access.$APP_CLIENT.roles – add the default client scope \"roles\" or a client role mapper" <<'JQ'
client($app) as $c | select($c != null)
| if roles_in_token($app; $c; .clientScopes) | not then [$app, "no client role mapper writes resource_access." + $app + ".roles into the access token: every user has no roles", ""] | @tsv else empty end
JQ

if [[ -n "$FORM_CONFIGS" ]]; then
check A06 FAIL "roles used in form configs exist on $APP_CLIENT" "Client $APP_CLIENT → Roles → Create role (names are case-sensitive; realm roles are not read)" <<'JQ'
select(client($app) != null)
| [.clientRoles[$app][]?.name] as $have
| $formroles | group_by(.role)[] | .[0].role as $r | select(($have | index($r)) == null)
| [.[0].role, "missing; used by " + ([.[] | .form + " (" + .mode + ")"] | join(", ")), ""] | @tsv
JQ
fi

check A07 WARN "roles of $APP_CLIENT are assigned to someone" "assign the role to a group (Groups → Role mapping) or user" <<'JQ'
select(client($app) != null)
| (if ($formroles | length) > 0 then [$formroles[].role] | unique else [.clientRoles[$app][]?.name] end) as $needed
| . as $m
| $needed[] as $r
| select(any($m.clientRoles[$app][]?; .name == $r))
| ($m.appRoleHolders[$r] // {groups: [], users: [], members: null}) as $h
| ((($m.defaultRoleComposites[$app] // []) | index($r)) != null) as $default
| if $default then [$r, "part of the default roles: every user of the realm has it", ""] | @tsv
  elif ($h.groups | length) == 0 and ($h.users | length) == 0 then
    [$r, "no group or user has this role" + (if $m.usersIncluded then "" else " (realm file without users: only groups checked)" end), ""] | @tsv
  elif $h.members != null and ($h.users | length) == 0 and ([$h.members[]] | add // 0) == 0 then
    [$r, "only in groups without members: " + ($h.groups | join(", ")), ""] | @tsv
  else empty end
JQ

check A08 INFO "who holds the roles of $APP_CLIENT" "" <<'JQ'
.appRoleHolders | to_entries[]
| [.key, "groups: " + ([.value.groups[] as $g | $g + (if .value.members != null then " (" + ((.value.members[$g] // "?") | tostring) + " members)" else "" end)] | join(", ") | if . == "" then "-" else . end)
         + " | users: " + (.value.users | join(", ") | if . == "" then "-" else . end), ""] | @tsv
JQ

check A09 WARN "$APP_CLIENT does not allow the password grant" "Direct access grants are not needed by the app" <<'JQ'
client($app) as $c | select($c != null and $c.publicClient == true and $c.directAccessGrantsEnabled == true)
| [$app, "direct access grants on a public client: anyone can try passwords without the login page", ""] | @tsv
JQ

if [[ -n "$FORM_CONFIGS" ]]; then
check F01 INFO "forms open to everyone (access true, incl. anonymous users)" "" <<'JQ'
$formpublic | group_by(.form)[] | [.[0].form, ([.[].mode] | join(" + ")) + " allowed without login", ""] | @tsv
JQ
fi

# ---------------------------------------------------------------- live checks (public endpoints)
if [[ -n "$KC_URL" ]]; then
  REALM_URL="$KC_URL/realms/$REALM"
  disc=$(http GET "$REALM_URL/.well-known/openid-configuration")
  ISSUER=$(jq -r '.issuer // empty' <<< "$disc" 2>/dev/null)
  if [[ -z "$ISSUER" ]]; then
    report L01 ERROR "OIDC discovery $REALM_URL" "HTTP $(status): $(head -c 200 <<< "$disc")"
  elif [[ -n "$PUBLIC_URL" ]]; then
    expected="$PUBLIC_URL/realms/$REALM"
    if [[ "$ISSUER" == "$expected" ]]; then
      report L01 PASS "token issuer matches form-backend KC_PUBLIC_URL ($ISSUER)"
    else
      report L01 FAIL "token issuer matches form-backend KC_PUBLIC_URL" \
        "Keycloak issues:      $ISSUER"$'\n'"form-backend expects: $expected" \
        "form-backend rejects every user token (no roles → 'Insufficient permissions'); set KC_PUBLIC_URL to ${ISSUER%/realms/*} or fix the Keycloak hostname (KC_HOSTNAME)"
    fi
  else
    report L01 INFO "token issuer" "$ISSUER – form-backend's KC_PUBLIC_URL + /realms/$REALM must equal it exactly (give --public-url to check)"
  fi

  realm_pub=$(http GET "$REALM_URL" | jq -r '.public_key // empty' 2>/dev/null)
  if [[ -z "$PUBLIC_KEY" ]]; then
    report L02 SKIP "form-backend KC_PUBLIC_KEY matches the realm key" "give --public-key"
  elif [[ -z "$realm_pub" ]]; then
    report L02 ERROR "form-backend KC_PUBLIC_KEY matches the realm key" "cannot read public_key from $REALM_URL (HTTP $(status))"
  elif [[ "$realm_pub" == "$PUBLIC_KEY" ]]; then
    report L02 PASS "form-backend KC_PUBLIC_KEY matches the realm key"
  else
    fp() { printf '%s' "$1" | sha256sum | cut -c1-16; }
    report L02 FAIL "form-backend KC_PUBLIC_KEY matches the realm key" "sha256 realm key: $(fp "$realm_pub")  given key: $(fp "$PUBLIC_KEY")" \
      "update KC_PUBLIC_KEY with public_key from $REALM_URL (keys rotated or wrong realm)"
  fi

  JWKS=$(http GET "$REALM_URL/protocol/openid-connect/certs")
  SIG_KIDS=$(jq -r '[.keys[]? | select(.use == "sig") | .kid] | join(" ")' <<< "$JWKS" 2>/dev/null)
  if [[ -z "$PGRST_JWKS" ]]; then
    report L03 SKIP "PostgREST JWKS contains the realm signing keys" "give --postgrest-conf (jwt-secret) or --postgrest-jwks"
  elif [[ "$PGRST_JWKS" == __unreadable__* ]]; then
    report L03 ERROR "PostgREST JWKS contains the realm signing keys" "cannot read ${PGRST_JWKS#__unreadable__ }"
  elif ! jq -e '.keys' <<< "$PGRST_JWKS" >/dev/null 2>&1; then
    report L03 FAIL "PostgREST JWKS contains the realm signing keys" "jwt-secret is not a JWKS (plain secret?)" \
      "set jwt-secret to the content of $REALM_URL/protocol/openid-connect/certs"
  else
    missing=$(for k in $SIG_KIDS; do jq -e --arg k "$k" 'any(.keys[]; .kid == $k)' <<< "$PGRST_JWKS" >/dev/null || echo "$k"; done | paste -sd' ' -)
    if [[ -z "$missing" ]]; then
      report L03 PASS "PostgREST JWKS contains the realm signing keys"
    else
      report L03 FAIL "PostgREST JWKS contains the realm signing keys" "missing kid(s): $missing" \
        "PostgREST rejects tokens signed with them (401 PGRST301): update jwt-secret from $REALM_URL/protocol/openid-connect/certs and restart PostgREST"
    fi
  fi

  # service token, exactly as form-backend requests it
  secret_src="KC_CLIENT_SECRET"
  PG_SECRET=${KC_CLIENT_SECRET:-}
  if [[ -z "$PG_SECRET" && -n "$ADMIN_TOKEN" && -n "${PG_UUID:-}" ]]; then
    PG_SECRET=$(aget "/clients/$PG_UUID/client-secret" | jq -r '.value // empty'); secret_src="Admin API"
  fi
  if [[ -z "$PG_SECRET" ]]; then
    report L04 SKIP "service token of $PG_CLIENT" "set KC_CLIENT_SECRET (form-backend POSTGREST_KEYCLOAK_CLIENT_SECRET) or use the Admin API"
  else
    tok=$(http POST "$REALM_URL/protocol/openid-connect/token" --data-urlencode "client_id=$PG_CLIENT" \
          --data-urlencode "client_secret=$PG_SECRET" -d grant_type=client_credentials)
    TOKEN=$(jq -r '.access_token // empty' <<< "$tok" 2>/dev/null)
    if [[ -z "$TOKEN" ]]; then
      report L04 FAIL "service token of $PG_CLIENT (secret from $secret_src)" \
        "HTTP $(status): $(jq -r '.error_description // .error // empty' <<< "$tok" 2>/dev/null)" \
        "form-backend logs 'Failed to get postgrest jwt': check the secret, client enabled, service accounts on"
    else
      payload=$(decode_jwt "$TOKEN"); header=$(decode_jwt "$TOKEN" 1)
      problems=$(jq -r --arg pg "$PG_CLIENT" --arg db "$DB_ROLE" --arg aud "$JWT_AUD" --argjson h "$header" --arg kids "$PGRST_JWKS" '
        ((.resource_access[$pg].roles // []) as $r
         | if ($r | length) == 0 then "resource_access.\($pg).roles is missing: PostgREST falls back to the anonymous role"
           elif $r[0] != $db then "roles[0] = \($r[0]), expected \($db)" else empty end),
        (if $aud != "" and ([.aud] | flatten | index($aud)) == null then "aud \([.aud] | flatten | join(",")) does not contain jwt-aud \($aud): PostgREST rejects the token" else empty end),
        (($kids | fromjson? // null) as $j | if $j != null and ($j.keys? // null) != null and (any($j.keys[]; .kid == $h.kid) | not)
           then "signed with kid \($h.kid), which is not in the PostgREST JWKS" else empty end)' <<< "$payload")
      if [[ -z "$problems" ]]; then
        report L04 PASS "service token of $PG_CLIENT carries role $DB_ROLE (alg $(jq -r .alg <<< "$header"))"
      else
        report L04 FAIL "service token of $PG_CLIENT" "$problems" "see C05–C08 and L03"
      fi
    fi
  fi

  # example token of a user (Admin API only)
  if [[ -n "$TEST_USER" ]]; then
    if [[ -z "$ADMIN_TOKEN" || -z "${APP_UUID:-}" ]]; then
      report U01 SKIP "token of user $TEST_USER" "needs the Admin API (no --realm-file) and an existing $APP_CLIENT"
    else
      uid=$(aget "/users?username=$(uri "$TEST_USER")&exact=true" | jq -r '.[0].id // empty')
      if [[ -z "$uid" ]]; then
        report U01 FAIL "token of user $TEST_USER" "user not found in realm $REALM"
      else
        ex=$(aget "/clients/$APP_UUID/evaluate-scopes/generate-example-access-token?scope=openid&userId=$uid")
        roles=$(jq -c --arg a "$APP_CLIENT" '.resource_access[$a].roles // []' <<< "$ex")
        forms=$(jq -r --argjson r "$roles" --argjson fr "$FORM_ROLES" --argjson fp "$FORM_PUBLIC" -n '
          ([$fr[], $fp[]] | map(.form) | unique)[] as $f
          | [ ($fp[] | select(.form == $f) | .mode), ($fr[] | select(.form == $f) | .role as $x | select(($r | index($x)) != null) | .mode) ] | unique as $m
          | "\($f): " + (if ($m | index("write")) then "read + write" elif ($m | index("read")) then "read" else "no access" end)')
        iss=$(jq -r '.iss' <<< "$ex")
        details="roles in resource_access.$APP_CLIENT: $(jq -r 'join(", ") | if . == "" then "-" else . end' <<< "$roles")"
        [[ -n "$forms" ]] && details+=$'\n'"$forms"
        if [[ -n "$PUBLIC_URL" && "$iss" != "$PUBLIC_URL/realms/$REALM" ]]; then
          details+=$'\n'"but: issuer $iss ≠ $PUBLIC_URL/realms/$REALM → form-backend ignores this token (see L01)"
          report U01 FAIL "token of user $TEST_USER" "$details" "fix L01 first"
        elif [[ "$roles" == "[]" ]]; then
          report U01 WARN "token of user $TEST_USER" "$details" "the user has no roles of $APP_CLIENT: only forms with access true work"
        else
          report U01 INFO "token of user $TEST_USER" "$details"
        fi
      fi
    fi
  fi
else
  report L00 SKIP "live checks (issuer, public key, JWKS, service token)" "give --url"
fi

# ---------------------------------------------------------------- summary
say ""
say "summary: PASS=${COUNT[PASS]} FAIL=${COUNT[FAIL]} ERROR=${COUNT[ERROR]} WARN=${COUNT[WARN]} SKIP=${COUNT[SKIP]} INFO=${COUNT[INFO]}"
say "log written to $LOG_FILE"
if (( COUNT[FAIL] + COUNT[ERROR] > 0 )); then exit 2; fi
if (( COUNT[WARN] > 0 )); then exit 1; fi
exit 0
