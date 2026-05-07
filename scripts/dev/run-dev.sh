#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

set_dev_harness_env

INTERVAL="${INTERVAL:-1000}"
hub_pid=""
seed_pid=""

cleanup() {
    if [ -n "${seed_pid}" ] && kill -0 "${seed_pid}" 2>/dev/null; then
        kill "${seed_pid}" 2>/dev/null || true
    fi
    if [ -n "${hub_pid}" ] && kill -0 "${hub_pid}" 2>/dev/null; then
        kill "${hub_pid}" 2>/dev/null || true
    fi
    if [ -n "${seed_pid}" ]; then
        wait "${seed_pid}" 2>/dev/null || true
    fi
    if [ -n "${hub_pid}" ]; then
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

wait_for_hub
printf 'Open the TUI with ./zig-out/bin/clumsies and sign in, or run: ./zig-out/bin/clumsies login --hub-url http://127.0.0.1:%s -u admin\n' "${HUB_PORT}"

printf 'Starting clumsies-seed with interval %sms\n' "${INTERVAL}"
"${REPO_ROOT}/zig-out/bin/clumsies-seed" "--interval=${INTERVAL}" &
seed_pid=$!

status=0
while true; do
    if ! kill -0 "${hub_pid}" 2>/dev/null; then
        wait "${hub_pid}" || status=$?
        break
    fi
    if ! kill -0 "${seed_pid}" 2>/dev/null; then
        wait "${seed_pid}" || status=$?
        break
    fi
    sleep 1
done

exit "${status}"
