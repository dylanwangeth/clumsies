#!/bin/sh
set -eu

[ "$#" -eq 4 ] || exit 64
compose_env=$1
server_binary=$2
server_address=$3
ready_file=$4

[ -f "$compose_env" ] && [ ! -L "$compose_env" ] \
  && [ -x "$server_binary" ] || exit 66
case "$ready_file" in /*) ;; *) exit 64 ;; esac
case "$server_address" in 127.0.0.1:*) ;; *) exit 64 ;; esac

env_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1) }' "$compose_env"
}

database_port=$(env_value CLUMSIES_DB_PORT)
oidc_port=$(env_value CLUMSIES_OIDC_PORT)
database_password=$(env_value CLUMSIES_DB_PASSWORD)
setup_code=$(env_value CLUMSIES_SETUP_CODE)
server_port=${server_address##*:}
case "$database_port:$oidc_port:$server_port" in
  *[!0-9:]*) exit 65 ;;
esac
[ -n "$database_port" ] && [ "$database_port" -ge 1 ] && [ "$database_port" -le 65535 ] \
  && [ -n "$oidc_port" ] && [ "$oidc_port" -ge 1 ] && [ "$oidc_port" -le 65535 ] \
  && [ -n "$server_port" ] && [ "$server_port" -le 65535 ] || exit 65
case "$database_password:$setup_code" in
  *[!0-9a-f:]*) exit 65 ;;
esac
[ "${#database_password}" -eq 48 ] && [ "${#setup_code}" -eq 48 ] || exit 65

exec env \
  DATABASE_URL="postgres://clumsies:$database_password@127.0.0.1:$database_port/clumsies" \
  CLUMSIES_SERVER_ADDR="$server_address" \
  CLUMSIES_PUBLIC_ORIGIN=auto \
  CLUMSIES_SERVER_READY_FILE="$ready_file" \
  CLUMSIES_SETUP_CODE="$setup_code" \
  CLUMSIES_OIDC_CLIENT_ID=clumsies-local \
  CLUMSIES_OIDC_CLIENT_SECRET=clumsies-local-secret \
  CLUMSIES_OIDC_ISSUER="http://127.0.0.1:$oidc_port/clumsies" \
  CLUMSIES_CLIENT_REDIRECT_URIS=http://127.0.0.1/callback \
  "$server_binary"
