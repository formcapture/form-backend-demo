# Debugging Connection Between Components

This guide helps you verify and troubleshoot the connections between the services in the form-backend-demo stack.

## Quick Overview of the Architecture

```
Browser → nginx → form-backend → postgrest → postgres (db)
                ↘ keycloak → keycloak-db (postgres-keycloak)
```

---

## 1. Test Connection: PostgREST → PostgreSQL (`db`)

PostgREST connects to the `db` container using the `authenticator` role.

**Check PostgREST logs for DB connection errors:**
```bash
docker compose logs postgrest
```

**Connect to the `db` container directly and verify the `authenticator` role exists:**
```bash
docker compose exec db psql -U postgres -c "\du"
```

**Test the exact connection PostgREST uses (from inside the `db` container):**
```bash
docker compose exec db psql "postgres://authenticator:${PGRST_DB_PASSWORD}@localhost:5432/postgres" -c "SELECT current_user;"
```

**Verify the required schemas and roles are in place:**
```bash
docker compose exec db psql -U postgres -c "\dn"
docker compose exec db psql -U postgres -c "SELECT grantee, table_schema, privilege_type FROM information_schema.role_table_grants WHERE grantee IN ('web_anon', 'formbackend', 'authenticator');"
```

**Hit the PostgREST health endpoint from within the network:**
```bash
docker compose exec form-backend wget -qO- http://postgrest:3000/
```

---

## 2. Test Connection: form-backend → PostgREST

form-backend calls PostgREST at `http://postgrest:3000`.

**Check form-backend logs:**
```bash
docker compose logs form-backend
```

**Test PostgREST reachability from within the form-backend container:**
```bash
docker compose exec form-backend wget -qO- http://postgrest:3000/
```

**Fetch a JWT from Keycloak using the `postgrest-client` credentials and call PostgREST with it:**

> All commands run inside the `form-backend` container, which has access to both Keycloak and
> PostgREST on the internal Docker network. The container provides `wget` and `node` for HTTP
> requests and JSON parsing — `curl` and `python3` are not available in this image.

```bash
docker compose exec form-backend sh -c '
TOKEN=$(wget -qO- \
  --post-data "client_id=postgrest-client&client_secret=${PGRST_KEYCLOAK_CLIENT_SECRET}&grant_type=client_credentials" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")).access_token)")

wget -qO- \
  --header "Authorization: Bearer $TOKEN" \
  http://postgrest:3000/fountains \
  | node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")); console.log(\"Rows returned:\", d.length)"
'
# Expected: "Rows returned: <N>" — confirms the full Keycloak → PostgREST auth chain works
```

**Verify the `POSTGREST_URL` env variable is set correctly inside the container:**
```bash
docker compose exec form-backend env | grep POSTGREST
```

---

## 3. Test Keycloak Connection and Client Secrets

Keycloak runs at `http://keycloak:8080/auth` (internal) and `https://auth.<HOSTNAME>/auth` (external via nginx).

> **Note:** The keycloak container image does not include `curl` or `wget`. All commands below
> that call the Keycloak API therefore run from inside the `form-backend` container, which is on
> the same Docker network and provides `wget` and `node`.

### Check Keycloak is healthy

**From the `form-backend` container (recommended):**
```bash
docker compose exec form-backend wget -qO- http://keycloak:9000/auth/health/live
# Expected: {"status":"UP","checks":[]}
```

**Using the Java healthcheck built into the keycloak container:**
```bash
docker compose exec keycloak sh -c '
[ -f /tmp/HealthCheck.java ] || echo "public class HealthCheck { public static void main(String[] args) throws java.lang.Throwable { java.net.URI uri = java.net.URI.create(args[0]); System.exit(java.net.HttpURLConnection.HTTP_OK == ((java.net.HttpURLConnection)uri.toURL().openConnection()).getResponseCode() ? 0 : 1); } }" > /tmp/HealthCheck.java
java /tmp/HealthCheck.java http://localhost:9000/auth/health/live && echo "healthy"'
```

**From the host (requires nginx running and SSL trust configured):**
```bash
curl -s https://auth.${HOSTNAME}/auth/health/live
```

### Verify the realm exists and get the public key

```bash
docker compose exec form-backend sh -c '
wget -qO- "http://keycloak:8080/auth/realms/${KEYCLOAK_REALM}" \
  | node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")); console.log(\"realm:\", d.realm); console.log(\"public_key:\", d.public_key?.substring(0,40)+\"...\")"
'
```

### Obtain an admin access token

```bash
docker compose exec form-backend sh -c '
ADMIN_TOKEN=$(wget -qO- \
  --post-data "client_id=admin-cli&username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/master/protocol/openid-connect/token" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")).access_token)")
echo "Admin token acquired: ${ADMIN_TOKEN:0:20}..."
'
```

### List clients in the realm

```bash
docker compose exec form-backend sh -c '
ADMIN_TOKEN=$(wget -qO- \
  --post-data "client_id=admin-cli&username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/master/protocol/openid-connect/token" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")).access_token)")

wget -qO- \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  "http://keycloak:8080/auth/admin/realms/${KEYCLOAK_REALM}/clients" \
  | node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")); d.forEach(c=>console.log(c.clientId))"
'
```

### Get the `postgrest-client` secret

```bash
docker compose exec form-backend sh -c '
ADMIN_TOKEN=$(wget -qO- \
  --post-data "client_id=admin-cli&username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/master/protocol/openid-connect/token" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")).access_token)")

CLIENT_UUID=$(wget -qO- \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  "http://keycloak:8080/auth/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${PGRST_KEYCLOAK_CLIENT_ID}" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\"))[0].id)")

wget -qO- \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  "http://keycloak:8080/auth/admin/realms/${KEYCLOAK_REALM}/clients/$CLIENT_UUID/client-secret"
# Expected: {"type":"secret","value":"<the secret>"}
'
```

### Get the `form-backend-app` client info

> **Note:** `form-backend-app` is a public client and does not have a client secret.
> The API returns `{"type":"secret"}` with no `value` field — this is expected.

```bash
docker compose exec form-backend sh -c '
ADMIN_TOKEN=$(wget -qO- \
  --post-data "client_id=admin-cli&username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/master/protocol/openid-connect/token" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")).access_token)")

FB_CLIENT_UUID=$(wget -qO- \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  "http://keycloak:8080/auth/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${CLIENT_APP_ID}" \
  | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\"))[0].id)")

wget -qO- \
  --header "Authorization: Bearer $ADMIN_TOKEN" \
  "http://keycloak:8080/auth/admin/realms/${KEYCLOAK_REALM}/clients/$FB_CLIENT_UUID/client-secret"
'
```

### Test the `postgrest-client` credentials directly

```bash
docker compose exec form-backend wget -qO- \
  --post-data "client_id=${PGRST_KEYCLOAK_CLIENT_ID}&client_secret=${PGRST_KEYCLOAK_CLIENT_SECRET}&grant_type=client_credentials" \
  --header "Content-Type: application/x-www-form-urlencoded" \
  "http://keycloak:8080/auth/realms/${KEYCLOAK_REALM}/protocol/openid-connect/token" \
  | node -e "const d=JSON.parse(require(\'fs\').readFileSync(\'/dev/stdin\',\'utf8\')); console.log(\'token_type:\', d.token_type); console.log(\'expires_in:\', d.expires_in); console.log(\'access_token:\', d.access_token ? d.access_token.substring(0,30)+\'...\' : \'ERROR: \'+d.error_description)"
# Expected: token_type: Bearer, expires_in: 300, access_token: <JWT prefix>...
```

### Check Keycloak logs

```bash
docker compose logs keycloak
```

## 4. Common Mistakes and Troubleshooting Steps

### Stack not starting or containers restarting

```bash
# Check status of all containers
docker compose ps

# Check logs of a specific failing container
docker compose logs <service-name>
```

**Common causes:**
- `.env` file missing — run `./initDev.sh` or copy `.env.example` to `.env` and fill in the values.
- `PGRST_DB_PASSWORD` in `.env` does not match the password set for the `authenticator` role in Postgres.
- `PGRST_JWT_SECRET` is empty — PostgREST requires a JWT secret to validate tokens from Keycloak. Set it to the realm's public key or a shared secret.

### Keycloak fails to start

- **DB not ready:** Keycloak depends on `keycloak-db`. Check `docker compose logs keycloak-db`.
- **Realm import fails:** Ensure `keycloak/init_data/keycloak_masterportal_realm.json` is valid JSON and the volume is mounted correctly.
- **Port conflicts:** Check that ports 80/443 are not already in use on the host.

### PostgREST returns `Connection refused` or `role does not exist`

1. Ensure `db` is healthy before starting `postgrest`: `docker compose ps db`
2. Verify the init SQL ran: `docker compose exec db psql -U postgres -c "\du"` — `authenticator`, `web_anon`, and `formbackend` roles must exist.
3. If the `db` data volume already exists from a previous run without those roles, remove it and restart:
   ```bash
   docker compose down
   sudo rm -rf postgres/data
   docker compose up -d
   ```

### form-backend cannot reach Keycloak

- Inside the stack, form-backend uses `http://keycloak:8080/auth`. Verify this is reachable:
  ```bash
  docker compose exec form-backend wget -qO- http://keycloak:8080/auth/health/live
  ```
- `KEYCLOAK_PUBLIC_KEY` in `.env` must match the realm's RSA public key. Retrieve it from:
  ```bash
  docker compose exec form-backend sh -c 'wget -qO- "http://keycloak:8080/auth/realms/${KEYCLOAK_REALM}" | node -e "const d=JSON.parse(require(\"fs\").readFileSync(\"/dev/stdin\",\"utf8\")); console.log(d.public_key)"'
  ```
  Then set `KEYCLOAK_PUBLIC_KEY=<value>` in `.env` and restart form-backend:
  ```bash
  docker compose restart form-backend
  ```

### SSL / certificate errors on the host

- Trust the local root CA (dev setup only):
  ```bash
  sudo cp ./nginx/certs/rootCA.pem /usr/local/share/ca-certificates/rootCA.crt
  sudo update-ca-certificates
  ```
- Add hostnames to `/etc/hosts`:
  ```
  127.0.0.1  auth.form-backend.local
  127.0.0.1  app.form-backend.local
  ```

### Uploads directory permission denied

```bash
chmod -R 777 form-backend/uploads
```

### Full reset (start from scratch)

```bash
docker compose down --remove-orphans
sudo rm -rf postgres/data postgres-keycloak/data .env
./initDev.sh
docker compose up -d
```
