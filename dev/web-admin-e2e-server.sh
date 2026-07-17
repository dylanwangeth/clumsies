#!/bin/sh
set -eu

compose_project=clumsies-web-admin-e2e
server_pid=

export CLUMSIES_DB_NAME=clumsies
export CLUMSIES_DB_USER=clumsies
export CLUMSIES_DB_PASSWORD=clumsies-e2e
export CLUMSIES_DB_PORT=55432
export CLUMSIES_OIDC_PORT=18091

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  docker compose -p "$compose_project" down -v --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

docker compose -p "$compose_project" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -p "$compose_project" up -d --wait postgres fake-oidc

env \
  DATABASE_URL=postgres://clumsies:clumsies-e2e@127.0.0.1:55432/clumsies \
  CLUMSIES_SERVER_ADDR=127.0.0.1:18090 \
  CLUMSIES_PUBLIC_ORIGIN=http://127.0.0.1:18090 \
  CLUMSIES_SETUP_CODE=clumsies-web-admin-e2e-setup-code \
  CLUMSIES_OIDC_CLIENT_ID=clumsies-local \
  CLUMSIES_OIDC_CLIENT_SECRET=clumsies-local-secret \
  CLUMSIES_OIDC_ISSUER=http://127.0.0.1:18091/clumsies \
  CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1:1423/admin/setup/callback,http://127.0.0.1:1423/admin/ \
  CLUMSIES_CORS_ORIGINS=http://127.0.0.1:1423 \
  cargo run -p server --bin clumsies-server &
server_pid=$!

wait "$server_pid"
