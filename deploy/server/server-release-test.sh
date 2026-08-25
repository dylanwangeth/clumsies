#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(mktemp -d)"
readonly TEST_DIR
export CLUMSIES_ROOT="$TEST_DIR/root"
readonly EVENT_LOG="$TEST_DIR/events.log"
readonly IMAGE_STATE="$TEST_DIR/image"
PREVIOUS_IMAGE="ghcr.io/lilhammerfun/clumsies-server@sha256:$(printf '1%.0s' {1..64})"
TARGET_IMAGE="ghcr.io/lilhammerfun/clumsies-server@sha256:$(printf '2%.0s' {1..64})"
TARGET_COMMIT="$(printf '3%.0s' {1..40})"
readonly PREVIOUS_IMAGE TARGET_IMAGE TARGET_COMMIT

cleanup_test() {
  rm -rf "$TEST_DIR"
}
trap cleanup_test EXIT

mkdir -p "$CLUMSIES_ROOT/releases"
touch "$EVENT_LOG"
printf '%s\n' "$PREVIOUS_IMAGE" >"$IMAGE_STATE"

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/server-release.sh"

event() {
  printf '%s\n' "$*" >>"$EVENT_LOG"
}

reset_case() {
  : >"$EVENT_LOG"
  printf '%s\n' "$PREVIOUS_IMAGE" >"$IMAGE_STATE"
  FAIL_PREFLIGHT=0
  FAIL_TARGET_START=0
  STOP_EXIT_CODE=0
}

current_image() {
  printf '%s\n' "$PREVIOUS_IMAGE"
}

validate_target() {
  return 0
}

docker() {
  event "docker:$*"
  if [[ "$1" == ps ]]; then
    printf 'server-container\n'
  elif [[ "$1" == inspect && "$*" == *'{{.State.ExitCode}}'* ]]; then
    printf '%s\n' "$STOP_EXIT_CODE"
  fi
}

compose() {
  local image

  image="$(<"$IMAGE_STATE")"
  event "compose[$image]:$*"
  if [[ "$*" == *" up "* || "$1" == up ]]; then
    if [[ "$image" == "$TARGET_IMAGE" && "$FAIL_TARGET_START" -eq 1 ]]; then
      return 1
    fi
  fi
}

backup_database() {
  local reason="$1"

  event "backup:$reason"
  printf '/backup/%s.dump\n' "$reason"
}

verify_backup_with_image() {
  event "verify:$1:$2:$3"
  [[ "$FAIL_PREFLIGHT" -eq 0 ]]
}

write_image_setting() {
  event "write-image:$1"
  printf '%s\n' "$1" >"$IMAGE_STATE"
}

restore_database() {
  event "restore:$1"
}

wait_public_health() {
  event "health:${1:-}:${2:-}"
}

record_release() {
  event "record:$*"
}

line_of() {
  local prefix="$1"

  awk -v prefix="$prefix" 'index($0, prefix) == 1 { print NR; exit }' "$EVENT_LOG"
}

assert_present() {
  local prefix="$1"

  [[ -n "$(line_of "$prefix")" ]] || {
    printf 'missing event: %s\n' "$prefix" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  }
}

assert_absent() {
  local prefix="$1"

  [[ -z "$(line_of "$prefix")" ]] || {
    printf 'unexpected event: %s\n' "$prefix" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  }
}

assert_before() {
  local first="$1"
  local second="$2"
  local first_line
  local second_line

  first_line="$(line_of "$first")"
  second_line="$(line_of "$second")"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] || {
    printf 'expected %s before %s\n' "$first" "$second" >&2
    cat "$EVENT_LOG" >&2
    exit 1
  }
}

test_successful_cutover() {
  local stop_event="compose[$PREVIOUS_IMAGE]:stop --timeout 10 server"

  reset_case
  deploy_release "$TARGET_IMAGE" "$TARGET_COMMIT"

  assert_before "verify:" "$stop_event"
  assert_before "$stop_event" "backup:pre-deploy-"
  assert_before "backup:pre-deploy-" "write-image:$TARGET_IMAGE"
  assert_before "write-image:$TARGET_IMAGE" "compose[$TARGET_IMAGE]:up "
  assert_before "compose[$TARGET_IMAGE]:up " "record:success "
  assert_absent "restore:"
}

test_failed_preflight_leaves_production_untouched() {
  reset_case
  FAIL_PREFLIGHT=1

  if (deploy_release "$TARGET_IMAGE" "$TARGET_COMMIT"); then
    printf 'expected release preflight to fail\n' >&2
    exit 1
  fi

  assert_present "record:preflight-failed "
  assert_absent "compose[$PREVIOUS_IMAGE]:stop "
  assert_absent "write-image:$TARGET_IMAGE"
  assert_absent "restore:"
}

test_nonzero_exit_after_stop_aborts_cutover() {
  local exit_code

  for exit_code in 1 137; do
    reset_case
    STOP_EXIT_CODE="$exit_code"

    if (deploy_release "$TARGET_IMAGE" "$TARGET_COMMIT"); then
      printf 'expected exit-%s stop to fail\n' "$exit_code" >&2
      exit 1
    fi

    assert_present "record:cutover-stop-failed "
    assert_absent "backup:pre-deploy-"
    assert_absent "write-image:$TARGET_IMAGE"
    assert_absent "compose[$TARGET_IMAGE]:up "
    assert_absent "restore:"
  done
}

test_isolated_server_requires_clean_exit() {
  local exit_code

  reset_case
  stop_isolated_server isolated-server
  assert_before "docker:stop --time 10 isolated-server" \
    "docker:inspect isolated-server --format {{.State.ExitCode}}"

  for exit_code in 1 137; do
    reset_case
    STOP_EXIT_CODE="$exit_code"
    if (stop_isolated_server isolated-server); then
      printf 'expected isolated Server exit %s to fail\n' "$exit_code" >&2
      exit 1
    fi
    assert_present "docker:stop --time 10 isolated-server"
    assert_present "docker:inspect isolated-server --format {{.State.ExitCode}}"
  done
}

test_failed_target_restores_database_before_old_image() {
  local target_start="compose[$TARGET_IMAGE]:up "
  local target_stop="compose[$TARGET_IMAGE]:stop --timeout 10 server"
  local previous_start="compose[$PREVIOUS_IMAGE]:up "

  reset_case
  FAIL_TARGET_START=1

  if (deploy_release "$TARGET_IMAGE" "$TARGET_COMMIT"); then
    printf 'expected target start to fail\n' >&2
    exit 1
  fi

  assert_before "$target_start" "$target_stop"
  assert_before "$target_stop" "write-image:$PREVIOUS_IMAGE"
  assert_before "write-image:$PREVIOUS_IMAGE" "restore:/backup/pre-deploy-"
  assert_before "restore:/backup/pre-deploy-" "$previous_start"
  assert_before "$previous_start" "record:rolled-back "
}

test_successful_cutover
test_failed_preflight_leaves_production_untouched
test_nonzero_exit_after_stop_aborts_cutover
test_isolated_server_requires_clean_exit
test_failed_target_restores_database_before_old_image

printf 'server release transaction tests passed\n'
