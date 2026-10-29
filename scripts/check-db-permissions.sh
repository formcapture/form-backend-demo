#!/usr/bin/env bash
#
# Permission checks for form-backend / PostgREST on a native PostgreSQL installation.
#
# Needs: bash, psql. Optional: jq (--form-configs), curl + jq (--postgrest-url).
# Read-only: no INSERT/UPDATE/DELETE, no DDL. Every check result is written to a log file.
#
# Exit code: 0 = all PASS, 1 = WARN only, 2 = at least one FAIL or ERROR, 3 = usage/connection error.
#
# See docs/database-permission-checks-native.md for details on every check.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: check-db-permissions.sh [options]

Connection (standard libpq environment variables PGHOST, PGPORT, PGDATABASE, PGUSER,
PGPASSWORD, PGSSLMODE and ~/.pgpass are honored as well):
  -h, --host HOST            database host
  -p, --port PORT            database port
  -d, --dbname DB            database name
  -U, --username USER        database user (ideally a superuser, see docs)
  PSQL_CMD=...               environment variable: psql command, e.g. PSQL_CMD="sudo -u postgres psql"

What to check:
  --schemas a,b              schemas exposed by PostgREST (db-schemas)
  --tables s.t1,s.t2         tables used by form-backend (schema-qualified)
  --form-configs DIR         derive tables and id columns from form-backend's form_configs/*.json (needs jq)
  --default-schema S         schema for config tables without "schema" (POSTGREST_DEFAULT_SCHEMA);
                             default: first of --schemas
  --healthcheck s.t          healthcheck table (default: <default-schema>.__form_backend_healthcheck)
  --id-columns s.t.col,...   id column per table (form-backend's idColumn); overrides the default
                             (form configs, else the single-column primary key, else a column "id")
  --auth-role R              PostgREST login role (default: authenticator, or user in db-uri)
  --fb-role R                form-backend role (default: formbackend)
  --anon-role R              anonymous role (default: web_anon, or db-anon-role)
  --postgrest-conf FILE      PostgREST config file; provides schemas, anon role, auth role and log level
  --postgrest-url URL        PostgREST base URL for read-only HTTP checks, e.g. http://localhost:3000
                             service token check: set KC_TOKEN_URL, KC_CLIENT_ID, KC_CLIENT_SECRET (env only)
  --log FILE                 log file (default: ./db-permission-check-<timestamp>.log)
  --help                     show this help

Explicit options win over values read from --postgrest-conf.
EOF
}

# ---------------------------------------------------------------- arguments
PSQL_ARGS=() DB_USER=""
OPT_SCHEMAS="" OPT_TABLES="" OPT_DEFAULT_SCHEMA="" OPT_HEALTHCHECK=""
OPT_AUTH_ROLE="" OPT_FB_ROLE="" OPT_ANON_ROLE="" OPT_IDCOLS=""
FORM_CONFIGS="" POSTGREST_CONF="" POSTGREST_URL=""
LOG_FILE="./db-permission-check-$(date +%Y%m%d-%H%M%S).log"

need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "option $1 needs a value" >&2; exit 3; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--host)         need_arg "$@"; PSQL_ARGS+=(-h "$2"); shift 2 ;;
    -p|--port)         need_arg "$@"; PSQL_ARGS+=(-p "$2"); shift 2 ;;
    -d|--dbname)       need_arg "$@"; PSQL_ARGS+=(-d "$2"); shift 2 ;;
    -U|--username)     need_arg "$@"; PSQL_ARGS+=(-U "$2"); DB_USER=$2; shift 2 ;;
    --schemas)         need_arg "$@"; OPT_SCHEMAS=$2; shift 2 ;;
    --tables)          need_arg "$@"; OPT_TABLES=$2; shift 2 ;;
    --form-configs)    need_arg "$@"; FORM_CONFIGS=$2; shift 2 ;;
    --default-schema)  need_arg "$@"; OPT_DEFAULT_SCHEMA=$2; shift 2 ;;
    --healthcheck)     need_arg "$@"; OPT_HEALTHCHECK=$2; shift 2 ;;
    --id-columns)      need_arg "$@"; OPT_IDCOLS=$2; shift 2 ;;
    --auth-role)       need_arg "$@"; OPT_AUTH_ROLE=$2; shift 2 ;;
    --fb-role)         need_arg "$@"; OPT_FB_ROLE=$2; shift 2 ;;
    --anon-role)       need_arg "$@"; OPT_ANON_ROLE=$2; shift 2 ;;
    --postgrest-conf)  need_arg "$@"; POSTGREST_CONF=$2; shift 2 ;;
    --postgrest-url)   need_arg "$@"; POSTGREST_URL=${2%/}; shift 2 ;;
    --log)             need_arg "$@"; LOG_FILE=$2; shift 2 ;;
    --help)            usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 3 ;;
  esac
done

read -r -a PSQL <<< "${PSQL_CMD:-psql}"
# -w: never prompt. Every check opens its own connection; the password is asked once below.
PSQL+=("${PSQL_ARGS[@]}" -w -X -q -A -t -F $'\t' -v ON_ERROR_STOP=1)

: > "$LOG_FILE" || { echo "cannot write log file $LOG_FILE" >&2; exit 3; }

# ---------------------------------------------------------------- output helpers
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

# Name lookups via the catalogs: resolving 'schema.table' with to_regclass() would need USAGE
# on the schema, which a non-superuser (e.g. a monitoring role) usually does not have.
SQL_LOOKUPS=$(cat <<'EOF'
\set tbls '(SELECT t AS name, coalesce(ex.oid, ci.oid) AS oid, (ex.oid IS NULL AND ci.oid IS NOT NULL) AS case_mismatch FROM unnest(' :'tables' '::text[]) t LEFT JOIN LATERAL (SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = split_part(t, ''.'', 1) AND c.relname = split_part(t, ''.'', 2) AND c.relkind IN (''r'',''p'',''v'',''m'',''f'')) ex ON true LEFT JOIN LATERAL (SELECT min(c.oid::bigint)::oid AS oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE lower(n.nspname) = lower(split_part(t, ''.'', 1)) AND lower(c.relname) = lower(split_part(t, ''.'', 2)) AND c.relkind IN (''r'',''p'',''v'',''m'',''f'') HAVING count(*) = 1) ci ON true)'
\set hc_oid '(SELECT c.oid FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = split_part(' :'healthcheck' ', ''.'', 1) AND c.relname = split_part(' :'healthcheck' ', ''.'', 2))'
EOF
)

# psql with all check variables; SQL from stdin (prefixed with the lookups above)
run_sql() {
  { printf '%s\n' "$SQL_LOOKUPS"; cat; } | "${PSQL[@]}" \
    -v auth_role="$AUTH_ROLE" -v fb_role="$FB_ROLE" -v anon_role="$ANON_ROLE" \
    -v schemas="$SCHEMAS_ARR" -v tables="$TABLES_ARR" -v idcols="$IDCOLS_ARR" \
    -v healthcheck="$HEALTHCHECK" \
    -f - 2>&1
}

# check ID SEVERITY TITLE HINT [requires_super] <<SQL   – 0 rows = PASS, rows = SEVERITY
check() {
  local id=$1 severity=$2 title=$3 hint=$4 requires=${5:-} sql out rc
  sql=$(cat)
  if [[ "$requires" == super && "$IS_SUPER" != t ]]; then
    report "$id" SKIP "$title" "needs a superuser connection (connected as $CUR_USER)"
    return
  fi
  out=$(printf '%s\n' "$sql" | run_sql); rc=$?
  # rows raised as NOTICE by DO blocks (P17)
  out=$(printf '%s' "$out" | sed $'s/^.*NOTICE:  ROW\t//')
  if (( rc != 0 )); then
    report "$id" ERROR "$title" "check could not run: $out"
  elif [[ -z "$out" ]]; then
    report "$id" PASS "$title"
  else
    report "$id" "$severity" "$title" "$(printf '%s\n' "$out" | format_rows)" "$hint"
  fi
}

# ---------------------------------------------------------------- configuration sources
conf_value() {  # PostgREST config: key = "value" (with \" escapes)  /  key = value
  sed -n -E -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*(#.*)?$/\1/p" \
            -e "t" -e "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^\"#[:space:]]+).*$/\1/p" "$POSTGREST_CONF" \
    | tail -1 | sed 's/\\"/"/g'
}

CONF_SCHEMAS="" CONF_ANON="" CONF_AUTH="" CONF_LOGLEVEL="" CONF_CLAIM=""
if [[ -n "$POSTGREST_CONF" ]]; then
  [[ -r "$POSTGREST_CONF" ]] || { echo "cannot read $POSTGREST_CONF" >&2; exit 3; }
  CONF_SCHEMAS=$(conf_value db-schemas); [[ -z "$CONF_SCHEMAS" ]] && CONF_SCHEMAS=$(conf_value db-schema)
  CONF_ANON=$(conf_value db-anon-role)
  CONF_LOGLEVEL=$(conf_value log-level)
  CONF_CLAIM=$(conf_value jwt-role-claim-key)
  # user part of db-uri: postgres://USER:PASSWORD@host/db (the password is never logged)
  CONF_AUTH=$(conf_value db-uri | sed -n -E 's#^postgres(ql)?://([^:@/]+).*#\2#p')
fi

AUTH_ROLE=${OPT_AUTH_ROLE:-${CONF_AUTH:-authenticator}}
FB_ROLE=${OPT_FB_ROLE:-formbackend}
ANON_ROLE=${OPT_ANON_ROLE:-${CONF_ANON:-web_anon}}
SCHEMAS=${OPT_SCHEMAS:-$CONF_SCHEMAS}
SCHEMAS=$(printf '%s' "$SCHEMAS" | tr -d ' ')
DEFAULT_SCHEMA=${OPT_DEFAULT_SCHEMA:-${SCHEMAS%%,*}}

if [[ -z "$SCHEMAS" ]]; then
  echo "no schemas given: use --schemas or --postgrest-conf (see --help)" >&2; exit 3
fi
HEALTHCHECK=${OPT_HEALTHCHECK:-$DEFAULT_SCHEMA.__form_backend_healthcheck}

TABLES=$OPT_TABLES IDCOLS="" CONFIG_SCHEMAS=""
if [[ -n "$FORM_CONFIGS" ]]; then
  command -v jq >/dev/null || { echo "--form-configs needs jq" >&2; exit 3; }
  compgen -G "$FORM_CONFIGS/*.json" >/dev/null || { echo "no *.json in $FORM_CONFIGS" >&2; exit 3; }
  JQ_TABLES='.. | objects | select(has("tableName")) | "\(.schema // "DEFAULT").\(.tableName)"'
  JQ_IDCOLS='.. | objects | select(has("tableName") and has("idColumn")) | "\(.schema // "DEFAULT").\(.tableName).\(.idColumn)"'
  if [[ -z "$TABLES" ]]; then
    TABLES=$(jq -r "$JQ_TABLES" "$FORM_CONFIGS"/*.json | sed "s/^DEFAULT\./$DEFAULT_SCHEMA./" | sort -u | paste -sd, -)
  fi
  IDCOLS=$(jq -r "$JQ_IDCOLS" "$FORM_CONFIGS"/*.json | sed "s/^DEFAULT\./$DEFAULT_SCHEMA./" | sort -u | paste -sd, -)
  CONFIG_SCHEMAS=$(jq -r '.. | objects | select(has("tableName")) | .schema // empty' "$FORM_CONFIGS"/*.json | sort -u | paste -sd, -)
fi

SCHEMAS_ARR="{$SCHEMAS}"
# explicit --id-columns first: the first match per table wins
IDCOLS=$(printf '%s,%s' "$OPT_IDCOLS" "$IDCOLS" | sed 's/^,//; s/,$//')
IDCOLS_ARR="{$IDCOLS}"

# ---------------------------------------------------------------- connection
say "form-backend / PostgREST permission check – $(date '+%F %T')"
say "log file: $LOG_FILE"
log "psql: ${PSQL[*]}"
log "env: PGHOST=${PGHOST:-} PGPORT=${PGPORT:-} PGDATABASE=${PGDATABASE:-} PGUSER=${PGUSER:-} PGPASSWORD=$([[ -n "${PGPASSWORD:-}" ]] && echo '<set>' || echo '<unset>')"

probe() {
  printf '%s\n' "SELECT current_user, current_database(), current_setting('server_version_num'),
    (SELECT rolsuper FROM pg_roles WHERE rolname = current_user), inet_server_addr(), inet_server_port();" \
    | "${PSQL[@]}" -f - 2>&1
}
INFO=$(probe); rc=$?
# password needed but neither PGPASSWORD nor ~/.pgpass: ask once, reuse it for every check
# (libpq's "fe_sendauth" prefix is not translated, so this works with any locale)
if (( rc != 0 )) && [[ -z "${PGPASSWORD:-}" && -t 0 ]] && grep -q 'fe_sendauth' <<< "$INFO"; then
  read -rsp "Password for database user ${DB_USER:-${PGUSER:-$USER}}: " PGPASSWORD; echo
  export PGPASSWORD
  log "password: entered interactively, used for all checks (not logged)"
  INFO=$(probe); rc=$?
fi
if (( rc != 0 )); then
  say "${C_RED}cannot connect:${C_OFF} $INFO"
  exit 3
fi
IFS=$'\t' read -r CUR_USER CUR_DB SERVER_NUM IS_SUPER SRV_ADDR SRV_PORT <<< "$INFO"
say "connected: user=$CUR_USER db=$CUR_DB server=${SRV_ADDR:-socket}:${SRV_PORT:-} version_num=$SERVER_NUM superuser=$IS_SUPER"
[[ "$IS_SUPER" == t ]] || say "${C_YEL}not a superuser: P03, P05, P11b and P17 are skipped${C_OFF}"

# all base tables of the schemas when no table list is given
if [[ -z "$TABLES" ]]; then
  TABLES_ARR="{}"
  TABLES=$(printf '%s\n' "SELECT string_agg(format('%s.%s', n.nspname, c.relname), ',' ORDER BY 1)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = ANY (:'schemas'::text[]) AND c.relkind IN ('r','p')
      AND format('%s.%s', n.nspname, c.relname) <> :'healthcheck';" | run_sql)
  say "no --tables / --form-configs: checking all base tables in $SCHEMAS"
fi
TABLES_ARR="{$TABLES}"
say "roles: auth=$AUTH_ROLE fb=$FB_ROLE anon=$ANON_ROLE | schemas: $SCHEMAS_ARR | healthcheck: $HEALTHCHECK"
say "tables: $TABLES_ARR"
[[ -n "$IDCOLS" ]] && say "id columns (declared): $IDCOLS_ARR"
say ""

# ---------------------------------------------------------------- configuration checks (no SQL)
if [[ -n "$POSTGREST_CONF" ]]; then
  if [[ -n "$CONFIG_SCHEMAS" ]]; then
    missing=$(comm -23 <(tr ',' '\n' <<< "$CONFIG_SCHEMAS" | sort -u) <(tr ',' '\n' <<< "$SCHEMAS" | sort -u) | paste -sd, -)
    if [[ -n "$missing" ]]; then
      report S1 FAIL "form config schemas exposed in PostgREST db-schemas" \
        "used in form configs but not in db-schemas: $missing" "add them to db-schemas, otherwise requests fail with 406 PGRST106"
    else
      report S1 PASS "form config schemas exposed in PostgREST db-schemas"
    fi
  fi
  case "${CONF_LOGLEVEL:-error}" in
    warn|info|debug) report S2 PASS "PostgREST log-level logs 4xx (log-level=$CONF_LOGLEVEL)" ;;
    *) report S2 WARN "PostgREST log-level logs 4xx" "log-level=${CONF_LOGLEVEL:-<unset, default error>}: 401/403 permission errors are not logged" \
         'set log-level = "warn" in the PostgREST config and restart PostgREST' ;;
  esac
  if [[ -z "$CONF_CLAIM" ]]; then
    report S3 INFO "PostgREST jwt-role-claim-key" "not set: PostgREST reads the role from the claim \"role\"; form-backend's Keycloak tokens carry it in resource_access.<client>.roles"
  else
    report S3 INFO "PostgREST jwt-role-claim-key" "$CONF_CLAIM"
  fi
fi

# ---------------------------------------------------------------- SQL checks
check P01 FAIL "roles exist with the right attributes" "create/alter the role" <<'SQL'
SELECT e.role, CASE
         WHEN r.rolname IS NULL THEN 'role does not exist'
         WHEN r.rolsuper THEN 'is SUPERUSER'
         WHEN r.rolbypassrls THEN 'has BYPASSRLS (RLS is ignored)'
         WHEN e.expect = 'login' AND NOT r.rolcanlogin THEN 'cannot LOGIN'
         WHEN e.expect = 'nologin' AND r.rolcanlogin THEN 'can LOGIN, should be NOLOGIN'
         WHEN r.rolvaliduntil < now() THEN 'password expired at ' || r.rolvaliduntil
       END,
       CASE WHEN r.rolname IS NULL THEN format('CREATE ROLE %I %s;', e.role, upper(e.expect)) ELSE '' END
FROM (VALUES (:'auth_role', 'login'), (:'fb_role', 'nologin'), (:'anon_role', 'nologin')) e(role, expect)
LEFT JOIN pg_roles r ON r.rolname = e.role
WHERE r.rolname IS NULL OR r.rolsuper OR r.rolbypassrls
   OR (e.expect = 'login') <> r.rolcanlogin
   OR r.rolvaliduntil < now();
SQL

check P01b WARN "role hardening (inherit, expiry, connection limit)" "see docs, section P01b" <<'SQL'
SELECT rolname, problem, fix FROM (
  SELECT rolname, 'role attribute INHERIT is on (PG ≥ 16: applies to memberships granted from now on; see P01c)' AS problem,
         format('ALTER ROLE %I NOINHERIT;', rolname) AS fix
  FROM pg_roles WHERE rolname = :'auth_role' AND rolinherit
  UNION ALL
  SELECT rolname, 'password expires within 30 days: ' || rolvaliduntil, format('ALTER ROLE %I VALID UNTIL ''infinity'';', rolname)
  FROM pg_roles WHERE rolname = :'auth_role' AND rolvaliduntil BETWEEN now() AND now() + interval '30 days'
  UNION ALL
  SELECT rolname, 'connection limit ' || rolconnlimit || ' (PostgREST pool needs enough connections)', ''
  FROM pg_roles WHERE rolname = :'auth_role' AND rolconnlimit <> -1
) x;
SQL

if (( SERVER_NUM >= 160000 )); then
check P02 FAIL "$AUTH_ROLE can SET ROLE to $FB_ROLE / $ANON_ROLE" "PostgREST fails with: permission denied to set role" <<'SQL'
SELECT g.role, 'authenticator is not a member with SET option',
       format('GRANT %I TO %I WITH INHERIT FALSE, SET TRUE;', g.role, :'auth_role')
FROM (VALUES (:'fb_role'), (:'anon_role')) g(role)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_auth_members a
  JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
  WHERE m.rolname = :'auth_role' AND r.rolname = g.role AND a.set_option);
SQL
else
check P02 FAIL "$AUTH_ROLE can SET ROLE to $FB_ROLE / $ANON_ROLE" "PostgREST fails with: permission denied to set role" <<'SQL'
SELECT g.role, 'authenticator is not a member', format('GRANT %I TO %I;', g.role, :'auth_role')
FROM (VALUES (:'fb_role'), (:'anon_role')) g(role)
WHERE NOT pg_has_role(:'auth_role', g.role, 'MEMBER');
SQL
fi

if (( SERVER_NUM >= 160000 )); then
check P01c WARN "$AUTH_ROLE memberships do not inherit privileges" "PostgREST only needs SET ROLE; inherited privileges let authenticator act as formbackend directly" <<'SQL'
SELECT m.rolname || ' → ' || r.rolname, 'membership has INHERIT TRUE: privileges apply without SET ROLE',
       format('GRANT %I TO %I WITH INHERIT FALSE;', r.rolname, m.rolname)
FROM pg_auth_members a
JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
WHERE m.rolname = :'auth_role' AND a.inherit_option;
SQL
fi

check P03 FAIL "$AUTH_ROLE has a SCRAM password" "ALTER ROLE ... PASSWORD '...' (with password_encryption = scram-sha-256)" super <<'SQL'
SELECT rolname, CASE WHEN rolpassword IS NULL THEN 'no password' ELSE 'not SCRAM-SHA-256 (md5?)' END, ''
FROM pg_authid
WHERE rolname = :'auth_role' AND (rolpassword IS NULL OR rolpassword NOT LIKE 'SCRAM-SHA-256$%');
SQL

check P04 FAIL "$AUTH_ROLE may CONNECT to the database" "PostgREST fails with: permission denied for database" <<'SQL'
SELECT current_database(), 'no CONNECT privilege', format('GRANT CONNECT ON DATABASE %I TO %I;', current_database(), :'auth_role')
WHERE NOT has_database_privilege(:'auth_role', current_database(), 'CONNECT');
SQL

check P05 WARN "pg_hba.conf has no errors / no trust for remote hosts" "edit pg_hba.conf, then SELECT pg_reload_conf();" super <<'SQL'
SELECT 'line ' || line_number, coalesce('error: ' || error, format('%s %s for %s from %s', type, auth_method, array_to_string(user_name, ','), coalesce(address, 'any'))), ''
FROM pg_hba_file_rules
WHERE error IS NOT NULL
   OR (type LIKE 'host%' AND auth_method IN ('trust', 'password') AND coalesce(address, '') NOT IN ('127.0.0.1', '::1'));
SQL

check P06 FAIL "tables used by form-backend exist" "fix the form config or create the table; PostgREST answers 404 PGRST205" <<'SQL'
SELECT name,
       CASE WHEN oid IS NULL THEN 'table does not exist'
            ELSE format('no table with this exact name; exists as %s. Names are case-sensitive in PostgREST and form-backend (unquoted CREATE TABLE stores lower case). The other checks use %s.', oid::regclass, oid::regclass) END,
       ''
FROM :tbls tb WHERE oid IS NULL OR case_mismatch;
SQL

check P07 FAIL "schema USAGE for $FB_ROLE / $ANON_ROLE" "error: permission denied for schema" <<'SQL'
SELECT s || ' / ' || r, 'no USAGE on schema', format('GRANT USAGE ON SCHEMA %I TO %I;', s, r)
FROM unnest(:'schemas'::name[]) s, unnest(ARRAY[:'fb_role', :'anon_role']::name[]) r
WHERE to_regnamespace(s) IS NOT NULL AND NOT has_schema_privilege(r, s, 'USAGE')
UNION ALL
SELECT s, 'schema does not exist', '' FROM unnest(:'schemas'::name[]) s WHERE to_regnamespace(s) IS NULL;
SQL

check P08 FAIL "table privileges ($FB_ROLE: CRUD, $ANON_ROLE: SELECT)" "error 42501: permission denied for table" <<'SQL'
SELECT tb.name || ' / ' || r.role, 'missing ' || p, format('GRANT %s ON %s TO %I;', p, tb.oid::regclass, r.role)
FROM :tbls tb
CROSS JOIN (VALUES (:'fb_role', ARRAY['SELECT','INSERT','UPDATE','DELETE']),
                   (:'anon_role', ARRAY['SELECT'])) r(role, privs)
CROSS JOIN LATERAL unnest(r.privs) p
WHERE tb.oid IS NOT NULL AND NOT has_table_privilege(r.role, tb.oid, p)
ORDER BY 1, 2;
SQL

check P09 FAIL "sequences behind column defaults usable by $FB_ROLE" "error on create: permission denied for sequence" <<'SQL'
-- identity columns are not listed: PostgreSQL does not check sequence privileges for them
WITH seqs AS MATERIALIZED (
  -- default nextval('seq'::regclass): recorded as dependency
  SELECT s.oid::regclass AS seq, ad.adrelid::regclass AS tbl
  FROM pg_attrdef ad
  JOIN pg_depend d ON d.classid = 'pg_attrdef'::regclass AND d.objid = ad.oid AND d.refclassid = 'pg_class'::regclass
  JOIN pg_class s ON s.oid = d.refobjid AND s.relkind = 'S'
  WHERE ad.adrelid IN (SELECT oid FROM :tbls tb)
  UNION
  -- default nextval('seq'::text): no dependency, parse the expression
  SELECT s.oid::regclass, x.tbl
  FROM (SELECT ad.adrelid::regclass AS tbl,
               replace(substring(pg_get_expr(ad.adbin, ad.adrelid) FROM 'nextval\(\(?''([^'']+)'''), '"', '') AS seqname
        FROM pg_attrdef ad
        WHERE ad.adrelid IN (SELECT oid FROM :tbls tb)) x
  JOIN pg_class s ON s.relkind = 'S' AND s.relname = regexp_replace(x.seqname, '^.*\.', '')
  JOIN pg_namespace sn ON sn.oid = s.relnamespace
                      AND (x.seqname NOT LIKE '%.%' OR sn.nspname = split_part(x.seqname, '.', 1))
)
SELECT tbl || ' → ' || seq, 'no USAGE on sequence', format('GRANT USAGE, SELECT ON SEQUENCE %s TO %I;', seq, :'fb_role')
FROM seqs
WHERE NOT has_sequence_privilege(:'fb_role', seq, 'USAGE');
SQL

check P09b WARN "all sequences in the schemas usable by $FB_ROLE (triggers/functions)" "only relevant if a trigger or function calls nextval() on it" <<'SQL'
WITH seqs AS MATERIALIZED (
  SELECT s.oid
  FROM pg_class s JOIN pg_namespace n ON n.oid = s.relnamespace
  WHERE s.relkind = 'S' AND n.nspname = ANY (:'schemas'::name[])
    AND NOT EXISTS (SELECT 1 FROM pg_depend d
                    WHERE d.classid = 'pg_class'::regclass AND d.objid = s.oid
                      AND (d.deptype = 'i' OR d.refobjid = :hc_oid))
)
SELECT oid::regclass::text, 'no USAGE on sequence', format('GRANT USAGE, SELECT ON SEQUENCE %s TO %I;', oid::regclass, :'fb_role')
FROM seqs
WHERE NOT has_sequence_privilege(:'fb_role', oid, 'USAGE');
SQL

check P10 FAIL "SELECT on FK-referenced tables (lookups / embedding)" "lookup lists stay empty, PostgREST: 42501 or PGRST200" <<'SQL'
SELECT DISTINCT c.conrelid::regclass || ' → ' || c.confrelid::regclass || ' / ' || r.role,
       'no SELECT on referenced table', format('GRANT SELECT ON %s TO %I;', c.confrelid::regclass, r.role)
FROM pg_constraint c
CROSS JOIN (VALUES (:'fb_role'), (:'anon_role')) r(role)
WHERE c.contype = 'f'
  AND c.conrelid IN (SELECT oid FROM :tbls tb)
  AND NOT has_table_privilege(r.role, c.confrelid, 'SELECT');
SQL

check P11 FAIL "healthcheck table usable by $FB_ROLE" "form-backend exits at startup (Insufficient privileges for role formbackend)" <<'SQL'
SELECT :'healthcheck', problem, fix FROM (
  SELECT CASE
    WHEN :hc_oid IS NULL THEN 'table missing (migration not run?)'
    WHEN NOT has_table_privilege(:'fb_role', :hc_oid, 'SELECT') THEN 'no SELECT'
    WHEN NOT has_table_privilege(:'fb_role', :hc_oid, 'UPDATE') THEN 'no UPDATE'
  END AS problem,
  CASE
    WHEN :hc_oid IS NULL THEN 'run postgres/migrations/V1.0.0_form_backend_testtable.sql'
    WHEN NOT has_table_privilege(:'fb_role', :hc_oid, 'SELECT') OR NOT has_table_privilege(:'fb_role', :hc_oid, 'UPDATE')
      THEN format('GRANT SELECT, UPDATE ON %s TO %I;', :'healthcheck', :'fb_role')
  END AS fix) x
WHERE problem IS NOT NULL;
SQL

check P11b FAIL "healthcheck row id = 1 exists" "without it the startup PATCH matches 0 rows and silently succeeds" super <<'SQL'
SELECT :'healthcheck', 'row id = 1 missing', format('INSERT INTO %s (id, last_start) VALUES (1, now());', :'healthcheck')
WHERE :hc_oid IS NOT NULL
  AND (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %s WHERE id = 1', :hc_oid::regclass), false, true, '')))[1]::text = '0';
SQL

check P12 FAIL "no RLS without a policy for $FB_ROLE / $ANON_ROLE" "no error, but 0 rows and writes without effect; add a policy or disable RLS" <<'SQL'
SELECT c.oid::regclass || ' / ' || r.role, 'RLS enabled, no policy applies to the role', ''
FROM pg_class c
CROSS JOIN (VALUES (:'fb_role'), (:'anon_role')) r(role)
WHERE c.relrowsecurity
  AND (c.oid IN (SELECT oid FROM :tbls tb) OR c.oid = :hc_oid)
  AND NOT EXISTS (
    SELECT 1 FROM pg_policy p
    WHERE p.polrelid = c.oid
      AND (0 = ANY (p.polroles) OR (SELECT oid FROM pg_roles WHERE rolname = r.role) = ANY (p.polroles)));
SQL

check P13 WARN "default privileges for table owners" "without them, every new table needs explicit GRANTs" <<'SQL'
SELECT DISTINCT n.nspname || ' / owner ' || pg_get_userbyid(c.relowner), 'new tables of this owner get no grants for ' || :'fb_role',
       format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I;',
              pg_get_userbyid(c.relowner), n.nspname, :'fb_role')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY (:'schemas'::name[]) AND c.relkind IN ('r','p','v','m')
  AND NOT EXISTS (
    SELECT 1 FROM pg_default_acl d
    WHERE d.defaclrole = c.relowner AND d.defaclobjtype = 'r'
      AND (d.defaclnamespace = n.oid OR d.defaclnamespace = 0)
      AND array_to_string(d.defaclacl, ',') LIKE '%' || :'fb_role' || '=%');
SQL

check P14a WARN "$ANON_ROLE cannot write" "anyone reaching PostgREST without a token can change data" <<'SQL'
SELECT c.oid::regclass::text, :'anon_role' || ' has ' || p, format('REVOKE %s ON %s FROM %I;', p, c.oid::regclass, :'anon_role')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN unnest(ARRAY['INSERT','UPDATE','DELETE','TRUNCATE']) p
WHERE n.nspname = ANY (:'schemas'::name[]) AND c.relkind IN ('r','p','v','m','f')
  AND has_table_privilege(:'anon_role', c.oid, p)
ORDER BY 1, 2;
SQL

check P14b WARN "API roles cannot CREATE in the schemas" "API roles should not create objects" <<'SQL'
SELECT s::text || ' / ' || r, 'has CREATE on schema', format('REVOKE CREATE ON SCHEMA %I FROM %I;', s, r)
FROM unnest(:'schemas'::name[]) s, unnest(ARRAY[:'auth_role', :'fb_role', :'anon_role']::name[]) r
WHERE to_regnamespace(s) IS NOT NULL AND has_schema_privilege(r, s, 'CREATE');
SQL

check P14c WARN "API roles own no objects / no grants to PUBLIC / authenticator has no direct grants" "owners bypass RLS and can DROP; PUBLIC includes every role" <<'SQL'
SELECT c.oid::regclass::text, 'owned by API role ' || pg_get_userbyid(c.relowner), ''
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = ANY (:'schemas'::name[]) AND c.relkind IN ('r','p','v','m','f','S')
  AND pg_get_userbyid(c.relowner) IN (:'auth_role', :'fb_role', :'anon_role')
UNION ALL
SELECT c.oid::regclass::text, 'privilege ' || a.privilege_type || ' granted to PUBLIC', format('REVOKE ALL ON %s FROM PUBLIC;', c.oid::regclass)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a
WHERE n.nspname = ANY (:'schemas'::name[]) AND c.relkind IN ('r','p','v','m','f','S') AND a.grantee = 0
UNION ALL
SELECT c.oid::regclass::text, :'auth_role' || ' has direct ' || a.privilege_type, format('REVOKE ALL ON %s FROM %I;', c.oid::regclass, :'auth_role')
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL aclexplode(c.relacl) a
WHERE n.nspname = ANY (:'schemas'::name[]) AND a.grantee = (SELECT oid FROM pg_roles WHERE rolname = :'auth_role');
SQL

check P15 INFO "role-level settings" "" <<'SQL'
SELECT r.rolname || coalesce(' @ ' || d.datname, ''), array_to_string(s.setconfig, ', '), ''
FROM pg_db_role_setting s
JOIN pg_roles r ON r.oid = s.setrole
LEFT JOIN pg_database d ON d.oid = s.setdatabase
WHERE r.rolname IN (:'auth_role', :'fb_role', :'anon_role');
SQL

check P16 FAIL "id columns get a value from the database" "form-backend omits the id on create → error 23502 (not-null violation)" <<'SQL'
-- form-backend removes the idColumn from the request body, so the database must fill it in.
-- id column: declared in the form configs / --id-columns, else the single-column primary key, else "id"
WITH idc AS (
  SELECT tb.oid, coalesce(dec.col, pk.col, idcol.col) AS col, dec.col IS NOT NULL AS declared
  FROM :tbls tb
  LEFT JOIN LATERAL (SELECT split_part(x.v, '.', 3) AS col FROM unnest(:'idcols'::text[]) WITH ORDINALITY x(v, ord)
                     WHERE lower(split_part(x.v, '.', 1) || '.' || split_part(x.v, '.', 2)) = lower(tb.name)
                     ORDER BY x.ord LIMIT 1) dec ON true
  LEFT JOIN LATERAL (SELECT a.attname::text AS col FROM pg_constraint c
                     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
                     WHERE c.conrelid = tb.oid AND c.contype = 'p' AND cardinality(c.conkey) = 1) pk ON true
  LEFT JOIN LATERAL (SELECT 'id'::text AS col FROM pg_attribute a
                     WHERE a.attrelid = tb.oid AND a.attname = 'id' AND NOT a.attisdropped) idcol ON true
  WHERE tb.oid IS NOT NULL
)
SELECT idc.oid::regclass || '.' || idc.col,
       CASE WHEN a.attname IS NULL THEN 'idColumn does not exist'
            ELSE 'NOT NULL without default, identity or generated value' END,
       CASE WHEN a.attname IS NULL THEN ''
            ELSE format('ALTER TABLE %s ALTER COLUMN %I ADD GENERATED BY DEFAULT AS IDENTITY;  -- then: SELECT setval(pg_get_serial_sequence(%L, %L), (SELECT max(%I) FROM %s));',
                        idc.oid::regclass, idc.col, idc.oid::regclass::text, idc.col, idc.col, idc.oid::regclass) END
FROM idc
LEFT JOIN pg_attribute a ON a.attrelid = idc.oid AND a.attname = idc.col AND NOT a.attisdropped
WHERE idc.col IS NOT NULL
  AND ((a.attname IS NULL AND idc.declared)
    OR (a.attnotnull AND NOT a.atthasdef AND a.attidentity = '' AND a.attgenerated = ''
        -- skipped when a BEFORE INSERT row trigger exists (assumed to set the id; P09b checks its sequence)
        AND NOT EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = idc.oid AND NOT tg.tgisinternal
                        AND tg.tgenabled <> 'D' AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 2) = 2 AND (tg.tgtype & 4) = 4)));
SQL

check P16b WARN "NOT NULL columns without default (must be filled by the form)" "make the column nullable, add a default, or make sure the form always sends it; otherwise error 23502" <<'SQL'
WITH idc AS (
  SELECT tb.oid, coalesce(dec.col, pk.col, idcol.col) AS col, dec.col IS NOT NULL AS declared
  FROM :tbls tb
  LEFT JOIN LATERAL (SELECT split_part(x.v, '.', 3) AS col FROM unnest(:'idcols'::text[]) WITH ORDINALITY x(v, ord)
                     WHERE lower(split_part(x.v, '.', 1) || '.' || split_part(x.v, '.', 2)) = lower(tb.name)
                     ORDER BY x.ord LIMIT 1) dec ON true
  LEFT JOIN LATERAL (SELECT a.attname::text AS col FROM pg_constraint c
                     JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
                     WHERE c.conrelid = tb.oid AND c.contype = 'p' AND cardinality(c.conkey) = 1) pk ON true
  LEFT JOIN LATERAL (SELECT 'id'::text AS col FROM pg_attribute a
                     WHERE a.attrelid = tb.oid AND a.attname = 'id' AND NOT a.attisdropped) idcol ON true
  WHERE tb.oid IS NOT NULL
)
SELECT a.attrelid::regclass || '.' || a.attname,
       CASE WHEN EXISTS (SELECT 1 FROM pg_trigger tg WHERE tg.tgrelid = a.attrelid AND NOT tg.tgisinternal
                         AND tg.tgenabled <> 'D' AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 2) = 2 AND (tg.tgtype & 4) = 4)
            THEN 'NOT NULL without default (table has a BEFORE INSERT trigger – does it set this column?)'
            ELSE 'NOT NULL without default' END,
       ''
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.attrelid IN (SELECT oid FROM :tbls tb)
  AND a.attnum > 0 AND NOT a.attisdropped
  AND a.attnotnull AND NOT a.atthasdef AND a.attidentity = '' AND a.attgenerated = ''
  -- join-table keys (PK and FK at the same time) are filled by form-backend
  AND NOT (EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = a.attrelid AND c.contype = 'p' AND a.attnum = ANY (c.conkey))
       AND EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = a.attrelid AND c.contype = 'f' AND a.attnum = ANY (c.conkey)))
  -- id columns are covered by P16
  AND NOT EXISTS (SELECT 1 FROM idc WHERE idc.oid = a.attrelid AND idc.col = a.attname)
ORDER BY 1;
SQL

# smoke test: EXPLAIN as each role (privilege check without execution, READ ONLY transaction)
check P17 FAIL "real statement path (EXPLAIN as $FB_ROLE / $ANON_ROLE)" "see P07/P08; for views: the view owner lacks privileges on the base table" super <<'SQL'
BEGIN READ ONLY;
SELECT set_config('dbg.tables', :'tables', true), set_config('dbg.fb', :'fb_role', true), set_config('dbg.anon', :'anon_role', true) \g /dev/null
DO $$
DECLARE
  r text; t text; op text; col text; stmt text; allowed boolean; expected boolean;
BEGIN
  FOREACH r IN ARRAY ARRAY[current_setting('dbg.fb'), current_setting('dbg.anon')] LOOP
    FOREACH t IN ARRAY current_setting('dbg.tables')::text[] LOOP
      CONTINUE WHEN to_regclass(t) IS NULL;
      SELECT quote_ident(attname) INTO col FROM pg_attribute
       WHERE attrelid = t::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum LIMIT 1;
      FOREACH op IN ARRAY ARRAY['SELECT','INSERT','UPDATE','DELETE'] LOOP
        stmt := CASE op
          WHEN 'SELECT' THEN format('EXPLAIN SELECT * FROM %s', t)
          WHEN 'INSERT' THEN format('EXPLAIN INSERT INTO %s DEFAULT VALUES', t)
          WHEN 'UPDATE' THEN format('EXPLAIN UPDATE %s SET %s = %s WHERE false', t, col, col)
          WHEN 'DELETE' THEN format('EXPLAIN DELETE FROM %s WHERE false', t)
        END;
        expected := (r = current_setting('dbg.fb') OR op = 'SELECT');
        BEGIN
          EXECUTE format('SET LOCAL ROLE %I', r);
          EXECUTE stmt;
          allowed := true;
        EXCEPTION WHEN insufficient_privilege THEN
          allowed := false;
          stmt := SQLERRM;
        END;
        RESET ROLE;
        IF allowed <> expected THEN
          RAISE NOTICE E'ROW\t%\t%\t', format('%s / %s %s', t, r, op),
            CASE WHEN allowed THEN 'allowed, should be denied' ELSE 'denied: ' || stmt END;
        END IF;
      END LOOP;
    END LOOP;
  END LOOP;
END $$;
ROLLBACK;
SQL

# ---------------------------------------------------------------- PostgREST HTTP checks (read-only)
if [[ -n "$POSTGREST_URL" ]]; then
  if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
    report H0 SKIP "PostgREST HTTP checks" "needs curl and jq"
  else
    IFS=, read -r -a TBL_LIST <<< "$TABLES"

    # H1: anonymous OpenAPI per schema
    for s in ${SCHEMAS//,/ }; do
      body=$(curl -s -m 10 -H "Accept-Profile: $s" "$POSTGREST_URL/" 2>&1); rc=$?
      if (( rc != 0 )); then
        report H1 ERROR "PostgREST reachable ($POSTGREST_URL, schema $s)" "curl exit $rc: $body"
        continue
      fi
      visible=$(jq -r '.definitions // {} | keys[]' <<< "$body" 2>/dev/null)
      if [[ -z "$visible" ]] && jq -e '.code' <<< "$body" >/dev/null 2>&1; then
        report H1 FAIL "PostgREST OpenAPI for schema $s" "$(jq -r '"\(.code): \(.message)"' <<< "$body")" "PGRST106: schema not in db-schemas"
      else
        report H1 PASS "PostgREST OpenAPI for schema $s ($(wc -w <<< "$visible") tables visible as $ANON_ROLE)"
      fi
    done

    # H2: service token as form-backend uses it (KC_* from the environment only)
    if [[ -n "${KC_TOKEN_URL:-}" && -n "${KC_CLIENT_ID:-}" && -n "${KC_CLIENT_SECRET:-}" ]]; then
      tok_json=$(curl -s -m 10 -X POST "$KC_TOKEN_URL" --data-urlencode "client_id=$KC_CLIENT_ID" \
                 --data-urlencode "client_secret=$KC_CLIENT_SECRET" -d grant_type=client_credentials 2>&1)
      TOKEN=$(jq -r '.access_token // empty' <<< "$tok_json" 2>/dev/null)
      if [[ -z "$TOKEN" ]]; then
        report H2 FAIL "service token from Keycloak ($KC_CLIENT_ID)" "$(jq -r '.error_description // .error // .' <<< "$tok_json" 2>/dev/null || echo "$tok_json")" \
          "check client secret / client enabled / service account"
      else
        payload=$(cut -d. -f2 <<< "$TOKEN" | tr '_-' '/+'); while (( ${#payload} % 4 )); do payload+="="; done
        role=$(base64 -d <<< "$payload" 2>/dev/null | jq -r --arg c "$KC_CLIENT_ID" '.resource_access[$c].roles[0] // empty')
        if [[ "$role" == "$FB_ROLE" ]]; then
          report H2 PASS "service token carries role $FB_ROLE"
        else
          report H2 FAIL "service token carries role $FB_ROLE" "resource_access.$KC_CLIENT_ID.roles[0] = '${role:-<missing>}'" \
            "Keycloak: Clients → $KC_CLIENT_ID → Service account roles → client role $FB_ROLE"
        fi
        # H3: every form table readable with the service token
        details=""
        resp=$(mktemp)
        for t in "${TBL_LIST[@]}"; do
          s=${t%%.*}; n=${t#*.}
          code=$(curl -s -m 10 -o "$resp" -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
                 -H "Accept-Profile: $s" "$POSTGREST_URL/$n?limit=1")
          [[ "$code" == 200 ]] || details+="$t: HTTP $code $(head -c 200 "$resp")"$'\n'
        done
        rm -f "$resp"
        if [[ -z "$details" ]]; then
          report H3 PASS "all ${#TBL_LIST[@]} form tables readable via PostgREST as $FB_ROLE"
        else
          report H3 FAIL "form tables readable via PostgREST as $FB_ROLE" "${details%$'\n'}" \
            "401 PGRST301: JWKS/secret; 42501: P08; PGRST205: P06 or NOTIFY pgrst, 'reload schema'; PGRST106: S1"
        fi
      fi
    else
      report H2 SKIP "service token checks" "set KC_TOKEN_URL, KC_CLIENT_ID and KC_CLIENT_SECRET to enable"
    fi
  fi
fi

# ---------------------------------------------------------------- summary
say ""
summary="summary: PASS=${COUNT[PASS]} FAIL=${COUNT[FAIL]} ERROR=${COUNT[ERROR]} WARN=${COUNT[WARN]} SKIP=${COUNT[SKIP]} INFO=${COUNT[INFO]}"
say "$summary"
say "log written to $LOG_FILE"
if (( COUNT[FAIL] + COUNT[ERROR] > 0 )); then exit 2; fi
if (( COUNT[WARN] > 0 )); then exit 1; fi
exit 0
