#!/bin/zsh

set -e

REPO="oabdrabo/DisplayDisabler"
BINARY_NAME="display_disable"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"

ZSHRC="$HOME/.zshrc"
SCRIPTS_DIR="$HOME/Scripts"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

WATCHDOG_SOURCE="$(cd "$(dirname "$0")" && pwd)/auto_enable_builtin_on_external_disconnect.sh"
WATCHDOG_TARGET="$SCRIPTS_DIR/DisplayDisabler-Watchdog"

TRUST_SCRIPT_SOURCE="$(cd "$(dirname "$0")" && pwd)/trust_current_external_displays.sh"
TRUST_SCRIPT_TARGET="$SCRIPTS_DIR/trust_current_external_displays.sh"

CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"
PLIST_PATH="$LAUNCH_AGENTS_DIR/com.displaydisabler.watchdog.plist"

echo
echo "DisplayDisabler Smart Installer"
echo "--------------------------------"
echo

install_binary_if_missing() {
  if [ -x "$INSTALL_PATH" ]; then
    echo "Found existing binary: $INSTALL_PATH"
    return
  fi

  echo "$BINARY_NAME not found at $INSTALL_PATH."
  echo "Downloading latest release asset from $REPO..."

  DOWNLOAD_URL="$(curl -s "https://api.github.com/repos/$REPO/releases/latest" \
    | grep browser_download_url \
    | grep "$BINARY_NAME" \
    | sed -E 's/.*"([^"]+)".*/\1/' \
    | head -n 1)"

  if [ -z "$DOWNLOAD_URL" ]; then
    echo "Could not find release asset named $BINARY_NAME."
    echo "Please install display_disable manually, then rerun this installer."
    exit 1
  fi

  TMP_FILE="$(mktemp)"
  curl -L -o "$TMP_FILE" "$DOWNLOAD_URL"
  chmod +x "$TMP_FILE"

  echo "Installing to $INSTALL_PATH"
  sudo mv "$TMP_FILE" "$INSTALL_PATH"
}

show_detected_displays() {
  echo
  echo "Detected displays from display_disable:"
  echo
  "$INSTALL_PATH" list
  echo

  echo "Detected displays from system_profiler:"
  echo
  /usr/sbin/system_profiler SPDisplaysDataType | awk '
    /Displays:/ { in_displays=1; print; next }
    in_displays { print }
  '
  echo
}

detect_builtin_display_id() {
  local output="$1"

  local detected_id
  detected_id="$(echo "$output" | awk '
    /Display [0-9]+:/ {
      id=""
    }

    /ID:/ {
      line=$0
      sub(/^.*\(/, "", line)
      sub(/\).*$/, "", line)
      id=line
    }

    /Built-in: YES/ {
      print id
      exit
    }
  ')"

  echo "$detected_id"
}

detect_system_profiler_display_names() {
  /usr/sbin/system_profiler SPDisplaysDataType | awk '
    /Displays:/ { in_displays=1; next }

    in_displays && /^[[:space:]]{8}[^[:space:]].*:$/ {
      name=$0
      sub(/^[[:space:]]+/, "", name)
      sub(/:$/, "", name)
      print name
    }
  '
}

escape_regex_name() {
  echo "$1" | sed -E 's/[][(){}.^$+*?|\\]/\\&/g'
}

build_trusted_external_names_regex() {
  local display_names="$1"

  local trusted=""
  local line
  local escaped

  while IFS= read -r line; do
    if [ -z "$line" ]; then
      continue
    fi

    # Color LCD is Apple's usual built-in display name.
    if [ "$line" = "Color LCD" ]; then
      continue
    fi

    # Generic names are treated as suspicious, not trusted.
    if [ "$line" = "Display" ] || [ "$line" = "Unknown Display" ]; then
      continue
    fi

    escaped="$(escape_regex_name "$line")"

    if [ -z "$trusted" ]; then
      trusted="$escaped"
    else
      trusted="$trusted|$escaped"
    fi
  done <<< "$display_names"

  echo "$trusted"
}

add_or_replace_alias() {
  local alias_name="$1"
  local alias_command="$2"

  touch "$ZSHRC"
  cp "$ZSHRC" "$ZSHRC.displaydisabler.bak"

  sed -i.tmp "/^alias ${alias_name}=/d" "$ZSHRC"
  rm -f "$ZSHRC.tmp"

  echo "alias ${alias_name}=\"${alias_command}\"" >> "$ZSHRC"
}

write_watchdog_config() {
  local builtin_id="$1"
  local trusted_external_names="$2"
  local confirmations="$3"
  local enable_logging="$4"
  local debug_logging="$5"
  local max_log_size_kb="$6"

  cat > "$CONFIG_FILE" <<EOF_CONFIG
# DisplayDisabler watchdog configuration
#
# BUILTIN_ID is the numeric display ID used by display_disable.
# TRUSTED_EXTERNAL_NAMES is an extended regular expression of external display
# names that are considered safe while the built-in display is disabled.
# SUSPICIOUS_DISPLAY_NAMES are generic/fallback names that may appear after a
# disconnect event.
# CHECK_CONFIRMATIONS controls how many consecutive unsafe checks are required
# before re-enabling the built-in display.
# ENABLE_LOGGING=1 writes lightweight logs to ~/Library/Logs/displaydisabler-watchdog.log.
# DEBUG_LOGGING=1 also writes full command output from display_disable and system_profiler.
# MAX_LOG_SIZE_KB rotates the log when it reaches this size. One backup is kept as .1.

BUILTIN_ID="$builtin_id"
TRUSTED_EXTERNAL_NAMES="$trusted_external_names"
SUSPICIOUS_DISPLAY_NAMES="Display|Unknown Display"
CHECK_CONFIRMATIONS="$confirmations"
ENABLE_LOGGING="$enable_logging"
DEBUG_LOGGING="$debug_logging"
MAX_LOG_SIZE_KB="$max_log_size_kb"
EOF_CONFIG

  echo
  echo "Created watchdog config:"
  echo "  $CONFIG_FILE"
}

install_trust_script() {
  mkdir -p "$SCRIPTS_DIR"

  cp "$TRUST_SCRIPT_SOURCE" "$TRUST_SCRIPT_TARGET"
  chmod +x "$TRUST_SCRIPT_TARGET"

  echo
  echo "Trust-displays helper installed:"
  echo "  $TRUST_SCRIPT_TARGET"
}

install_watchdog() {
  local interval="$1"

  mkdir -p "$SCRIPTS_DIR"
  mkdir -p "$LAUNCH_AGENTS_DIR"

  cp "$WATCHDOG_SOURCE" "$WATCHDOG_TARGET"
  chmod +x "$WATCHDOG_TARGET"

  cat > "$PLIST_PATH" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.displaydisabler.watchdog</string>

    <key>ProgramArguments</key>
    <array>
      <string>$WATCHDOG_TARGET</string>
    </array>

    <key>StartInterval</key>
    <integer>$interval</integer>

    <key>RunAtLoad</key>
    <true/>
  </dict>
</plist>
EOF_PLIST

  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/com.displaydisabler.watchdog"
  launchctl kickstart -k "gui/$(id -u)/com.displaydisabler.watchdog"

  echo
  echo "Watchdog installed:"
  echo "  $PLIST_PATH"
}

cleanup_old_watchdog_names() {
  local old_plist="$LAUNCH_AGENTS_DIR/com.displaydisabler.auto-enable-builtin.plist"
  local old_script="$SCRIPTS_DIR/auto_enable_builtin_on_external_disconnect.sh"

  if [ -f "$old_plist" ]; then
    launchctl bootout "gui/$(id -u)" "$old_plist" 2>/dev/null || true
    rm -f "$old_plist"
    echo "Removed old LaunchAgent name:"
    echo "  $old_plist"
  fi

  if [ -f "$old_script" ]; then
    rm -f "$old_script"
    echo "Removed old watchdog script name:"
    echo "  $old_script"
  fi
}

cleanup_old_watchdog_names

install_binary_if_missing

DD_OUTPUT="$($INSTALL_PATH list 2>/dev/null)"
SP_DISPLAY_NAMES="$(detect_system_profiler_display_names)"

show_detected_displays

BUILTIN_ID="$(detect_builtin_display_id "$DD_OUTPUT")"

if [ -z "$BUILTIN_ID" ]; then
  echo "Could not automatically detect the built-in display."
  echo
  read "BUILTIN_ID?Enter built-in display ID manually: "
fi

if [ -z "$BUILTIN_ID" ]; then
  echo "No built-in display ID provided. Aborting."
  exit 1
fi

TRUSTED_EXTERNAL_NAMES="$(build_trusted_external_names_regex "$SP_DISPLAY_NAMES")"

echo "Built-in display ID: $BUILTIN_ID"

if [ -n "$TRUSTED_EXTERNAL_NAMES" ]; then
  echo "Trusted external display names regex: $TRUSTED_EXTERNAL_NAMES"
else
  echo "No trusted external display names detected."
  echo "If your external monitor is currently connected but appears only as 'Display',"
  echo "you may need to edit $CONFIG_FILE manually after installation."
fi

echo

read "OFF_ALIAS?Alias to disable built-in display [s-off]: "
OFF_ALIAS="${OFF_ALIAS:-s-off}"

read "ON_ALIAS?Alias to enable built-in display [s-on]: "
ON_ALIAS="${ON_ALIAS:-s-on}"

install_trust_script

read "TRUST_ALIAS?Alias to trust currently connected external displays [trust-displays]: "
TRUST_ALIAS="${TRUST_ALIAS:-trust-displays}"

add_or_replace_alias "$OFF_ALIAS" "$INSTALL_PATH disable $BUILTIN_ID"
add_or_replace_alias "$ON_ALIAS" "$INSTALL_PATH enable $BUILTIN_ID"
add_or_replace_alias "$TRUST_ALIAS" "$TRUST_SCRIPT_TARGET"

echo
echo "Aliases added to $ZSHRC:"
echo "  $OFF_ALIAS    -> $INSTALL_PATH disable $BUILTIN_ID"
echo "  $ON_ALIAS     -> $INSTALL_PATH enable $BUILTIN_ID"
echo "  $TRUST_ALIAS  -> $TRUST_SCRIPT_TARGET"

echo
read "INSTALL_WATCHDOG?Install safety watchdog to re-enable built-in display when external display disconnects? [Y/n]: "
INSTALL_WATCHDOG="${INSTALL_WATCHDOG:-Y}"

if [[ "$INSTALL_WATCHDOG" =~ ^[Yy]$ ]]; then
  read "CHECK_INTERVAL?Check interval in seconds [10]: "
  CHECK_INTERVAL="${CHECK_INTERVAL:-10}"

  read "CHECK_CONFIRMATIONS?Unsafe checks before re-enabling built-in display [2]: "
  CHECK_CONFIRMATIONS="${CHECK_CONFIRMATIONS:-2}"

  read "ENABLE_LOGGING?Enable lightweight watchdog logging? [y/N]: "
  ENABLE_LOGGING_ANSWER="${ENABLE_LOGGING:-N}"

  if [[ "$ENABLE_LOGGING_ANSWER" =~ ^[Yy]$ ]]; then
    ENABLE_LOGGING_VALUE="1"

    read "DEBUG_LOGGING?Enable verbose debug logging? [y/N]: "
    DEBUG_LOGGING_ANSWER="${DEBUG_LOGGING:-N}"

    if [[ "$DEBUG_LOGGING_ANSWER" =~ ^[Yy]$ ]]; then
      DEBUG_LOGGING_VALUE="1"
    else
      DEBUG_LOGGING_VALUE="0"
    fi

    read "MAX_LOG_SIZE_KB?Max log size before rotation in KB [1024]: "
    MAX_LOG_SIZE_KB="${MAX_LOG_SIZE_KB:-1024}"
  else
    ENABLE_LOGGING_VALUE="0"
    DEBUG_LOGGING_VALUE="0"
    MAX_LOG_SIZE_KB="1024"
  fi

  write_watchdog_config "$BUILTIN_ID" "$TRUSTED_EXTERNAL_NAMES" "$CHECK_CONFIRMATIONS" "$ENABLE_LOGGING_VALUE" "$DEBUG_LOGGING_VALUE" "$MAX_LOG_SIZE_KB"
  install_watchdog "$CHECK_INTERVAL"
else
  echo "Watchdog not installed."
fi

echo
echo "Done."
echo
echo "Reload your shell:"
echo "  source ~/.zshrc"
echo
echo "Then use:"
echo "  $OFF_ALIAS"
echo "  $ON_ALIAS"
echo
echo "If the watchdog was installed, logs are available at:"
echo "  ~/Library/Logs/displaydisabler-watchdog.log"
echo
