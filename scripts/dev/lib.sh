#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${CLUMSIES_COMPOSE_FILE:-${REPO_ROOT}/docker-compose.yml}"

require_env() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        printf 'Error: %s must be set in the shell or %s/.env.local\n' "${name}" "${REPO_ROOT}" >&2
        exit 1
    fi
}

require_command() {
    local name="$1"
    if ! command -v "${name}" >/dev/null 2>&1; then
        printf 'Error: required command not found: %s\n' "${name}" >&2
        exit 1
    fi
}

require_docker_compose() {
    require_command docker
    if ! docker compose version >/dev/null 2>&1; then
        printf 'Error: docker compose is required for local development\n' >&2
        exit 1
    fi
}

set_dev_harness_env() {
    export COMPOSE_PROJECT_NAME="clumsies-dev"
    export HUB_PORT="8410"
    export HUB_DB_HOST="127.0.0.1"
    export HUB_DB_PORT="5433"
    export HUB_DB_NAME="clumsies_dev"
    export HUB_DB_USER="clumsies_dev"
    export HUB_DB_PASSWORD="clumsies_dev"
    export HUB_BOOTSTRAP_ORG="seed-dev"
    export HUB_BOOTSTRAP_USERNAME="admin"
    export HUB_BOOTSTRAP_PASSWORD="admin"
}

docker_compose() {
    require_docker_compose
    docker compose --project-name "${COMPOSE_PROJECT_NAME}" -f "${COMPOSE_FILE}" "$@"
}

compose_up_postgres() {
    docker_compose up -d postgres >/dev/null
}

wait_for_postgres() {
    local attempts="${1:-30}"
    local i

    for ((i = 1; i <= attempts; i++)); do
        if docker_compose exec -T postgres pg_isready -U "${HUB_DB_USER}" -d "${HUB_DB_NAME}" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done

    printf 'Error: postgres did not become ready after %s seconds\n' "${attempts}" >&2
    exit 1
}

ensure_postgres_ready() {
    compose_up_postgres
    wait_for_postgres
}

build_repo() {
    require_command zig
    (
        cd "${REPO_ROOT}"
        zig build
    )
}

wait_for_hub() {
    require_command curl
    local base_url="http://127.0.0.1:${HUB_PORT}"
    local attempts="${1:-150}"
    local i
    local http_status

    for ((i = 1; i <= attempts; i++)); do
        http_status="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 1 "${base_url}/api/auth/me" || true)"
        case "${http_status}" in
            200|401|403)
                return
                ;;
        esac
        sleep 0.2
    done

    printf 'Error: hub did not become ready at %s after %s attempts\n' "${base_url}" "${attempts}" >&2
    exit 1
}
