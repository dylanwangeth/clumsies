#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

readonly CLUMSIES_ROOT="${CLUMSIES_ROOT:-/opt/clumsies}"
readonly COMPOSE_FILE="$CLUMSIES_ROOT/compose.production.yml"
readonly ENV_FILE="$CLUMSIES_ROOT/.env"
readonly BACKUP_DIR="$CLUMSIES_ROOT/backups"
readonly RELEASE_DIR="$CLUMSIES_ROOT/releases"
readonly IMAGE_PREFIX="ghcr.io/lilhammerfun/clumsies-server"
readonly LOCK_FILE="/run/lock/clumsies-server-release.lock"

log() {
  printf '[clumsies-release] %s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "this command must run as root"
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock --nonblock 9 || die "another release or backup operation is active"
}

compose() {
  (
    cd "$CLUMSIES_ROOT"
    docker compose --project-name clumsies --file "$COMPOSE_FILE" "$@"
  )
}

read_env_value() {
  local key="$1"
  awk -v key="$key" '
    index($0, key "=") == 1 {
      sub(/^[^=]*=/, "")
      print
      exit
    }
  ' "$ENV_FILE"
}

current_container_image() {
  local container

  container="$(docker ps --all \
    --filter label=com.docker.compose.project=clumsies \
    --filter label=com.docker.compose.service=server \
    --format '{{.ID}}' | sed -n '1p')"
  [[ -n "$container" ]] || return 0
  docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null || true
}

current_image() {
  local image
  image="$(read_env_value CLUMSIES_SERVER_IMAGE)"
  if [[ -z "$image" ]]; then
    image="$(current_container_image)"
  fi
  [[ -n "$image" ]] || die "CLUMSIES_SERVER_IMAGE is unset and no Server container exists"
  printf '%s\n' "$image"
}

write_image_setting() {
  local image="$1"
  local temp

  [[ -n "$image" && "$image" != *$'\n'* && "$image" != *$'\r'* ]] ||
    die "invalid image setting"

  temp="$(mktemp "$CLUMSIES_ROOT/.env.image.XXXXXX")"
  awk -v image="$image" '
    BEGIN { replaced = 0 }
    /^CLUMSIES_SERVER_IMAGE=/ {
      if (!replaced) {
        print "CLUMSIES_SERVER_IMAGE=" image
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print "CLUMSIES_SERVER_IMAGE=" image
      }
    }
  ' "$ENV_FILE" >"$temp"
  chmod --reference="$ENV_FILE" "$temp"
  chown --reference="$ENV_FILE" "$temp"
  mv "$temp" "$ENV_FILE"
}

ensure_image_setting() {
  if [[ -z "$(read_env_value CLUMSIES_SERVER_IMAGE)" ]]; then
    write_image_setting "$(current_image)"
  fi
}

write_runtime_configuration() {
  local origin="$1"
  local redirects="$2"
  local temp

  validate_public_origin "$origin"
  [[ "$redirects" != *$'\n'* && "$redirects" != *$'\r'* ]] ||
    die "invalid client redirect URI setting"

  temp="$(mktemp "$CLUMSIES_ROOT/.env.runtime.XXXXXX")"
  awk -v origin="$origin" -v redirects="$redirects" '
    BEGIN { origin_replaced = 0; redirects_replaced = 0 }
    /^CLUMSIES_PUBLIC_ORIGIN=/ {
      if (!origin_replaced) {
        print "CLUMSIES_PUBLIC_ORIGIN=" origin
        origin_replaced = 1
      }
      next
    }
    /^CLUMSIES_CLIENT_REDIRECT_URIS=/ {
      if (!redirects_replaced) {
        print "CLUMSIES_CLIENT_REDIRECT_URIS=" redirects
        redirects_replaced = 1
      }
      next
    }
    { print }
    END {
      if (!origin_replaced) {
        print "CLUMSIES_PUBLIC_ORIGIN=" origin
      }
      if (!redirects_replaced) {
        print "CLUMSIES_CLIENT_REDIRECT_URIS=" redirects
      }
    }
  ' "$ENV_FILE" >"$temp"
  chmod --reference="$ENV_FILE" "$temp"
  chown --reference="$ENV_FILE" "$temp"
  mv "$temp" "$ENV_FILE"
}

require_environment() {
  local compose_version

  [[ -f "$COMPOSE_FILE" ]] || die "missing $COMPOSE_FILE"
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
  compose_version="$(docker compose version --short 2>/dev/null || true)"
  [[ "${compose_version%%.*}" == "2" ]] ||
    die "Docker Compose v2 is required; found ${compose_version:-none}"

  install -d -m 0700 "$BACKUP_DIR" "$RELEASE_DIR"
  ensure_image_setting
}

validate_target() {
  local image="$1"
  local commit="$2"
  local digest

  digest="${image#"$IMAGE_PREFIX@sha256:"}"
  [[ "$image" == "$IMAGE_PREFIX@sha256:$digest" && "$digest" =~ ^[a-f0-9]{64}$ ]] ||
    die "image must be an immutable ${IMAGE_PREFIX}@sha256 reference"
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] ||
    die "commit must contain 40 lowercase hexadecimal characters"
}

validate_public_origin() {
  local origin="$1"

  [[ "$origin" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] ||
    die "CLUMSIES_PUBLIC_ORIGIN must be an HTTPS origin without a path"
}

public_origin() {
  local origin

  origin="$(read_env_value CLUMSIES_PUBLIC_ORIGIN)"
  validate_public_origin "$origin"
  printf '%s\n' "$origin"
}

wait_public_health() {
  local attempts="${1:-30}"
  local origin="${2:-}"
  local attempt

  if [[ -z "$origin" ]]; then
    origin="$(public_origin)"
  else
    validate_public_origin "$origin"
  fi
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if curl --fail --silent --show-error --max-time 8 \
      "$origin/api/v1/admin/health" >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

prune_scheduled_backups() {
  local retention_days="${CLUMSIES_BACKUP_RETENTION_DAYS:-14}"

  [[ "$retention_days" =~ ^[0-9]+$ ]] || die "invalid backup retention"
  find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name 'scheduled-*.dump' -o -name 'scheduled-*.dump.sha256' \) \
    -mtime "+$retention_days" -delete
}

backup_database() {
  local reason="$1"
  local timestamp
  local backup
  local temp
  local size

  [[ "$reason" =~ ^[a-z0-9-]+$ ]] || die "invalid backup reason"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$BACKUP_DIR/${reason}-${timestamp}.dump"
  temp="$BACKUP_DIR/.${reason}-${timestamp}.dump.tmp"

  log "creating PostgreSQL backup: $backup"
  # POSTGRES_USER and POSTGRES_DB are expanded inside the Postgres container.
  # shellcheck disable=SC2016
  if ! compose exec -T postgres sh -c \
    'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' >"$temp"; then
    rm -f "$temp"
    die "pg_dump failed"
  fi

  size="$(stat -c %s "$temp")"
  if ((size < 1024)); then
    rm -f "$temp"
    die "database backup is unexpectedly small"
  fi

  if ! compose exec -T postgres sh -c 'pg_restore --list >/dev/null' <"$temp"; then
    rm -f "$temp"
    die "pg_restore could not read the new backup"
  fi

  mv "$temp" "$backup"
  sha256sum "$backup" >"$backup.sha256"
  if [[ "$reason" == scheduled ]]; then
    prune_scheduled_backups
  fi
  printf '%s\n' "$backup"
}

record_release() {
  local status="$1"
  local timestamp="$2"
  local commit="$3"
  local image="$4"
  local previous_image="$5"
  local backup="$6"
  local record="$RELEASE_DIR/deploy-${timestamp}-${commit:0:12}.env"
  local temp

  temp="$(mktemp "$RELEASE_DIR/.deploy-record.XXXXXX")"
  {
    printf 'status=%s\n' "$status"
    printf 'timestamp=%s\n' "$timestamp"
    printf 'commit=%s\n' "$commit"
    printf 'image=%s\n' "$image"
    printf 'previous_image=%s\n' "$previous_image"
    printf 'backup=%s\n' "$backup"
  } >"$temp"
  mv "$temp" "$record"
  log "release record: $record"
}

rollback_release() {
  local previous_image="$1"

  log "rolling back to $previous_image"
  write_image_setting "$previous_image"
  if ! compose up --detach --no-deps --force-recreate --pull never \
    --wait --wait-timeout 180 server; then
    die "rollback container recreation failed"
  fi
  wait_public_health 30 || die "rollback did not restore public health"
}

deploy_release() {
  local image="$1"
  local commit="$2"
  local previous_image
  local timestamp
  local backup

  validate_target "$image" "$commit"
  previous_image="$(current_image)"

  if [[ "$previous_image" == "$image" ]] && wait_public_health 1; then
    log "image is already healthy: $image"
    return 0
  fi

  log "pulling $image"
  docker pull "$image"
  (
    export CLUMSIES_SERVER_IMAGE="$image"
    compose config --quiet
  )

  backup="$(backup_database "pre-deploy-${commit:0:12}")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  write_image_setting "$image"

  if ! compose up --detach --no-deps --pull never \
    --wait --wait-timeout 180 server; then
    rollback_release "$previous_image"
    record_release rolled-back "$timestamp" "$commit" "$image" "$previous_image" "$backup"
    die "new Server container failed; previous image restored"
  fi

  if ! wait_public_health 30; then
    rollback_release "$previous_image"
    record_release rolled-back "$timestamp" "$commit" "$image" "$previous_image" "$backup"
    die "public health check failed; previous image restored"
  fi

  record_release success "$timestamp" "$commit" "$image" "$previous_image" "$backup"
  log "deployment healthy: $image"
}

record_reconfiguration() {
  local status="$1"
  local timestamp="$2"
  local previous_origin="$3"
  local origin="$4"
  local backup="$5"
  local env_backup="$6"
  local record="$RELEASE_DIR/reconfigure-${timestamp}.env"
  local temp

  temp="$(mktemp "$RELEASE_DIR/.reconfigure-record.XXXXXX")"
  {
    printf 'status=%s\n' "$status"
    printf 'timestamp=%s\n' "$timestamp"
    printf 'previous_origin=%s\n' "$previous_origin"
    printf 'origin=%s\n' "$origin"
    printf 'backup=%s\n' "$backup"
    printf 'env_backup=%s\n' "$env_backup"
  } >"$temp"
  mv "$temp" "$record"
  log "reconfiguration record: $record"
}

rollback_reconfiguration() {
  local env_backup="$1"
  local previous_origin="$2"

  log "rolling back runtime configuration to $previous_origin"
  cp --preserve=mode,ownership,timestamps "$env_backup" "$ENV_FILE"
  compose config --quiet
  if ! compose up --detach --no-deps --force-recreate --pull never \
    --wait --wait-timeout 240 server caddy; then
    die "runtime configuration rollback failed"
  fi
  wait_public_health 30 "$previous_origin" ||
    die "runtime configuration rollback did not restore public health"
}

reconfigure_runtime() {
  local origin="$1"
  local redirects="${2:-}"
  local previous_origin
  local previous_redirects
  local timestamp
  local env_backup
  local backup

  validate_public_origin "$origin"
  previous_origin="$(public_origin)"
  previous_redirects="$(read_env_value CLUMSIES_CLIENT_REDIRECT_URIS)"
  if [[ "$#" -lt 2 ]]; then
    redirects="$previous_redirects"
  fi

  if [[ "$previous_origin" == "$origin" && "$previous_redirects" == "$redirects" ]] &&
    wait_public_health 1 "$origin"; then
    log "runtime configuration is already healthy: $origin"
    return 0
  fi

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  env_backup="$RELEASE_DIR/reconfigure-${timestamp}.env.backup"
  cp --preserve=mode,ownership,timestamps "$ENV_FILE" "$env_backup"
  write_runtime_configuration "$origin" "$redirects"

  if ! compose config --quiet; then
    cp --preserve=mode,ownership,timestamps "$env_backup" "$ENV_FILE"
    die "new runtime configuration is invalid; previous configuration restored"
  fi

  if ! backup="$(backup_database pre-reconfigure)"; then
    cp --preserve=mode,ownership,timestamps "$env_backup" "$ENV_FILE"
    die "database backup failed; previous configuration restored"
  fi
  if ! compose up --detach --no-deps --force-recreate --pull never \
    --wait --wait-timeout 240 server caddy; then
    rollback_reconfiguration "$env_backup" "$previous_origin"
    record_reconfiguration rolled-back "$timestamp" "$previous_origin" \
      "$origin" "$backup" "$env_backup"
    die "runtime reconfiguration failed; previous configuration restored"
  fi

  if ! wait_public_health 60 "$origin"; then
    rollback_reconfiguration "$env_backup" "$previous_origin"
    record_reconfiguration rolled-back "$timestamp" "$previous_origin" \
      "$origin" "$backup" "$env_backup"
    die "new public origin failed health checks; previous configuration restored"
  fi

  record_reconfiguration success "$timestamp" "$previous_origin" \
    "$origin" "$backup" "$env_backup"
  log "runtime configuration healthy: $origin"
}

latest_backup() {
  local -a candidates

  mapfile -t candidates < <(
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.dump' -printf '%T@ %p\n' |
      sort -nr
  )
  ((${#candidates[@]} > 0)) || die "no PostgreSQL backup is available"
  printf '%s\n' "${candidates[0]#* }"
}

restore_drill() (
  set -Eeuo pipefail

  local backup="${1:-}"
  local image
  local suffix
  local network
  local postgres_container
  local server_container
  local password
  local attempt
  local table_count
  local migration_count

  if [[ -z "$backup" ]]; then
    backup="$(latest_backup)"
  elif [[ "$backup" != /* ]]; then
    backup="$BACKUP_DIR/$backup"
  fi
  [[ -f "$backup" ]] || die "backup does not exist: $backup"
  if [[ -f "$backup.sha256" ]]; then
    sha256sum --check "$backup.sha256" >/dev/null
  fi

  image="$(current_image)"
  docker image inspect "$image" >/dev/null
  suffix="$(date -u +%Y%m%d%H%M%S)-$$"
  network="clumsies-restore-$suffix"
  postgres_container="clumsies-restore-postgres-$suffix"
  server_container="clumsies-restore-server-$suffix"
  password="$(openssl rand -hex 24)"

  # Invoked by the EXIT trap for this isolated subshell.
  # shellcheck disable=SC2317,SC2329
  cleanup() {
    docker rm --force "$server_container" "$postgres_container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  docker network create "$network" >/dev/null
  docker run --detach --name "$postgres_container" --network "$network" \
    --env POSTGRES_PASSWORD="$password" \
    --env POSTGRES_DB=clumsies_restore \
    postgres:16-alpine >/dev/null

  for ((attempt = 1; attempt <= 60; attempt += 1)); do
    if docker exec "$postgres_container" \
      pg_isready -U postgres -d clumsies_restore >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  ((attempt <= 60)) || die "restore PostgreSQL did not become ready"

  docker exec -i "$postgres_container" \
    pg_restore -U postgres -d clumsies_restore --no-owner --no-privileges <"$backup"

  docker run --detach --name "$server_container" --network "$network" \
    --env-file "$ENV_FILE" \
    --env "DATABASE_URL=postgres://postgres:$password@$postgres_container:5432/clumsies_restore" \
    --env CLUMSIES_SERVER_ADDR=0.0.0.0:8080 \
    "$image" >/dev/null

  for ((attempt = 1; attempt <= 90; attempt += 1)); do
    if docker exec "$server_container" curl --fail --silent \
      http://127.0.0.1:8080/api/v1/admin/health >/dev/null 2>&1; then
      break
    fi
    if [[ "$(docker inspect "$server_container" --format '{{.State.Status}}')" == exited ]]; then
      docker logs "$server_container" >&2
      die "restored Server exited"
    fi
    sleep 1
  done
  ((attempt <= 90)) || die "restored Server did not become healthy"

  table_count="$(docker exec "$postgres_container" psql -At -U postgres \
    -d clumsies_restore -c \
    "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname = 'public';")"
  migration_count="$(docker exec "$postgres_container" psql -At -U postgres \
    -d clumsies_restore -c 'SELECT count(*) FROM _sqlx_migrations;')"
  log "restore drill healthy: backup=$backup tables=$table_count migrations=$migration_count image=$image"
)

preflight() {
  local image
  local origin

  image="$(current_image)"
  origin="$(public_origin)"
  compose config --quiet
  compose ps
  log "preflight ok: compose=$(docker compose version --short) origin=$origin image=$image"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  clumsies-server-release preflight
  clumsies-server-release deploy IMAGE@sha256:DIGEST COMMIT
  clumsies-server-release reconfigure PUBLIC_ORIGIN [CLIENT_REDIRECT_URIS]
  clumsies-server-release backup [reason]
  clumsies-server-release restore-drill [backup-file]
EOF
  exit 2
}

main() {
  local command="${1:-}"

  require_root
  acquire_lock
  require_environment

  case "$command" in
    preflight)
      [[ "$#" -eq 1 ]] || usage
      preflight
      ;;
    deploy)
      [[ "$#" -eq 3 ]] || usage
      deploy_release "$2" "$3"
      ;;
    reconfigure)
      [[ "$#" -ge 2 && "$#" -le 3 ]] || usage
      if [[ "$#" -eq 2 ]]; then
        reconfigure_runtime "$2"
      else
        reconfigure_runtime "$2" "$3"
      fi
      ;;
    backup)
      [[ "$#" -le 2 ]] || usage
      backup_database "${2:-manual}"
      ;;
    restore-drill)
      [[ "$#" -le 2 ]] || usage
      restore_drill "${2:-}"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
