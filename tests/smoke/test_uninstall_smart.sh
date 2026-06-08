#!/bin/zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_exists() {
  local target_path="$1"
  local label="$2"

  [ -e "$target_path" ] || fail "$label should exist: $target_path"
}

assert_not_exists() {
  local target_path="$1"
  local label="$2"

  [ ! -e "$target_path" ] || fail "$label should be removed: $target_path"
}

assert_contains() {
  local target_path="$1"
  local needle="$2"
  local label="$3"

  grep -Fq "$needle" "$target_path" || fail "$label should contain: $needle"
}

assert_not_contains() {
  local target_path="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq "$needle" "$target_path"; then
    fail "$label should not contain: $needle"
  fi
}

TMP_HOME="$(mktemp -d "${TMPDIR:-/tmp}/displaydisabler-uninstall.XXXXXX")"

cleanup() {
  rm -rf "$TMP_HOME"
}

trap cleanup EXIT

APP_PATH="$TMP_HOME/Applications/DisplayDisabler.app"
BIN_PATH="$TMP_HOME/bin/display_disable"
ZSHRC="$TMP_HOME/.zshrc"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$TMP_HOME/Scripts" "$TMP_HOME/Library/LaunchAgents" "$TMP_HOME/Library/Logs" "$TMP_HOME/bin"

touch "$APP_PATH/Contents/MacOS/DisplayDisabler"
touch "$TMP_HOME/Library/LaunchAgents/com.displaydisabler.watchdog.plist"
touch "$TMP_HOME/Library/LaunchAgents/com.displaydisabler.auto-enable-builtin.plist"
touch "$TMP_HOME/Scripts/DisplayDisabler-Watchdog"
touch "$TMP_HOME/Scripts/auto_enable_builtin_on_external_disconnect.sh"
touch "$TMP_HOME/Scripts/displaydisabler-smart"
touch "$TMP_HOME/Scripts/safe_disable_builtin.sh"
touch "$TMP_HOME/Scripts/trust_current_external_displays.sh"
touch "$TMP_HOME/Scripts/displaydisabler_smart_lib.sh"
touch "$TMP_HOME/.displaydisabler-watchdog.conf"
touch "$TMP_HOME/Library/Logs/displaydisabler-watchdog.log"
touch "$TMP_HOME/Library/Logs/displaydisabler-watchdog.log.1"
touch "$TMP_HOME/Library/Logs/displaydisabler-watchdog-suspicious-count"
touch "$BIN_PATH"

cat > "$ZSHRC" <<'EOF_ZSHRC'
export KEEP_ME=1
# >>> DisplayDisabler smart aliases >>>
alias ddo="$HOME/Scripts/safe_disable_builtin.sh"
alias dds="$HOME/Scripts/displaydisabler-smart status"
# <<< DisplayDisabler smart aliases <<<
alias legacy_off="display_disable disable 1"
alias legacy_on="display_disable enable 1"
alias legacy_trust="$HOME/Scripts/trust_current_external_displays.sh"
alias legacy_watchdog="$HOME/Scripts/DisplayDisabler-Watchdog"
alias legacy_smart="$HOME/Scripts/displaydisabler-smart"
alias legacy_safe="$HOME/Scripts/safe_disable_builtin.sh"
export AFTER=1
EOF_ZSHRC

printf 'y\ny\n' | HOME="$TMP_HOME" \
  APP_INSTALL_PATH="$APP_PATH" \
  BINARY_PATH="$BIN_PATH" \
  zsh "$REPO_ROOT/scripts/uninstall_smart.sh" --full >/dev/null

assert_not_exists "$APP_PATH" "menu-bar app"
assert_not_exists "$TMP_HOME/Library/LaunchAgents/com.displaydisabler.watchdog.plist" "LaunchAgent"
assert_not_exists "$TMP_HOME/Library/LaunchAgents/com.displaydisabler.auto-enable-builtin.plist" "old LaunchAgent"
assert_not_exists "$TMP_HOME/Scripts/DisplayDisabler-Watchdog" "watchdog script"
assert_not_exists "$TMP_HOME/Scripts/auto_enable_builtin_on_external_disconnect.sh" "old watchdog script"
assert_not_exists "$TMP_HOME/Scripts/displaydisabler-smart" "smart command"
assert_not_exists "$TMP_HOME/Scripts/safe_disable_builtin.sh" "safe-disable wrapper"
assert_not_exists "$TMP_HOME/Scripts/trust_current_external_displays.sh" "trust helper"
assert_not_exists "$TMP_HOME/Scripts/displaydisabler_smart_lib.sh" "helper library"
assert_not_exists "$TMP_HOME/.displaydisabler-watchdog.conf" "watchdog config"
assert_not_exists "$TMP_HOME/Library/Logs/displaydisabler-watchdog.log" "watchdog log"
assert_not_exists "$TMP_HOME/Library/Logs/displaydisabler-watchdog.log.1" "rotated watchdog log"
assert_not_exists "$TMP_HOME/Library/Logs/displaydisabler-watchdog-suspicious-count" "watchdog state"
assert_not_exists "$BIN_PATH" "display_disable binary"

assert_exists "$ZSHRC.displaydisabler-uninstall.bak" "zshrc backup"
assert_contains "$ZSHRC" "export KEEP_ME=1" ".zshrc"
assert_contains "$ZSHRC" "export AFTER=1" ".zshrc"
assert_not_contains "$ZSHRC" "DisplayDisabler smart aliases" ".zshrc"
assert_not_contains "$ZSHRC" "display_disable disable" ".zshrc"
assert_not_contains "$ZSHRC" "display_disable enable" ".zshrc"
assert_not_contains "$ZSHRC" "trust_current_external_displays.sh" ".zshrc"
assert_not_contains "$ZSHRC" "DisplayDisabler-Watchdog" ".zshrc"
assert_not_contains "$ZSHRC" "displaydisabler-smart" ".zshrc"
assert_not_contains "$ZSHRC" "safe_disable_builtin.sh" ".zshrc"

echo "smart uninstaller smoke tests passed"
