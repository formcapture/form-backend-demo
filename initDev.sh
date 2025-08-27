#!/bin/bash
set -euo pipefail
# remove existing .env file if it exists
if [ -f .env ]; then
  echo "Remove existing .env file to initialize the project again."
  exit 0
fi

# Copy env.example to .env if it does not exist
if [ ! -f .env ]; then
  cp .env.example .env
fi

HOST_IP=$(ip route get 1 | awk '{gsub("^.*src ",""); print $1; exit}')
sed -i -E "s/HOST_IP=(.+)/HOST_IP=${HOST_IP}/" .env

sed -i -E "s/POSTGRES_PASSWORD=(.+)/POSTGRES_PASSWORD=$(pwgen 19 1 -s)/" .env
sed -i -E "s/KEYCLOAK_PASSWORD=(.+)/KEYCLOAK_PASSWORD=$(pwgen 19 1 -s)/" .env

PGRST_DB_PASSWORD=$(pwgen 29 1 -s)
sed -i -E "s/PGRST_DB_PASSWORD=(.+)/PGRST_DB_PASSWORD=${PGRST_DB_PASSWORD}/" .env

# Parse --form-backend-base parameter or prompt if not provided
FORMCAPTURE_BASE_DIR=""
for arg in "$@"; do
  case $arg in
    --form-backend-base=*)
      FORMCAPTURE_BASE_DIR="${arg#*=}"
      shift
      ;;
  esac
done

if [ -z "$FORMCAPTURE_BASE_DIR" ]; then
  read -p "Enter the base directory of formcapture form-backend: " FORMCAPTURE_BASE_DIR
fi

sed -i -E "s/FORMCAPTURE_BASE_DIR=(.+)/FORMCAPTURE_BASE_DIR=$(echo $FORMCAPTURE_BASE_DIR | sed 's_/_\\/_g')/" .env

# load predefined environment variables from .env file
ENV_FILE=".env"
set -o allexport
source "$ENV_FILE"
set +o allexport

docker compose up -d

sleep 2

echo "Waiting for keycloak to become healthy 😴..."
until docker compose ps | grep keycloak | grep -q "(healthy)"; do
  sleep 5
  echo "Waiting 5 sec for keycloak health check ⏱️..."
  if ! docker compose ps | grep nginx | grep -q "Up"; then
    echo "nginx is not running. Starting nginx with docker compose..."
    docker compose up -d nginx
  fi
done

echo "Getting jwt secret..."
LOADED_PGRST_JWT_SECRET=$(curl --cacert $(pwd)/nginx/certs/rootCA.pem https://auth.${HOSTNAME}/auth/realms/masterportal/protocol/openid-connect/certs)
LOADED_PGRST_JWT_SECRET_ESCAPED=$(echo ${LOADED_PGRST_JWT_SECRET} | sed 's/"/\\"/g')
echo "# The secret for verifying the jwt token. Can be taken from auth//realms/masterportal/protocol/openid-connect/certs"
sed -i '/^PGRST_JWT_SECRET/d' .env
echo "PGRST_JWT_SECRET=\"${LOADED_PGRST_JWT_SECRET_ESCAPED}\"" >> .env

echo "Getting keycloak public key..."
KEYCLOAK_PUBLIC_KEY=$(curl --cacert $(pwd)/nginx/certs/rootCA.pem https://auth.${HOSTNAME}/auth/realms/masterportal | jq '.public_key')
echo "# The public key ${KEYCLOAK_PUBLIC_KEY} of the keycloak realm. Can be taken from /auth/realms/masterportal"
sed -i '/^KEYCLOAK_PUBLIC_KEY/d' .env
echo "KEYCLOAK_PUBLIC_KEY=${KEYCLOAK_PUBLIC_KEY}" >> .env

echo "Getting client secret of postgrest client..."
echo "[*] Authenticating as admin (${KEYCLOAK_USER})..."
ADMIN_TOKEN=$(curl --cacert $(pwd)/nginx/certs/rootCA.pem -s -X POST "https://auth.${HOSTNAME}/auth/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_USER}" \
  -d "password=${KEYCLOAK_PASSWORD}" \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli' | jq -r '.access_token')

if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  echo "[!] Error: Could not fetch access token."
  exit 1
fi

echo "[*] Searching for client ID of '$PGRST_KEYCLOAK_CLIENT_ID' in realm '$KEYCLOAK_REALM'..."
CLIENT_UUID=$(curl --cacert $(pwd)/nginx/certs/rootCA.pem -s -X GET "https://auth.${HOSTNAME}/auth/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${PGRST_KEYCLOAK_CLIENT_ID}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.[0].id')

if [[ -z "$CLIENT_UUID" || "$CLIENT_UUID" == "null" ]]; then
  echo "[!] Error: Client '$PGRST_KEYCLOAK_CLIENT_ID' not found in realm '$KEYCLOAK_REALM'."
  exit 2
fi

echo "[+] Client-UUID: $CLIENT_UUID"

echo "[*] Load secret for client '$PGRST_KEYCLOAK_CLIENT_ID'..."
CLIENT_SECRET=$(curl --cacert $(pwd)/nginx/certs/rootCA.pem -s -X GET "https://auth.${HOSTNAME}/auth/admin/realms/${KEYCLOAK_REALM}/clients/${CLIENT_UUID}/client-secret" \
  -H "Authorization: Bearer $ADMIN_TOKEN" | jq -r '.value')

if [[ -z "$CLIENT_SECRET" || "$CLIENT_SECRET" == "null" ]]; then
  echo "[!] Error: Could not load secret for client."
  exit 3
fi

LOADED_PGRST_CLIENT_SECRET_ESCAPED=$(echo ${CLIENT_SECRET} | sed 's/"/\\"/g')
sed -i -E "s/PGRST_KEYCLOAK_CLIENT_SECRET=(.+)/PGRST_KEYCLOAK_CLIENT_SECRET=${LOADED_PGRST_CLIENT_SECRET_ESCAPED}/" .env

echo "Setting up authenticator user in postgres 🔑 ..."
ESCAPED_PGRST_PASSWORD=$(printf '%s' "$PGRST_DB_PASSWORD" | sed "s/'/''/g")
docker compose exec db psql -U postgres -c "ALTER USER authenticator WITH PASSWORD '${ESCAPED_PGRST_PASSWORD}';"

echo "Run migrations..."
for sql_file in postgres/migrations/*.sql; do
  echo "Running migration: $(basename $sql_file)"
  docker compose exec db psql -U postgres -f "/migrations/$(basename $sql_file)"
done

docker compose down
echo "Project initialized successfully! 🎉"
