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
  docker inspect clumsies_server_1 --format '{{.Config.Image}}' 2>/dev/null || true
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

server_host() {
  local host
  host="$(read_env_value CLUMSIES_SERVER_HOST)"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid CLUMSIES_SERVER_HOST"
  printf '%s\n' "$host"
}

wait_public_health() {
  local attempts="${1:-30}"
  local host
  local attempt

  host="$(server_host)"
  for ((attempt = 1; attempt <= attempts; attempt += 1)); do
    if curl --fail --silent --show-error --max-time 8 \
      "https://$host/api/v1/admin/health" >/dev/null; then
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
  local host

  image="$(current_image)"
  host="$(server_host)"
  compose config --quiet
  compose ps
  log "preflight ok: compose=$(docker compose version --short) host=$host image=$image"
}

usage() {
  cat >&2 <<'EOF'
Usage:
  clumsies-server-release preflight
  clumsies-server-release deploy IMAGE@sha256:DIGEST COMMIT
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
