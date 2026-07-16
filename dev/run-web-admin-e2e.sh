#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose_project=clumsies-web-admin-e2e

cleanup() {
  docker compose \
    -f "$repo_root/docker-compose.yml" \
    -p "$compose_project" \
    down -v --remove-orphans >/dev/null 2>&1 || true
}

trap cleanup EXIT INT TERM

cd "$repo_root/apps/web-admin"
playwright test
