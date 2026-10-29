# Database Permission Checks: Native Installation

This guide is for deployments **without Docker**: PostgreSQL is installed natively, PostgREST and form-backend run as services, and there is **no central `.env` file**. It ships with a standalone script, [`scripts/check-db-permissions.sh`](../scripts/check-db-permissions.sh), which runs every permission check, prints a status for each one, and writes everything to a log file.

The checks are the same as in the Docker variant ([database-permission-checks-production.md](database-permission-checks-production.md)). This one adds checks for the problems found in customer deployments:

| Problem seen in the field | Symptom | Check |
|---------------------------|---------|-------|
| `id` column without default/sequence/identity | `ErrorCodes.DATABASE.23502` ("Eintrag konnte nicht erstellt werden") | **P16** |
| NOT NULL column the form doesn't fill | `23502` | **P16b** |
| `formbackend` lacks `USAGE` on the sequence of a default (`::regclass` and the older `::text` form) | `permission denied for sequence …` | **P09** |
| Sequence only used in a trigger | `permission denied for sequence …` | **P09b** |
| `web_anon` has INSERT/UPDATE/DELETE | none, but anyone without a token can change data | **P14a** |
| API roles have `CREATE` on the schema | none (hardening) | **P14b** |
| `authenticator` has `INHERIT` / inheriting memberships | none (authenticator can act as `formbackend` without `SET ROLE`) | **P01b**, **P01c** |
| A view whose owner can't read the base table | `permission denied for table <base table>`, even though the grants on the view look right | **P17** |
| Healthcheck row missing | form-backend's startup check passes even though nothing was updated | **P11b** |

Every check was tested against PostgreSQL 17 with PostgREST v13. It was run against a healthy database and against a copy with all of the faults above injected, both as a superuser and as a non-superuser. The outputs below come from those runs.

---

## 1. Requirements

| Tool | Needed for |
|------|------------|
| `bash`, `psql` | everything (any `psql` that can connect to the server) |
| `jq` | `--form-configs` (reading the form configs) and the HTTP checks |
| `curl` | the HTTP checks (`--postgrest-url`) |

The script is **read-only**: no INSERT, UPDATE, DELETE or DDL. The write checks use `EXPLAIN` inside a `READ ONLY` transaction, which runs PostgreSQL's privilege check without executing the statement.

---

## 2. Where the script gets its settings (no `.env`)

| Setting | Source, in order of precedence |
|---------|--------------------------------|
| DB connection | `-h/-p/-d/-U`, then the libpq variables `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE`, then `~/.pgpass`, then peer authentication |
| `psql` command | `PSQL_CMD` (e.g. `PSQL_CMD="sudo -u postgres psql"` for peer authentication), default `psql` |
| Exposed schemas | `--schemas`, then `db-schemas` from `--postgrest-conf` |
| Anonymous role | `--anon-role`, then `db-anon-role` from the PostgREST config, then `web_anon` |
| Login role | `--auth-role`, then the user in `db-uri` from the PostgREST config, then `authenticator` |
| form-backend role | `--fb-role`, default `formbackend` |
| Tables used by form-backend | `--tables`, then every `tableName` in `--form-configs DIR/*.json`, then **all tables** of the schemas |
| `idColumn` per table | `--id-columns schema.table.column,…`, then `idColumn` from `--form-configs`, then the table's **single-column primary key** (covers `fid`, `gid`, `ogc_fid` from GeoServer/ogr2ogr), then a column named `id` |
| Default schema of the form configs | `--default-schema` (= form-backend's `POSTGREST_DEFAULT_SCHEMA`), then the first entry of the schemas |
| Healthcheck table | `--healthcheck`, then `<default-schema>.__form_backend_healthcheck` |
| Keycloak (HTTP check H2/H3) | **environment variables only**: `KC_TOKEN_URL`, `KC_CLIENT_ID`, `KC_CLIENT_SECRET` |

The script never writes the password from `db-uri` or `KC_CLIENT_SECRET` to the console or the log. `PGPASSWORD` only appears in the log as `<set>`.

**Password prompt.** Each check opens its own connection. If neither `PGPASSWORD` nor `~/.pgpass` provides a password, the script asks **once** at the start, without echo, and reuses the password for every check. It's kept only in the script process's environment and logged as "entered interactively". A wrong password stops the script with exit code `3`, without asking again. Without a terminal (cron, CI) it never prompts and stops with `no password supplied`: use `~/.pgpass` (mode `0600`) or `PGPASSWORD` there. With `PSQL_CMD="sudo -u postgres psql"`, peer authentication applies; a password is only needed for TCP connections. Note that `sudo` drops `PGPASSWORD` from the environment, so put it in the `~postgres/.pgpass` file instead.

---

## 3. Running it

### Which user?

Run it as a **superuser**, typically `postgres`, to get every check. A non-superuser works too: name lookups go through the system catalogs, so it needs no `USAGE` on the schemas. But four checks need superuser rights and are then reported as `SKIP`:

- P03 (password hash, `pg_authid`)
- P05 (`pg_hba_file_rules`)
- P11b (reading the healthcheck row)
- P17 (`SET ROLE` smoke test)

### Examples

**On the DB server, peer authentication as `postgres`, with the PostgREST config and the form configs:**
```bash
PSQL_CMD="sudo -u postgres psql" ./scripts/check-db-permissions.sh -d geodb \
  --postgrest-conf /etc/postgrest/postgrest.conf \
  --form-configs /opt/form-backend/form_configs
```

**Remote over TCP, with the password from `~/.pgpass` or entered once:**
```bash
read -rs PGPASSWORD && export PGPASSWORD
./scripts/check-db-permissions.sh -h db.example.org -p 5432 -U postgres -d geodb \
  --schemas data --default-schema data --form-configs ./form_configs
```

**Minimal, checking all tables of one schema:**
```bash
./scripts/check-db-permissions.sh -h localhost -U postgres -d geodb --schemas data
```

**Including the HTTP checks against PostgREST.** The client secret is read without echo and only lives in the environment:
```bash
export KC_TOKEN_URL=https://auth.example.org/auth/realms/masterportal/protocol/openid-connect/token
export KC_CLIENT_ID=postgrest-client
read -rs KC_CLIENT_SECRET && export KC_CLIENT_SECRET
./scripts/check-db-permissions.sh -d geodb --postgrest-conf /etc/postgrest/postgrest.conf \
  --form-configs /opt/form-backend/form_configs --postgrest-url http://localhost:3000
```
For a self-signed certificate on Keycloak, also set `CURL_CA_BUNDLE=/path/to/ca.pem`.

### Status, exit code, log

| Status | Meaning |
|--------|---------|
| `PASS` | check passed |
| `FAIL` | a problem that causes errors in form-backend/PostgREST |
| `WARN` | a security or hardening problem, or a latent risk; no error today |
| `SKIP` | check not possible (no superuser, tool missing, no `KC_*`) |
| `ERROR` | **the check itself failed** (e.g. a role named in the parameters doesn't exist); the psql error message is logged |
| `INFO` | for information only |

Exit code: `0` all PASS · `1` only WARN · `2` at least one FAIL or ERROR · `3` usage error or no DB connection. That makes the script usable in monitoring and CI.

The log file (default `./db-permission-check-<timestamp>.log`, or `--log FILE`) contains:
- the parameters used: `psql` command, `PG*` variables (password only as `<set>`), roles, schemas, tables, id columns
- the server version and whether the connection is a superuser
- one timestamped line per check, plus every affected object with the fix statement

Example: the log header, then a FAIL entry:
```
form-backend / PostgREST permission check – 2026-10-29 14:50:21
psql: psql -h localhost -p 6667 -U postgres -d postgres -X -q -A -t -F 	 -v ON_ERROR_STOP=1
env: PGHOST= PGPORT= PGDATABASE= PGUSER= PGPASSWORD=<set>
connected: user=postgres db=postgres server=172.20.0.2:5432 version_num=170011 superuser=t
roles: auth=authenticator fb=formbackend anon=web_anon | schemas: {sampledata} | healthcheck: sampledata.__form_backend_healthcheck
tables: {other.spielplaetze,sampledata.contacts,sampledata.fountains,…,sampledata.v_fountains}
…
2026-10-29 14:45:59 FAIL  P16   id columns get a value from the database
        sampledata.freikarte.id: NOT NULL without default, identity or generated value
            fix: ALTER TABLE sampledata.freikarte ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY;  -- then: SELECT setval(pg_get_serial_sequence('sampledata.freikarte', 'id'), (SELECT max(id) FROM sampledata.freikarte));
        → form-backend omits the id on create → error 23502 (not-null violation)
```

**Review every `fix` statement before running it.** The fixes are suggestions. For example, the `REVOKE` statements in P14a are only correct if anonymous writing really isn't intended.

---

## 4. The checks

### Configuration (only with `--postgrest-conf`)

| ID | Severity | Checks | Symptom when it fails |
|----|----------|--------|----------------------|
| S1 | FAIL | Every `schema` in the form configs is listed in `db-schemas` | `406 PGRST106 Invalid schema` |
| S2 | WARN | `log-level` is `warn`/`info`/`debug` | At the default level `error`, PostgREST doesn't log 401/403 at all |
| S3 | INFO | Shows `jwt-role-claim-key` | Wrong key → the role from the token isn't recognized |

### Roles and login

| ID | Severity | Checks | Symptom |
|----|----------|--------|---------|
| P01 | FAIL | The 3 roles exist; `authenticator` can log in; `formbackend`/`web_anon` can't; none is SUPERUSER/BYPASSRLS; password not expired | `role "…" does not exist`, login fails, RLS bypassed |
| P01b | WARN | `authenticator` has the role attribute `INHERIT`; password expires within 30 days; connection limit set | Hardening, upcoming outage |
| P01c | WARN | (PG ≥ 16) `authenticator` memberships with `INHERIT TRUE` | `authenticator` can act as `formbackend` without `SET ROLE` |
| P02 | FAIL | `authenticator` is a member of `formbackend`/`web_anon` (PG ≥ 16: with `SET`) | `permission denied to set role` |
| P03 | FAIL | `authenticator` has a SCRAM password (superuser) | `password authentication failed` |
| P04 | FAIL | `CONNECT` on the database | `permission denied for database` |
| P05 | WARN | `pg_hba.conf` has no errors, and no `trust`/`password` for remote hosts (superuser) | Login fails, or it's insecure |

**About P01b and P01c.** Since PostgreSQL 16, the role attribute `INHERIT` (`pg_roles.rolinherit`) only sets the default for memberships granted *from then on*. Whether privileges are actually inherited is decided per membership (`pg_auth_members.inherit_option`). An `authenticator` with `rolinherit = true` and old memberships `WITH INHERIT FALSE` doesn't inherit anything. A `GRANT formbackend TO authenticator WITH INHERIT TRUE` does make it inherit, whatever the attribute says. Both cases were reproduced. That's why there are two checks.

### Tables, sequences, defaults

| ID | Severity | Checks | Symptom |
|----|----------|--------|---------|
| P06 | FAIL | Every table from the form configs / `--tables` exists **under exactly this name**. If it only exists in a different case (`myschema.Freikarte` vs. `myschema.freikarte`), P06 reports that, and all other checks still run against the real table | `404 PGRST205`, `Table definition … not found` |
| P07 | FAIL | `USAGE` on the schemas for `formbackend`/`web_anon` | `permission denied for schema` |
| P08 | FAIL | `formbackend`: SELECT/INSERT/UPDATE/DELETE, `web_anon`: SELECT on every form table | `42501 permission denied for table` |
| P09 | FAIL | `formbackend` has `USAGE` on every sequence used in a column default of a form table (`nextval('…'::regclass)` and `nextval('…'::text)`) | `permission denied for sequence` on create |
| P09b | WARN | Any sequence in the schemas without `USAGE` for `formbackend`, which covers triggers and functions that call `nextval()` | `permission denied for sequence` on create |
| P10 | FAIL | SELECT on tables referenced by a foreign key (lookups) | Lookup lists stay empty, `42501`, `PGRST200` |
| P16 | FAIL | Every `idColumn` gets its value from the database: a default, identity or generated column | `23502 null value in column "id" … violates not-null constraint` |
| P16b | WARN | Other NOT NULL columns without a default. Join-table keys (PK and FK at the same time) are excluded, because form-backend fills them | `23502` if the form doesn't send the column |

Identity columns (`GENERATED … AS IDENTITY`) don't show up in P09/P09b: PostgreSQL doesn't check sequence privileges for them. An INSERT as `formbackend` works without `USAGE` (verified). **That makes identity the most robust fix for P16:**

```sql
ALTER TABLE data.freikarte ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY;
SELECT setval(pg_get_serial_sequence('data.freikarte', 'id'), (SELECT max(id) FROM data.freikarte));
NOTIFY pgrst, 'reload schema';
```
Tested: with an existing row `id = 7`, the next insert as `formbackend`, sent without an `id`, gets `id = 8`. `ALTER TABLE` needs the table owner or a superuser.

P16 skips tables that have an enabled `BEFORE INSERT … FOR EACH ROW` trigger: the trigger is assumed to set the `id`. Its sequence is checked by P09b.

**Checking a single table**, e.g. the one a customer reports:
```bash
./scripts/check-db-permissions.sh -d geodb --schemas myschema --tables myschema.freikarte
# id column not the primary key and no form config available:
./scripts/check-db-permissions.sh -d geodb --schemas myschema --tables myschema.freikarte --id-columns myschema.freikarte.fid
```
For that table, P08 (grants), P09 (sequences in all of its column defaults), P10 (lookups), P12 (RLS), P16/P16b (id and NOT NULL columns) and P17 all run. P09b, P13 and P14 always cover the whole schema. The option is `--tables` (plural), and several tables are separated by commas. The table name is case-sensitive, see P06.

### Healthcheck, RLS, defaults for new tables

| ID | Severity | Checks | Symptom |
|----|----------|--------|---------|
| P11 | FAIL | Healthcheck table exists; `formbackend` has SELECT and UPDATE on it | form-backend exits at startup: `Insufficient privileges for role formbackend` |
| P11b | FAIL | Row `id = 1` exists (superuser) | Startup PATCH matches 0 rows and **passes anyway** |
| P12 | FAIL | No table with RLS enabled but no policy for the role | **No error**: 0 rows, PATCH/DELETE have no effect |
| P13 | WARN | Table owners in the schemas have `ALTER DEFAULT PRIVILEGES` for `formbackend` | The next table that owner creates is invisible |

### Over-privilege (hardening)

| ID | Severity | Checks |
|----|----------|--------|
| P14a | WARN | `web_anon` has INSERT/UPDATE/DELETE/TRUNCATE on objects in the schemas |
| P14b | WARN | `authenticator`/`formbackend`/`web_anon` have `CREATE` on a schema |
| P14c | WARN | API roles own objects; privileges granted to `PUBLIC`; `authenticator` has direct privileges |
| P15 | INFO | Role-level settings (`statement_timeout`, `search_path`, …) |

### Real statement path (superuser)

| ID | Severity | Checks |
|----|----------|--------|
| P17 | FAIL | Runs `EXPLAIN SELECT/INSERT/UPDATE/DELETE` as `formbackend` and as `web_anon` against every form table, and reports deviations from the expected state: `formbackend` may do everything, `web_anon` may only SELECT. This also catches **views whose owner lacks privileges on the base table**, which P08 can't see. Example: `sampledata.v_fountains / formbackend SELECT: denied: permission denied for table fountains` |

### PostgREST over HTTP (only with `--postgrest-url`; GET requests only)

| ID | Severity | Checks |
|----|----------|--------|
| H1 | FAIL | `GET /` (OpenAPI) for each schema answers; reports how many tables `web_anon` can see |
| H2 | FAIL | Keycloak issues a service token (client credentials), and it carries `resource_access.<client>.roles[0] = formbackend` |
| H3 | FAIL | Every form table can be read with that token: `GET /<table>?limit=1` with `Accept-Profile` |

Example (copy with injected faults):
```
PASS  H1    PostgREST OpenAPI for schema sampledata (11 tables visible as web_anon)
PASS  H2    service token carries role formbackend
FAIL  H3    form tables readable via PostgREST as formbackend
        other.spielplaetze: HTTP 406 {"code":"PGRST106",…,"message":"Invalid schema: other"}
        sampledata.fountain_types: HTTP 403 {"code":"42501",…,"message":"permission denied for table fountain_types"}
        sampledata.v_fountains: HTTP 403 {"code":"42501",…,"message":"permission denied for table fountains"}
```
With a wrong client secret:
```
FAIL  H2    service token from Keycloak (postgrest-client)
        Invalid client or Invalid client credentials
```

---

## 5. Example: full run against the faulty copy

Superuser, `--postgrest-conf`, `--form-configs` and `--postgrest-url` (output shortened; the H checks are shown in section 4):

```
FAIL  S1    form config schemas exposed in PostgREST db-schemas
        used in form configs but not in db-schemas: other
PASS  S2    PostgREST log-level logs 4xx (log-level=warn)
WARN  P01b  role hardening (inherit, expiry, connection limit)
        authenticator: role attribute INHERIT is on (PG ≥ 16: applies to memberships granted from now on; see P01c)
WARN  P01c  authenticator memberships do not inherit privileges
FAIL  P06   tables used by form-backend exist
        other.spielplaetze: table does not exist
FAIL  P08   table privileges (formbackend: CRUD, web_anon: SELECT)
        sampledata.fountain_types / formbackend: missing SELECT
            fix: GRANT SELECT ON sampledata.fountain_types TO formbackend;
FAIL  P09   sequences behind column defaults usable by formbackend
        sampledata.freikarte_logo → sampledata.freikarte_logo_seq: no USAGE on sequence
            fix: GRANT USAGE, SELECT ON SEQUENCE sampledata.freikarte_logo_seq TO formbackend;
WARN  P09b  all sequences in the schemas usable by formbackend (triggers/functions)
        sampledata.freikarte_stadt_seq: no USAGE on sequence
FAIL  P11b  healthcheck row id = 1 exists
        sampledata.__form_backend_healthcheck: row id = 1 missing
FAIL  P12   no RLS without a policy for formbackend / web_anon
        sampledata.inspections / formbackend: RLS enabled, no policy applies to the role
WARN  P14a  web_anon cannot write
        sampledata.freikarte: web_anon has INSERT
            fix: REVOKE INSERT ON sampledata.freikarte FROM web_anon;
WARN  P14b  API roles cannot CREATE in the schemas
        sampledata / web_anon: has CREATE on schema
FAIL  P16   id columns get a value from the database
        sampledata.freikarte.id: NOT NULL without default, identity or generated value
WARN  P16b  NOT NULL columns without default (must be filled by the form)
        sampledata.freikarte.altersgruppe: NOT NULL without default
FAIL  P17   real statement path (EXPLAIN as formbackend / web_anon)
        sampledata.v_fountains / formbackend SELECT: denied: permission denied for table fountains
        sampledata.freikarte / web_anon INSERT: allowed, should be denied

summary: PASS=12 FAIL=10 ERROR=0 WARN=7 SKIP=0 INFO=1
```

The same copy as the non-superuser `authenticator`: identical results, except `P03`, `P05`, `P11b` and `P17`, which are `SKIP`.

When a check can't run at all, it's logged as `ERROR` with the PostgreSQL message. Example: a typo in a role name.
```
FAIL  P01   roles exist with the right attributes
        formbackendd: role does not exist
ERROR P07   schema USAGE for formbackendd / web_anon
        check could not run: psql:<stdin>:5: ERROR:  role "formbackendd" does not exist
```

---

## 6. Logs and reloads on a native installation

| What | Where / how |
|------|-------------|
| PostgreSQL log | `SHOW log_directory;` (relative to `SHOW data_directory;`), or `journalctl -u postgresql`. Look for `grep -A1 'permission denied\|violates not-null'`. The log shows the statement, but always the session user `authenticator`, not the role it switched to |
| PostgREST log | `journalctl -u postgrest` (depending on the unit name). Only with `log-level = "warn"` (or higher) are 4xx responses logged with their role, e.g. `… - web_anon [...] "GET /… HTTP/1.1" 401 …` |
| form-backend log | depends on the service (`journalctl -u form-backend`); look for `Insufficient`, `swagger`, `postgrest jwt` |
| PostgREST schema cache after DDL (new table/column/FK) | `NOTIFY pgrst, 'reload schema';` in the database. Until then: `404 PGRST205` |
| `GRANT` / `REVOKE` | take effect immediately, no reload needed |
| `pg_hba.conf` changes | `SELECT pg_reload_conf();` |
| PostgREST config changes | restart PostgREST (`systemctl restart postgrest`) |

---

## 7. Limitations

- Table and schema names containing `.` or characters that need quoting aren't supported in `--tables`/`--schemas`.
- If several tables differ only in case (`freikarte` and `"FREIKARTE"`), there's no case-insensitive fallback. P06 then reports "does not exist", and you need to give the exact name.
- On PostgreSQL < 16, P02 only checks membership (there's no `SET` option), and P01c is skipped.
- P09b also lists sequences that no form uses. Use the `owned_by`/object name to judge whether one matters.
- P16 assumes that a `BEFORE INSERT` row trigger sets the `id`. It doesn't verify that.
- The HTTP checks read tables of the form configs with the service token. They never write, so they can't test INSERT, UPDATE or DELETE end to end. P08/P09/P16/P17 cover that at the database level.
- form-backend's own environment (`POSTGREST_DEFAULT_SCHEMA`, Keycloak settings) depends on how it's deployed. Pass it to the script as `--default-schema` and the `KC_*` variables.
