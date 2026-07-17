#!/usr/bin/env bash

set -Eeuo pipefail

readonly IMAGE_PREFIX="ghcr.io/lilhammerfun/clumsies-server"
readonly RELEASE_COMMAND="/usr/local/sbin/clumsies-server-release"

deny() {
  printf 'deployment command rejected\n' >&2
  exit 1
}

main() {
  local original="${SSH_ORIGINAL_COMMAND:-}"
  local command
  local image
  local commit
  local extra
  local digest

  read -r command image commit extra <<<"$original"
  [[ "$command" == deploy ]] || deny
  [[ -z "${extra:-}" ]] || deny
  digest="${image#"$IMAGE_PREFIX@sha256:"}"
  [[ "$image" == "$IMAGE_PREFIX@sha256:$digest" && "$digest" =~ ^[a-f0-9]{64}$ ]] || deny
  [[ "$commit" =~ ^[a-f0-9]{40}$ ]] || deny

  exec sudo --non-interactive "$RELEASE_COMMAND" deploy "$image" "$commit"
}

main "$@"
