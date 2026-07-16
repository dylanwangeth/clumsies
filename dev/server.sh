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
  CLUMSIES_SETUP_CODE=clumsies-local-setup-code-00000001 \
  CLUMSIES_OIDC_CLIENT_ID=clumsies-local \
  CLUMSIES_OIDC_CLIENT_SECRET=clumsies-local-secret \
  CLUMSIES_OIDC_CALLBACK_URL=http://127.0.0.1:18080/login/oauth2/code/oidc \
  CLUMSIES_OIDC_ISSUER=http://127.0.0.1:18081/clumsies \
  CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback,http://127.0.0.1/admin/setup/callback,http://127.0.0.1:1421/admin/ \
  CLUMSIES_CORS_ORIGINS=http://127.0.0.1:1420,http://localhost:1420,http://127.0.0.1:1421,http://localhost:1421 \
  cargo run -p server --bin clumsies-server
