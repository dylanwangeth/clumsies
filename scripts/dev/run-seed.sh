#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

set_dev_harness_env

INTERVAL="${INTERVAL:-1000}"
seed_pid=""

cleanup() {
    if [ -n "${seed_pid}" ] && kill -0 "${seed_pid}" 2>/dev/null; then
        kill "${seed_pid}" 2>/dev/null || true
        wait "${seed_pid}" 2>/dev/null || true
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

printf 'Starting clumsies-seed with interval %sms\n' "${INTERVAL}"
"${REPO_ROOT}/zig-out/bin/clumsies-seed" "--interval=${INTERVAL}" &
seed_pid=$!
wait "${seed_pid}"
