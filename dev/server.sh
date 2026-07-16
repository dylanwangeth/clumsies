#!/bin/sh
set -eu

export CLUMSIES_DB_NAME=clumsies
export CLUMSIES_DB_USER=clumsies
export CLUMSIES_DB_PASSWORD=clumsies
export CLUMSIES_DB_PORT=5432

docker compose up -d --wait postgres fake-oidc

exec env \
  DATABASE_URL=postgres://clumsies:clumsies@127.0.0.1:5432/clumsies \
  CLUMSIES_SERVER_ADDR=127.0.0.1:18080 \
  CLUMSIES_BOOTSTRAP_ORG_NAME="Clumsies Lab" \
  CLUMSIES_BOOTSTRAP_OWNER_EMAIL=owner@clumsies.local \
  CLUMSIES_BOOTSTRAP_OWNER_NAME="Local Owner" \
  CLUMSIES_BOOTSTRAP_PROJECT_NAME=Default \
  CLUMSIES_OIDC_CLIENT_ID=clumsies-local \
  CLUMSIES_OIDC_CLIENT_SECRET=clumsies-local-secret \
  CLUMSIES_OIDC_CALLBACK_URL=http://127.0.0.1:18080/login/oauth2/code/oidc \
  CLUMSIES_OIDC_ISSUER=http://127.0.0.1:18081/clumsies \
  CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback \
  CLUMSIES_CORS_ORIGINS=http://127.0.0.1:1420,http://localhost:1420 \
  cargo run -p server --bin clumsies-server
