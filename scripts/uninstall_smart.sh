#!/bin/zsh

set -e

ZSHRC="$HOME/.zshrc"
SCRIPTS_DIR="$HOME/Scripts"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
APP_NAME="DisplayDisabler"
APP_BUNDLE="$APP_NAME.app"
APP_INSTALL_PATH="${APP_INSTALL_PATH:-/Applications/$APP_BUNDLE}"

CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"
WATCHDOG_LABEL="com.displaydisabler.watchdog"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$WATCHDOG_LABEL.plist"
OLD_PLIST_PATH="$LAUNCH_AGENTS_DIR/com.displaydisabler.auto-enable-builtin.plist"

WATCHDOG_SCRIPT="$SCRIPTS_DIR/DisplayDisabler-Watchdog"
OLD_WATCHDOG_SCRIPT="$SCRIPTS_DIR/auto_enable_builtin_on_external_disconnect.sh"
SMART_SCRIPT="$SCRIPTS_DIR/displaydisabler-smart"
SAFE_SCRIPT="$SCRIPTS_DIR/safe_disable_builtin.sh"
TRUST_SCRIPT="$SCRIPTS_DIR/trust_current_external_displays.sh"
LIB_SCRIPT="$SCRIPTS_DIR/displaydisabler_smart_lib.sh"

LOG_FILE="$HOME/Library/Logs/displaydisabler-watchdog.log"
STATE_FILE="$HOME/Library/Logs/displaydisabler-watchdog-suspicious-count"
BINARY_PATH="${BINARY_PATH:-/usr/local/bin/display_disable}"

ALIAS_BEGIN="# >>> DisplayDisabler smart aliases >>>"
ALIAS_END="# <<< DisplayDisabler smart aliases <<<"

DRY_RUN="0"
ASSUME_YES="0"
UNINSTALL_PROFILE=""
KEEP_APP="0"
KEEP_BINARY="0"
KEEP_CONFIG="0"
KEEP_LOGS="0"

usage() {
  cat <<EOF_USAGE
Usage: ./scripts/uninstall_smart.sh [options]

Options:
  --app           Remove the menu-bar app only
  --cli           Remove CLI aliases/helpers only
  --full          Remove both menu-bar app and CLI helpers
  --dry-run       Show planned removals without changing files
  --yes           Use default answers for prompts
  --keep-app      Leave /Applications/DisplayDisabler.app installed
  --keep-binary   Leave /usr/local/bin/display_disable installed
  --keep-config   Leave ~/.displaydisabler-watchdog.conf installed
  --keep-logs     Leave watchdog log files installed
  -h, --help      Show this help
EOF_USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      UNINSTALL_PROFILE="app"
      ;;
    --cli)
      UNINSTALL_PROFILE="cli"
      ;;
    --full)
      UNINSTALL_PROFILE="full"
      ;;
    --dry-run)
      DRY_RUN="1"
      ;;
    --yes)
      ASSUME_YES="1"
      ;;
    --keep-app)
      KEEP_APP="1"
      ;;
    --keep-binary)
      KEEP_BINARY="1"
      ;;
    --keep-config)
      KEEP_CONFIG="1"
      ;;
    --keep-logs)
      KEEP_LOGS="1"
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

echo
echo "DisplayDisabler Smart Uninstaller"
echo "----------------------------------"
if [ "$DRY_RUN" = "1" ]; then
  echo "Mode: dry run"
fi
echo

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

prompt_choice() {
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

normalize_uninstall_profile() {
  local profile="$1"
  case "$profile" in
    app|a|menu|menubar|menu-bar)
      echo "app"
      ;;
    cli|c|shell)
      echo "cli"
      ;;
    full|f|both|all)
      echo "full"
      ;;
    *)
      echo ""
      ;;
  esac
}

remove_file() {
  local target_path="$1"
  local label="$2"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would remove $label: $target_path"
    return
  fi

  if [ -e "$target_path" ]; then
    rm -f "$target_path"
    echo "Removed $label."
  else
    echo "No $label found."
  fi
}

remove_path() {
  local target_path="$1"
  local label="$2"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would remove $label: $target_path"
    return
  fi

  if [ -e "$target_path" ]; then
    rm -rf "$target_path"
    echo "Removed $label."
  else
    echo "No $label found."
  fi
}

bootout_plist() {
  local plist_path="$1"
  local label="$2"

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would unload $label if loaded: $plist_path"
    return
  fi

  if [ -f "$plist_path" ]; then
    launchctl bootout "gui/$(id -u)" "$plist_path" 2>/dev/null || true
  fi
}

remove_aliases() {
  local tmp_file
  local tmp_file_2

  if [ ! -f "$ZSHRC" ]; then
    echo "No $ZSHRC found."
    return
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] Would remove DisplayDisabler alias block and legacy aliases from $ZSHRC"
    return
  fi

  cp "$ZSHRC" "$ZSHRC.displaydisabler-uninstall.bak"
  tmp_file="$(mktemp)"
  tmp_file_2="$(mktemp)"

  awk -v begin="$ALIAS_BEGIN" -v end="$ALIAS_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$ZSHRC" > "$tmp_file"

  awk '
    /display_disable disable/ { next }
    /display_disable enable/ { next }
    /trust_current_external_displays.sh/ { next }
    /DisplayDisabler-Watchdog/ { next }
    /displaydisabler-smart/ { next }
    /safe_disable_builtin.sh/ { next }
    { print }
  ' "$tmp_file" > "$tmp_file_2"

  mv "$tmp_file_2" "$ZSHRC"
  rm -f "$tmp_file"

  echo "Removed display_disable aliases from $ZSHRC."
  echo "Backup created: $ZSHRC.displaydisabler-uninstall.bak"
}

if [ -z "$UNINSTALL_PROFILE" ]; then
  echo "Choose uninstall type:"
  echo "  app  - menu-bar app only"
  echo "  cli  - shell aliases/helpers only"
  echo "  full - app plus CLI fallback"
  echo
  prompt_choice UNINSTALL_PROFILE "Uninstall type: app, cli or full" "full"
fi

UNINSTALL_PROFILE="$(normalize_uninstall_profile "$UNINSTALL_PROFILE")"
if [ -z "$UNINSTALL_PROFILE" ]; then
  echo "Invalid uninstall type. Use app, cli, or full." >&2
  exit 1
fi

echo "Uninstall type: $UNINSTALL_PROFILE"
echo

if [ "$UNINSTALL_PROFILE" = "app" ] || [ "$UNINSTALL_PROFILE" = "full" ]; then
  if [ "$KEEP_APP" = "1" ]; then
    echo "Keeping menu-bar app: $APP_INSTALL_PATH"
  else
    remove_path "$APP_INSTALL_PATH" "menu-bar app"
  fi
fi

if [ "$UNINSTALL_PROFILE" = "cli" ] || [ "$UNINSTALL_PROFILE" = "full" ]; then
  bootout_plist "$PLIST_PATH" "LaunchAgent"
  remove_file "$PLIST_PATH" "LaunchAgent"

  bootout_plist "$OLD_PLIST_PATH" "old LaunchAgent"
  remove_file "$OLD_PLIST_PATH" "old LaunchAgent"

  remove_file "$WATCHDOG_SCRIPT" "watchdog script"
  remove_file "$OLD_WATCHDOG_SCRIPT" "old watchdog script"
  remove_file "$SMART_SCRIPT" "smart command"
  remove_file "$SAFE_SCRIPT" "safe-disable wrapper"
  remove_file "$TRUST_SCRIPT" "trust-displays script"
  remove_file "$LIB_SCRIPT" "smart helper library"

  if [ "$KEEP_CONFIG" = "1" ]; then
    echo "Keeping watchdog config: $CONFIG_FILE"
  else
    remove_file "$CONFIG_FILE" "watchdog config"
  fi

  remove_file "$STATE_FILE" "watchdog state file"
  remove_aliases

  if [ "$KEEP_LOGS" = "1" ]; then
    echo "Keeping watchdog logs."
  else
    prompt_default REMOVE_LOG "Remove watchdog log files? y/N" "N"
    if [[ "$REMOVE_LOG" =~ '^[Yy]$' ]]; then
      remove_file "$LOG_FILE" "watchdog log file"
      remove_file "$LOG_FILE.1" "rotated watchdog log file"
    else
      echo "Keeping watchdog log files."
    fi
  fi

  if [ "$KEEP_BINARY" = "1" ]; then
    echo "Keeping display_disable binary: $BINARY_PATH"
  else
    prompt_default REMOVE_BINARY "Remove display_disable binary from /usr/local/bin? Y/n" "Y"
    if [[ "$REMOVE_BINARY" =~ '^[Yy]$' ]]; then
      if [ "$DRY_RUN" = "1" ]; then
        echo "[dry-run] Would remove binary: $BINARY_PATH"
      elif [ -f "$BINARY_PATH" ]; then
        rm -f "$BINARY_PATH" 2>/dev/null || sudo rm "$BINARY_PATH"
        echo "Removed display_disable binary:"
        echo "  $BINARY_PATH"
      else
        echo "No display_disable binary found."
      fi
    else
      echo "Keeping display_disable binary."
    fi
  fi
fi

echo
echo "Done."
echo
