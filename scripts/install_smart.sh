#!/bin/zsh

set -e

REPO="oabdrabo/DisplayDisabler"
BINARY_NAME="display_disable"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"

ZSHRC="$HOME/.zshrc"
SCRIPTS_DIR="$HOME/Scripts"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_SOURCE="$SCRIPT_DIR/lib/displaydisabler_smart_lib.sh"
SMART_SOURCE="$SCRIPT_DIR/displaydisabler_smart.sh"
SAFE_SOURCE="$SCRIPT_DIR/safe_disable_builtin.sh"
WATCHDOG_SOURCE="$SCRIPT_DIR/auto_enable_builtin_on_external_disconnect.sh"
TRUST_SCRIPT_SOURCE="$SCRIPT_DIR/trust_current_external_displays.sh"

LIB_TARGET="$SCRIPTS_DIR/displaydisabler_smart_lib.sh"
SMART_TARGET="$SCRIPTS_DIR/displaydisabler-smart"
SAFE_TARGET="$SCRIPTS_DIR/safe_disable_builtin.sh"
WATCHDOG_TARGET="$SCRIPTS_DIR/DisplayDisabler-Watchdog"
TRUST_SCRIPT_TARGET="$SCRIPTS_DIR/trust_current_external_displays.sh"

CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"
WATCHDOG_LABEL="com.displaydisabler.watchdog"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$WATCHDOG_LABEL.plist"

ALIAS_BEGIN="# >>> DisplayDisabler smart aliases >>>"
ALIAS_END="# <<< DisplayDisabler smart aliases <<<"

DRY_RUN="0"
NO_WATCHDOG="0"
NO_DOWNLOAD="0"
ASSUME_YES="0"
REPAIR="0"

usage() {
  cat <<EOF_USAGE
Usage: ./scripts/install_smart.sh [options]

Options:
  --dry-run       Show planned writes without changing files
  --repair        Reinstall helper files, aliases and LaunchAgent using defaults
  --no-watchdog   Install aliases/helpers but skip the safety LaunchAgent
  --no-download   Do not download display_disable if it is missing
  --yes           Use default answers for prompts
  -h, --help      Show this help
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN="1"
      ;;
    --repair)
      REPAIR="1"
      ASSUME_YES="1"
      ;;
    --no-watchdog)
      NO_WATCHDOG="1"
      ;;
    --no-download)
      NO_DOWNLOAD="1"
      ;;
    --yes)
      ASSUME_YES="1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

source "$LIB_SOURCE"
DISPLAY_DISABLE="$INSTALL_PATH"
DD_CONFIG_FILE="$CONFIG_FILE"
DD_PLIST_PATH="$PLIST_PATH"
DD_WATCHDOG_LABEL="$WATCHDOG_LABEL"
dd_source_config

echo
echo "DisplayDisabler Smart Installer"
echo "--------------------------------"
if [ "$DRY_RUN" = "1" ]; then
  echo "Mode: dry run"
elif [ "$REPAIR" = "1" ]; then
  echo "Mode: repair"
fi
echo

run_or_echo() {
  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

prompt_default() {
  local __var="$1"
  local prompt="$2"
  local default="$3"
  local answer

  if [ "$ASSUME_YES" = "1" ]; then
    echo "$prompt [$default]: $default"
    eval "$__var=\"\$default\""
    return
  fi

  read "answer?$prompt [$default]: "
  answer="${answer:-$default}"
  eval "$__var=\"\$answer\""
}

validate_alias_name() {
  local alias_name="$1"
  if [[ ! "$alias_name" =~ '^[A-Za-z0-9_][A-Za-z0-9_-]*$' ]]; then
    echo "Invalid alias name: $alias_name" >&2
    exit 1
  fi
}

validate_positive_int() {
  local value="$1"
  local label="$2"
  if [[ ! "$value" =~ '^[0-9]+$' ]] || [ "$value" -lt 1 ]; then
    echo "$label must be a positive integer." >&2
    exit 1
  fi
}

install_binary_if_missing() {
  if [ -x "$INSTALL_PATH" ]; then
    echo "Found existing binary: $INSTALL_PATH"
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would download latest release asset from $REPO"
    echo "[dry-run] Would install it to $INSTALL_PATH"
    return
  fi

  if [ "$NO_DOWNLOAD" = "1" ]; then
    echo "$BINARY_NAME not found at $INSTALL_PATH and --no-download was set." >&2
    echo "Install display_disable manually, then rerun this installer." >&2
    exit 1
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

collect_display_disable_output() {
  if [ ! -x "$INSTALL_PATH" ]; then
    DD_OUTPUT=""
    return
  fi

  DD_OUTPUT="$("$INSTALL_PATH" list 2>/dev/null || true)"
}

collect_system_profiler_names() {
  local sp_output=""

  if [ ! -x /usr/sbin/system_profiler ]; then
    SP_DISPLAY_NAMES=""
    return
  fi

  sp_output="$(/usr/sbin/system_profiler SPDisplaysDataType 2>/dev/null || true)"
  SP_DISPLAY_NAMES="$(echo "$sp_output" | dd_display_names_from_system_profiler_output)"
}

show_detected_displays() {
  if [ -x "$INSTALL_PATH" ]; then
    echo
    echo "Detected displays from display_disable:"
    echo
    "$INSTALL_PATH" list || true
    echo
  fi

  if [ -x /usr/sbin/system_profiler ]; then
    echo "Detected displays from system_profiler:"
    echo
    /usr/sbin/system_profiler SPDisplaysDataType | awk '
      /Displays:/ { in_displays=1; print; next }
      in_displays { print }
    '
    echo
  fi
}

write_watchdog_config() {
  local builtin_id="$1"
  local trusted_external_names="$2"
  local confirmations="$3"
  local enable_logging="$4"
  local debug_logging="$5"
  local max_log_size_kb="$6"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would write watchdog config: $CONFIG_FILE"
    echo "[dry-run] BUILTIN_ID=$builtin_id TRUSTED_EXTERNAL_NAMES=$trusted_external_names"
    return
  fi

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

install_helper() {
  local source_path="$1"
  local target_path="$2"
  local mode="$3"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would install $target_path"
    return
  fi

  mkdir -p "$SCRIPTS_DIR"
  cp "$source_path" "$target_path"
  chmod "$mode" "$target_path"
}

install_helpers() {
  install_helper "$LIB_SOURCE" "$LIB_TARGET" 644
  install_helper "$SMART_SOURCE" "$SMART_TARGET" 755
  install_helper "$SAFE_SOURCE" "$SAFE_TARGET" 755
  install_helper "$TRUST_SCRIPT_SOURCE" "$TRUST_SCRIPT_TARGET" 755

  echo
  echo "Smart helpers installed:"
  echo "  $SMART_TARGET"
  echo "  $SAFE_TARGET"
  echo "  $TRUST_SCRIPT_TARGET"
}

write_alias_block() {
  local off_alias="$1"
  local on_alias="$2"
  local trust_alias="$3"
  local status_alias="$4"
  local tmp_file

  validate_alias_name "$off_alias"
  validate_alias_name "$on_alias"
  validate_alias_name "$trust_alias"
  validate_alias_name "$status_alias"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would update alias block in $ZSHRC"
    echo "[dry-run] alias $off_alias=\"$SAFE_TARGET\""
    echo "[dry-run] alias $on_alias=\"$INSTALL_PATH enable $BUILTIN_ID\""
    echo "[dry-run] alias $trust_alias=\"$SMART_TARGET trust\""
    echo "[dry-run] alias $status_alias=\"$SMART_TARGET status\""
    return
  fi

  touch "$ZSHRC"
  cp "$ZSHRC" "$ZSHRC.displaydisabler.bak"
  tmp_file="$(mktemp)"

  awk -v begin="$ALIAS_BEGIN" -v end="$ALIAS_END" \
      -v off_alias="$off_alias" -v on_alias="$on_alias" \
      -v trust_alias="$trust_alias" -v status_alias="$status_alias" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    $0 ~ "^alias " off_alias "=" { next }
    $0 ~ "^alias " on_alias "=" { next }
    $0 ~ "^alias " trust_alias "=" { next }
    $0 ~ "^alias " status_alias "=" { next }
    !skip { print }
  ' "$ZSHRC" > "$tmp_file"

  {
    echo "$ALIAS_BEGIN"
    echo "alias ${off_alias}=\"$SAFE_TARGET\""
    echo "alias ${on_alias}=\"$INSTALL_PATH enable $BUILTIN_ID\""
    echo "alias ${trust_alias}=\"$SMART_TARGET trust\""
    echo "alias ${status_alias}=\"$SMART_TARGET status\""
    echo "$ALIAS_END"
  } >> "$tmp_file"

  mv "$tmp_file" "$ZSHRC"
}

install_watchdog() {
  local interval="$1"

  validate_positive_int "$interval" "Check interval"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would install watchdog script: $WATCHDOG_TARGET"
    echo "[dry-run] Would write LaunchAgent: $PLIST_PATH"
    return
  fi

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
    <string>$WATCHDOG_LABEL</string>

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

  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$PLIST_PATH" >/dev/null
  fi

  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
  launchctl enable "gui/$(id -u)/$WATCHDOG_LABEL"
  launchctl kickstart -k "gui/$(id -u)/$WATCHDOG_LABEL"

  echo
  echo "Watchdog installed:"
  echo "  $PLIST_PATH"
}

cleanup_old_watchdog_names() {
  local old_plist="$LAUNCH_AGENTS_DIR/com.displaydisabler.auto-enable-builtin.plist"
  local old_script="$SCRIPTS_DIR/auto_enable_builtin_on_external_disconnect.sh"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would remove old watchdog names if present"
    return
  fi

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
collect_display_disable_output
collect_system_profiler_names

if [ "$ASSUME_YES" != "1" ]; then
  show_detected_displays
fi

DETECTED_BUILTIN_ID="$(echo "$DD_OUTPUT" | dd_builtin_display_id_from_display_disable_output)"
if [ -n "$DETECTED_BUILTIN_ID" ]; then
  BUILTIN_ID="$DETECTED_BUILTIN_ID"
fi

if [ -z "$BUILTIN_ID" ]; then
  echo "Could not automatically detect the built-in display."
  echo
  prompt_default BUILTIN_ID "Enter built-in display ID manually" ""
fi

if [ -z "$BUILTIN_ID" ]; then
  echo "No built-in display ID provided. Aborting."
  exit 1
fi

DETECTED_TRUSTED_EXTERNAL_NAMES="$(echo "$SP_DISPLAY_NAMES" | dd_trusted_external_names_regex_from_names)"
if [ -n "$DETECTED_TRUSTED_EXTERNAL_NAMES" ]; then
  if [ -n "$TRUSTED_EXTERNAL_NAMES" ]; then
    TRUSTED_EXTERNAL_NAMES="$(printf '%s|%s\n' "$TRUSTED_EXTERNAL_NAMES" "$DETECTED_TRUSTED_EXTERNAL_NAMES" | dd_join_regex_unique)"
  else
    TRUSTED_EXTERNAL_NAMES="$DETECTED_TRUSTED_EXTERNAL_NAMES"
  fi
fi

echo "Built-in display ID: $BUILTIN_ID"
if [ -n "$TRUSTED_EXTERNAL_NAMES" ]; then
  echo "Trusted external display names regex: $TRUSTED_EXTERNAL_NAMES"
else
  echo "No trusted external display names detected."
  echo "If your external monitor is currently connected but appears only as 'Display',"
  echo "you may need to edit $CONFIG_FILE manually after installation."
fi

echo
prompt_default OFF_ALIAS "Alias to safely disable built-in display" "s-off"
prompt_default ON_ALIAS "Alias to enable built-in display" "s-on"
prompt_default TRUST_ALIAS "Alias to trust currently connected external displays" "trust-displays"
prompt_default STATUS_ALIAS "Alias to show smart setup status" "dd-status"

prompt_default CHECK_CONFIRMATIONS "Unsafe checks before re-enabling built-in display" "$CHECK_CONFIRMATIONS"
validate_positive_int "$CHECK_CONFIRMATIONS" "Unsafe checks"

if [ "$ENABLE_LOGGING" = "1" ]; then
  ENABLE_LOGGING_DEFAULT="Y"
else
  ENABLE_LOGGING_DEFAULT="N"
fi

prompt_default ENABLE_LOGGING_ANSWER "Enable lightweight watchdog logging? y/N" "$ENABLE_LOGGING_DEFAULT"
if [[ "$ENABLE_LOGGING_ANSWER" =~ '^[Yy]$' ]]; then
  ENABLE_LOGGING_VALUE="1"
  if [ "$DEBUG_LOGGING" = "1" ]; then
    DEBUG_LOGGING_DEFAULT="Y"
  else
    DEBUG_LOGGING_DEFAULT="N"
  fi
  prompt_default DEBUG_LOGGING_ANSWER "Enable verbose debug logging? y/N" "$DEBUG_LOGGING_DEFAULT"
  if [[ "$DEBUG_LOGGING_ANSWER" =~ '^[Yy]$' ]]; then
    DEBUG_LOGGING_VALUE="1"
  else
    DEBUG_LOGGING_VALUE="0"
  fi
  prompt_default MAX_LOG_SIZE_KB "Max log size before rotation in KB" "$MAX_LOG_SIZE_KB"
  validate_positive_int "$MAX_LOG_SIZE_KB" "Max log size"
else
  ENABLE_LOGGING_VALUE="0"
  DEBUG_LOGGING_VALUE="0"
  MAX_LOG_SIZE_KB="1024"
fi

write_watchdog_config "$BUILTIN_ID" "$TRUSTED_EXTERNAL_NAMES" "$CHECK_CONFIRMATIONS" "$ENABLE_LOGGING_VALUE" "$DEBUG_LOGGING_VALUE" "$MAX_LOG_SIZE_KB"
install_helpers
write_alias_block "$OFF_ALIAS" "$ON_ALIAS" "$TRUST_ALIAS" "$STATUS_ALIAS"

if [ "$NO_WATCHDOG" = "1" ]; then
  echo
  echo "Watchdog skipped because --no-watchdog was set."
else
  prompt_default INSTALL_WATCHDOG "Install safety watchdog to re-enable built-in display when external display disconnects? Y/n" "Y"
  if [[ "$INSTALL_WATCHDOG" =~ '^[Yy]$' ]]; then
    prompt_default CHECK_INTERVAL "Check interval in seconds" "10"
    install_watchdog "$CHECK_INTERVAL"
  else
    echo "Watchdog not installed."
  fi
fi

echo
echo "Aliases added to $ZSHRC:"
echo "  $OFF_ALIAS     -> $SAFE_TARGET"
echo "  $ON_ALIAS      -> $INSTALL_PATH enable $BUILTIN_ID"
echo "  $TRUST_ALIAS   -> $SMART_TARGET trust"
echo "  $STATUS_ALIAS  -> $SMART_TARGET status"
echo
echo "Reload your shell:"
echo "  source ~/.zshrc"
echo
echo "Then use:"
echo "  $OFF_ALIAS"
echo "  $ON_ALIAS"
echo "  $STATUS_ALIAS"
echo
