#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
promote_script="$repo_root/apps/macos/Scripts/promote-debug.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/clumsies-promote-debug-test.XXXXXX")"
fake_bin="$test_root/bin"
event_log="$test_root/events.log"

cleanup_test() {
  rm -rf "$test_root"
}
trap cleanup_test 0 1 2 15

fail() {
  printf '%s\n' "$1" >&2
  if [ -f "$event_log" ]; then
    printf '%s\n' "events:" >&2
    sed 's/^/  /' "$event_log" >&2
  fi
  exit 1
}

line_of() {
  awk -v event="$1" '$0 == event { print NR; exit }' "$event_log"
}

assert_present() {
  [ -n "$(line_of "$1")" ] || fail "missing event: $1"
}

assert_absent() {
  [ -z "$(line_of "$1")" ] || fail "unexpected event: $1"
}

assert_before() {
  first_line="$(line_of "$1")"
  second_line="$(line_of "$2")"
  [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] \
    || fail "expected '$1' before '$2'"
}

assert_installed_version() {
  actual="$(sed -n '1p' "$install_dir/Clumsies.app/version" 2>/dev/null || true)"
  [ "$actual" = "$1" ] || fail "expected installed App version '$1', got '$actual'"
}

assert_no_transaction_artifacts() {
  for artifact in "$install_dir"/.Clumsies.*.app; do
    [ ! -e "$artifact" ] || fail "transaction artifact was not cleaned up: $artifact"
  done
}

mkdir -p "$fake_bin"

cat >"$fake_bin/fake-command" <<'EOF'
#!/bin/sh
set -eu

event() {
  printf '%s\n' "$1" >>"$CLUMSIES_TEST_EVENT_LOG"
}

command_name="${0##*/}"
case "$command_name" in
  xcodegen)
    event build-project
    ;;
  xcodebuild)
    event build-app
    if [ "$CLUMSIES_TEST_BUILD_FAIL" = 1 ]; then
      exit 42
    fi
    app="$CLUMSIES_MACOS_DERIVED_DATA/Build/Products/Debug/Clumsies.app"
    mkdir -p "$app/Contents/Resources"
    printf '%s\n' new >"$app/version"
    cp "$CLUMSIES_TEST_FAKE_COMMAND" "$app/Contents/Resources/clumsiesd"
    chmod 755 "$app/Contents/Resources/clumsiesd"
    ;;
  codesign)
    event verify-app
    ;;
  ditto)
    event stage-app
    cp -R "$1" "$2"
    ;;
  pgrep)
    state="$(sed -n '1p' "$CLUMSIES_TEST_APP_STATE")"
    case "$state" in
      absent)
        exit 1
        ;;
      running|stuck)
        exit 0
        ;;
      quitting)
        printf '%s\n' absent >"$CLUMSIES_TEST_APP_STATE"
        exit 0
        ;;
      *)
        printf 'unknown fake App state: %s\n' "$state" >&2
        exit 2
        ;;
    esac
    ;;
  osascript)
    event quit-app
    state="$(sed -n '1p' "$CLUMSIES_TEST_APP_STATE")"
    if [ "$state" = running ]; then
      printf '%s\n' quitting >"$CLUMSIES_TEST_APP_STATE"
    fi
    ;;
  sleep)
    event wait-for-quit
    ;;
  mv)
    source_name="${1##*/}"
    target_name="${2##*/}"
    case "$source_name:$target_name" in
      Clumsies.app:.Clumsies.previous.*.app)
        event backup-app
        /bin/mv "$@"
        if [ "$CLUMSIES_TEST_SIGNAL_AFTER_BACKUP" = 1 ]; then
          event signal-after-backup
          kill -TERM "$PPID"
        fi
        ;;
      .Clumsies.previous.*.app:Clumsies.app)
        event restore-app
        /bin/mv "$@"
        ;;
      .Clumsies.*.app:Clumsies.app)
        event install-app
        if [ "$CLUMSIES_TEST_SWAP_FAIL" = 1 ]; then
          exit 43
        fi
        /bin/mv "$@"
        if [ "$CLUMSIES_TEST_SIGNAL_AFTER_INSTALL" = 1 ]; then
          event signal-after-install
          kill -TERM "$PPID"
        fi
        ;;
      *)
        /bin/mv "$@"
        ;;
    esac
    ;;
  clumsiesd)
    app_root="${0%/Contents/Resources/clumsiesd}"
    app_version="$(sed -n '1p' "$app_root/version")"
    case "${1:-}" in
      --reconcile-launch-agent)
        event "reconcile-launch-agent-$app_version"
        if [ "$CLUMSIES_TEST_RECONCILE_FAIL" = 1 ] && [ "$app_version" = new ]; then
          exit 46
        fi
        plist="$HOME/Library/LaunchAgents/ai.clumsies.daemon.plist"
        mkdir -p "${plist%/*}"
        printf '%s\n' "$app_version" >"$plist"
        ;;
      *)
        exit 44
        ;;
    esac
    ;;
  open)
    event open-app
    if [ "$CLUMSIES_TEST_OPEN_FAIL" = 1 ]; then
      exit 47
    fi
    ;;
  *)
    printf 'unexpected fake command: %s\n' "$command_name" >&2
    exit 45
    ;;
esac
EOF
chmod 755 "$fake_bin/fake-command"

for command_name in xcodegen xcodebuild codesign ditto pgrep osascript sleep mv open; do
  ln -s fake-command "$fake_bin/$command_name"
done

reset_case() {
  case_name="$1"
  initial_state="$2"
  initial_install="${3:-present}"
  case_root="$test_root/$case_name"
  case_home="$case_root/home"
  install_dir="$case_root/install"
  derived_data="$case_root/derived"
  event_log="$case_root/events.log"
  app_state="$case_root/app-state"
  stdout_log="$case_root/stdout.log"
  stderr_log="$case_root/stderr.log"
  build_fail=0
  swap_fail=0
  signal_after_backup=0
  signal_after_install=0
  reconcile_fail=0
  open_fail=0

  mkdir -p "$case_home" "$install_dir"
  if [ "$initial_install" = present ]; then
    mkdir -p "$install_dir/Clumsies.app/Contents/Resources"
    printf '%s\n' old >"$install_dir/Clumsies.app/version"
    cp "$fake_bin/fake-command" \
      "$install_dir/Clumsies.app/Contents/Resources/clumsiesd"
    chmod 755 "$install_dir/Clumsies.app/Contents/Resources/clumsiesd"
  fi
  printf '%s\n' "$initial_state" >"$app_state"
  : >"$event_log"
}

run_promote() {
  env \
    HOME="$case_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    CLUMSIES_MACOS_INSTALL_DIR="$install_dir" \
    CLUMSIES_MACOS_DERIVED_DATA="$derived_data" \
    CLUMSIES_TEST_EVENT_LOG="$event_log" \
    CLUMSIES_TEST_APP_STATE="$app_state" \
    CLUMSIES_TEST_FAKE_COMMAND="$fake_bin/fake-command" \
    CLUMSIES_TEST_BUILD_FAIL="$build_fail" \
    CLUMSIES_TEST_SWAP_FAIL="$swap_fail" \
    CLUMSIES_TEST_SIGNAL_AFTER_BACKUP="$signal_after_backup" \
    CLUMSIES_TEST_SIGNAL_AFTER_INSTALL="$signal_after_install" \
    CLUMSIES_TEST_RECONCILE_FAIL="$reconcile_fail" \
    CLUMSIES_TEST_OPEN_FAIL="$open_fail" \
    sh "$promote_script" >"$stdout_log" 2>"$stderr_log"
}

test_successful_promotion() {
  reset_case success running
  run_promote || fail "successful promotion failed"

  assert_installed_version new
  assert_before build-app stage-app
  assert_before stage-app quit-app
  assert_before quit-app backup-app
  assert_before backup-app install-app
  assert_before install-app reconcile-launch-agent-new
  assert_before reconcile-launch-agent-new open-app
  grep -q 'The App reconciles the global Plugin after launch' "$stdout_log" \
    || fail "promotion did not explain the asynchronous Plugin reconciliation"
  grep -q 'restart Codex and create a new task' "$stdout_log" \
    || fail "promotion did not explain the Host refresh requirement"
  assert_no_transaction_artifacts
}

test_quit_timeout_preserves_installed_app() {
  reset_case timeout stuck
  if run_promote; then
    fail "promotion unexpectedly succeeded when the App never quit"
  fi

  grep -q 'did not quit within 10 seconds' "$stderr_log" \
    || fail "quit timeout did not report the 10-second deadline"
  assert_installed_version old
  assert_present quit-app
  assert_absent backup-app
  assert_absent install-app
  assert_absent reconcile-launch-agent-new
  assert_absent reconcile-launch-agent-old
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_failed_swap_restores_installed_app() {
  reset_case swap-failure absent
  swap_fail=1
  if run_promote; then
    fail "promotion unexpectedly succeeded when the staging swap failed"
  fi

  assert_installed_version old
  assert_before backup-app install-app
  assert_before install-app restore-app
  assert_before restore-app reconcile-launch-agent-old
  assert_absent reconcile-launch-agent-new
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_failed_build_has_no_install_side_effects() {
  reset_case build-failure running
  build_fail=1
  if run_promote; then
    fail "promotion unexpectedly succeeded when the build failed"
  fi

  assert_installed_version old
  assert_present build-app
  assert_absent stage-app
  assert_absent quit-app
  assert_absent backup-app
  assert_absent install-app
  assert_absent reconcile-launch-agent-new
  assert_absent reconcile-launch-agent-old
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_signal_after_backup_restores_installed_app() {
  reset_case signal-restore absent
  signal_after_backup=1
  if run_promote; then
    fail "promotion unexpectedly succeeded after an interrupted backup"
  fi

  assert_installed_version old
  assert_before backup-app signal-after-backup
  assert_before signal-after-backup restore-app
  assert_before restore-app reconcile-launch-agent-old
  assert_absent reconcile-launch-agent-new
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_failed_reconcile_restores_installed_app() {
  reset_case reconcile-failure absent
  reconcile_fail=1
  if run_promote; then
    fail "promotion unexpectedly succeeded when daemon reconciliation failed"
  fi

  assert_installed_version old
  assert_before install-app reconcile-launch-agent-new
  assert_before reconcile-launch-agent-new restore-app
  assert_before restore-app reconcile-launch-agent-old
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_failed_open_restores_installed_app() {
  reset_case open-failure absent
  open_fail=1
  if run_promote; then
    fail "promotion unexpectedly succeeded when opening the App failed"
  fi

  assert_installed_version old
  assert_before reconcile-launch-agent-new open-app
  assert_before open-app restore-app
  assert_before restore-app reconcile-launch-agent-old
  assert_no_transaction_artifacts
}

test_signal_after_install_restores_installed_app() {
  reset_case signal-after-install absent
  signal_after_install=1
  if run_promote; then
    fail "promotion unexpectedly succeeded after an interrupted install"
  fi

  assert_installed_version old
  assert_before install-app signal-after-install
  assert_before signal-after-install restore-app
  assert_before restore-app reconcile-launch-agent-old
  assert_absent reconcile-launch-agent-new
  assert_absent open-app
  assert_no_transaction_artifacts
}

test_successful_first_install_defers_reconcile_to_app() {
  reset_case first-install-success absent missing
  run_promote || fail "successful first promotion failed"

  assert_installed_version new
  assert_before install-app open-app
  assert_absent reconcile-launch-agent-new
  assert_absent reconcile-launch-agent-old
  assert_no_transaction_artifacts
}

test_failed_first_install_removes_new_app_without_touching_launch_agent() {
  reset_case first-install-failure absent missing
  plist="$case_home/Library/LaunchAgents/ai.clumsies.daemon.plist"
  mkdir -p "${plist%/*}"
  printf '%s\n' existing >"$plist"
  open_fail=1
  if run_promote; then
    fail "first promotion unexpectedly succeeded when opening the App failed"
  fi

  [ ! -e "$install_dir/Clumsies.app" ] \
    || fail "failed first promotion left the new App installed"
  [ "$(sed -n '1p' "$plist")" = existing ] \
    || fail "failed first promotion changed the existing LaunchAgent plist"
  assert_present open-app
  assert_absent restore-app
  assert_absent reconcile-launch-agent-new
  assert_absent reconcile-launch-agent-old
  assert_no_transaction_artifacts
}

test_interrupted_first_install_removes_new_app_without_touching_launch_agent() {
  reset_case first-install-signal absent missing
  plist="$case_home/Library/LaunchAgents/ai.clumsies.daemon.plist"
  mkdir -p "${plist%/*}"
  printf '%s\n' existing >"$plist"
  signal_after_install=1
  if run_promote; then
    fail "first promotion unexpectedly succeeded after an interrupted install"
  fi

  [ ! -e "$install_dir/Clumsies.app" ] \
    || fail "interrupted first promotion left the new App installed"
  [ "$(sed -n '1p' "$plist")" = existing ] \
    || fail "interrupted first promotion changed the existing LaunchAgent plist"
  assert_absent reconcile-launch-agent-new
  assert_absent open-app
  assert_no_transaction_artifacts
}

[ -f "$promote_script" ] || fail "missing script under test: $promote_script"

test_successful_promotion
test_quit_timeout_preserves_installed_app
test_failed_swap_restores_installed_app
test_failed_build_has_no_install_side_effects
test_signal_after_backup_restores_installed_app
test_failed_reconcile_restores_installed_app
test_failed_open_restores_installed_app
test_signal_after_install_restores_installed_app
test_successful_first_install_defers_reconcile_to_app
test_failed_first_install_removes_new_app_without_touching_launch_agent
test_interrupted_first_install_removes_new_app_without_touching_launch_agent

printf '%s\n' 'macOS Debug promotion contract tests passed'
