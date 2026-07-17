#!/usr/bin/env bash

set -Eeuo pipefail
umask 0077

readonly DEPLOY_USER="clumsies-deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

die() {
  printf '[clumsies-install] error: %s\n' "$*" >&2
  exit 1
}

main() {
  local public_key_file="${1:-}"
  local public_key
  local home_dir
  local sudoers_temp

  [[ "$(id -u)" -eq 0 ]] || die "run this installer as root"
  [[ -f "$public_key_file" ]] ||
    die "usage: install.sh /path/to/github-deploy-key.pub"
  docker compose version --short >/dev/null 2>&1 ||
    die "Docker Compose v2 must be installed first"

  public_key="$(<"$public_key_file")"
  [[ "$public_key" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] ||
    die "the deploy key must be a single Ed25519 public key"

  if ! id "$DEPLOY_USER" >/dev/null 2>&1; then
    useradd --create-home --home-dir "/var/lib/$DEPLOY_USER" \
      --shell /bin/bash --user-group "$DEPLOY_USER"
    passwd --lock "$DEPLOY_USER" >/dev/null
  fi
  home_dir="$(getent passwd "$DEPLOY_USER" | cut -d: -f6)"

  install -m 0755 "$SCRIPT_DIR/server-release.sh" \
    /usr/local/sbin/clumsies-server-release
  install -m 0755 "$SCRIPT_DIR/github-command.sh" \
    /usr/local/sbin/clumsies-github-command
  install -m 0644 "$SCRIPT_DIR/clumsies-backup.service" \
    /etc/systemd/system/clumsies-backup.service
  install -m 0644 "$SCRIPT_DIR/clumsies-backup.timer" \
    /etc/systemd/system/clumsies-backup.timer
  install -m 0644 "$SCRIPT_DIR/clumsies-restore-drill.service" \
    /etc/systemd/system/clumsies-restore-drill.service
  install -m 0644 "$SCRIPT_DIR/clumsies-restore-drill.timer" \
    /etc/systemd/system/clumsies-restore-drill.timer

  install -d -m 0700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$home_dir/.ssh"
  {
    printf 'command="/usr/local/sbin/clumsies-github-command",'
    printf 'no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding '
    printf '%s\n' "$public_key"
  } >"$home_dir/.ssh/authorized_keys"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$home_dir/.ssh/authorized_keys"
  chmod 0600 "$home_dir/.ssh/authorized_keys"

  sudoers_temp="$(mktemp)"
  printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/clumsies-server-release deploy *\n' \
    "$DEPLOY_USER" >"$sudoers_temp"
  visudo --check --file="$sudoers_temp" >/dev/null
  install -m 0440 "$sudoers_temp" "/etc/sudoers.d/$DEPLOY_USER"
  rm -f "$sudoers_temp"

  install -d -m 0700 /opt/clumsies/backups /opt/clumsies/releases
  /usr/local/sbin/clumsies-server-release preflight
  systemctl daemon-reload
  systemctl enable --now clumsies-backup.timer clumsies-restore-drill.timer
  printf '[clumsies-install] GitHub deploy identity and recovery timers installed\n'
}

main "$@"
