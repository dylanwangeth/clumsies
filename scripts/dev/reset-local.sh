#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

set_dev_harness_env

printf 'Removing dev postgres state for compose project %s\n' "${COMPOSE_PROJECT_NAME}"
docker_compose down -v --remove-orphans >/dev/null
printf 'Skipping ~/.clumsies cleanup; seed-owned local data cleanup is handled separately\n'

printf 'Dev state reset complete\n'
