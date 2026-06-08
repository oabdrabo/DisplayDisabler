#!/bin/zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local needle="$2"
  local label="$3"

  echo "$text" | grep -Fq "$needle" || fail "$label should contain: $needle"
}

assert_not_contains() {
  local text="$1"
  local needle="$2"
  local label="$3"

  if echo "$text" | grep -Fq "$needle"; then
    fail "$label should not contain: $needle"
  fi
}

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/displaydisabler-status-doctor.XXXXXX")"

cleanup() {
  rm -rf "$TMP_HOME"
}

trap cleanup EXIT

APP_PATH="$TMP_HOME/Applications/DisplayDisabler.app"
BIN_PATH="$TMP_HOME/bin/display_disable"
CONFIG_PATH="$TMP_HOME/.displaydisabler-watchdog.conf"
PLIST_PATH="$TMP_HOME/Library/LaunchAgents/com.displaydisabler.watchdog.plist"

mkdir -p "$APP_PATH" "$TMP_HOME/bin" "$TMP_HOME/Library/LaunchAgents"

APP_ONLY_STATUS="$(HOME="$TMP_HOME" \
  DD_APP_PATH="$APP_PATH" \
  DISPLAY_DISABLE="$BIN_PATH" \
  DD_CONFIG_FILE="$CONFIG_PATH" \
  DD_PLIST_PATH="$PLIST_PATH" \
  zsh "$REPO_ROOT/scripts/displaydisabler_smart.sh" status)"

assert_contains "$APP_ONLY_STATUS" "install profile: app" "app-only status"
assert_contains "$APP_ONLY_STATUS" "menu-bar app: present" "app-only status"
assert_contains "$APP_ONLY_STATUS" "binary: missing" "app-only status"

APP_ONLY_DOCTOR="$(HOME="$TMP_HOME" \
  DD_APP_PATH="$APP_PATH" \
  DISPLAY_DISABLE="$BIN_PATH" \
  DD_CONFIG_FILE="$CONFIG_PATH" \
  DD_PLIST_PATH="$PLIST_PATH" \
  zsh "$REPO_ROOT/scripts/displaydisabler_smart.sh" doctor)"

assert_contains "$APP_ONLY_DOCTOR" "profile: app" "app-only doctor"
assert_contains "$APP_ONLY_DOCTOR" "info: display_disable CLI fallback is not installed" "app-only doctor"
assert_contains "$APP_ONLY_DOCTOR" "doctor: ok" "app-only doctor"
assert_not_contains "$APP_ONLY_DOCTOR" "fail:" "app-only doctor"

cat > "$CONFIG_PATH" <<'EOF_CONFIG'
DD_INSTALL_PROFILE="cli"
BUILTIN_ID="1"
TRUSTED_EXTERNAL_NAMES="DELL"
SUSPICIOUS_DISPLAY_NAMES="Display|Unknown Display"
CHECK_CONFIRMATIONS="2"
ENABLE_LOGGING="0"
DEBUG_LOGGING="0"
MAX_LOG_SIZE_KB="1024"
EOF_CONFIG

set +e
CLI_DOCTOR="$(HOME="$TMP_HOME" \
  DD_APP_PATH="$APP_PATH.missing" \
  DISPLAY_DISABLE="$BIN_PATH" \
  DD_CONFIG_FILE="$CONFIG_PATH" \
  DD_PLIST_PATH="$PLIST_PATH" \
  zsh "$REPO_ROOT/scripts/displaydisabler_smart.sh" doctor)"
CLI_STATUS=$?
set -e

[ "$CLI_STATUS" -ne 0 ] || fail "cli doctor should fail when display_disable is missing"
assert_contains "$CLI_DOCTOR" "profile: cli" "cli doctor"
assert_contains "$CLI_DOCTOR" "fail: display_disable is missing" "cli doctor"
assert_contains "$CLI_DOCTOR" "doctor: 2 failure(s)" "cli doctor"

echo "smart status/doctor smoke tests passed"
