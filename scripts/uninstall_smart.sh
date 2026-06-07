#!/bin/zsh

set -e

ZSHRC="$HOME/.zshrc"
CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"
PLIST_PATH="$HOME/Library/LaunchAgents/com.displaydisabler.watchdog.plist"
WATCHDOG_SCRIPT="$HOME/Scripts/DisplayDisabler-Watchdog"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/com.displaydisabler.watchdog.plist"
OLD_WATCHDOG_SCRIPT="$HOME/Scripts/DisplayDisabler-Watchdog"
OLD_PLIST_PATH="$HOME/Library/LaunchAgents/com.displaydisabler.auto-enable-builtin.plist"
OLD_WATCHDOG_SCRIPT="$HOME/Scripts/auto_enable_builtin_on_external_disconnect.sh"
TRUST_SCRIPT="$HOME/Scripts/trust_current_external_displays.sh"
LOG_FILE="$HOME/Library/Logs/displaydisabler-watchdog.log"
STATE_FILE="$HOME/Library/Logs/displaydisabler-watchdog-suspicious-count"

echo
echo "DisplayDisabler Smart Uninstaller"
echo "----------------------------------"
echo

if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
  echo "Removed LaunchAgent."
else
  echo "No LaunchAgent found."
fi

if [ -f "$OLD_PLIST_PATH" ]; then
  launchctl bootout "gui/$(id -u)" "$OLD_PLIST_PATH" 2>/dev/null || true
  rm -f "$OLD_PLIST_PATH"
  echo "Removed old LaunchAgent."
fi

if [ -f "$WATCHDOG_SCRIPT" ]; then
  rm -f "$WATCHDOG_SCRIPT"
  echo "Removed watchdog script."
else
  echo "No watchdog script found."
fi

if [ -f "$OLD_WATCHDOG_SCRIPT" ]; then
  rm -f "$OLD_WATCHDOG_SCRIPT"
  echo "Removed old watchdog script."
fi

if [ -f "$TRUST_SCRIPT" ]; then
  rm -f "$TRUST_SCRIPT"
  echo "Removed trust-displays script."
else
  echo "No trust-displays script found."
fi

if [ -f "$CONFIG_FILE" ]; then
  rm -f "$CONFIG_FILE"
  echo "Removed watchdog config."
else
  echo "No watchdog config found."
fi

if [ -f "$STATE_FILE" ]; then
  rm -f "$STATE_FILE"
  echo "Removed watchdog state file."
fi

if [ -f "$ZSHRC" ]; then
  cp "$ZSHRC" "$ZSHRC.displaydisabler-uninstall.bak"

  sed -i.tmp '/display_disable disable/d' "$ZSHRC"
  sed -i.tmp '/display_disable enable/d' "$ZSHRC"
  sed -i.tmp '/trust_current_external_displays.sh/d' "$ZSHRC"
  sed -i.tmp '/DisplayDisabler-Watchdog/d' "$ZSHRC"
  rm -f "$ZSHRC.tmp"

  echo "Removed display_disable aliases from $ZSHRC."
  echo "Backup created: $ZSHRC.displaydisabler-uninstall.bak"
fi

echo
read "REMOVE_LOG?Remove watchdog log file? [y/N]: "
REMOVE_LOG="${REMOVE_LOG:-N}"

if [[ "$REMOVE_LOG" =~ ^[Yy]$ ]]; then
  rm -f "$LOG_FILE"
  echo "Removed watchdog log file."
fi

BINARY_PATH="/usr/local/bin/display_disable"

if [ -f "$BINARY_PATH" ]; then
  sudo rm "$BINARY_PATH"
  echo "Removed display_disable binary:"
  echo "  $BINARY_PATH"
else
  echo "No display_disable binary found."
fi

echo
echo "Done."
echo
