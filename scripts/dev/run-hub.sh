#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

set_dev_harness_env
hub_pid=""

cleanup() {
    if [ -n "${hub_pid}" ] && kill -0 "${hub_pid}" 2>/dev/null; then
        kill "${hub_pid}" 2>/dev/null || true
        wait "${hub_pid}" 2>/dev/null || true
    fi
}

handle_interrupt() {
    trap - EXIT INT TERM
    cleanup
    exit 0
}

trap cleanup EXIT
trap handle_interrupt INT TERM

ensure_postgres_ready
build_repo

printf 'Starting clumsies-hub on port %s\n' "${HUB_PORT}"
"${REPO_ROOT}/zig-out/bin/clumsies-hub" &
hub_pid=$!
wait "${hub_pid}"
