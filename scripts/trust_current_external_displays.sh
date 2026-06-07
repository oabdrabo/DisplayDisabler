#!/bin/zsh

set -e

CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Config file not found: $CONFIG_FILE"
  echo "Run ./scripts/install_smart.sh first."
  exit 1
fi

escape_regex_name() {
  echo "$1" | sed -E 's/[][(){}.^$+*?|\\]/\\&/g'
}

CURRENT_EXTERNAL_NAMES="$(/usr/sbin/system_profiler SPDisplaysDataType | awk '
  /Displays:/ { in_displays=1; next }

  in_displays && /^[[:space:]]{8}[^[:space:]].*:$/ {
    name=$0
    sub(/^[[:space:]]+/, "", name)
    sub(/:$/, "", name)
    print name
  }
' | grep -v "^Color LCD$" | grep -v "^Display$" | grep -v "^Unknown Display$" || true)"

if [ -z "$CURRENT_EXTERNAL_NAMES" ]; then
  echo "No stable external display names detected."
  echo
  echo "Displays named 'Display' or 'Unknown Display' are not added automatically"
  echo "because they are treated as suspicious fallback names."
  echo
  echo "You can edit the config manually if needed:"
  echo "  $CONFIG_FILE"
  exit 1
fi

CURRENT_REGEX=""

while IFS= read -r name; do
  escaped="$(escape_regex_name "$name")"

  if [ -z "$CURRENT_REGEX" ]; then
    CURRENT_REGEX="$escaped"
  else
    CURRENT_REGEX="$CURRENT_REGEX|$escaped"
  fi
done <<< "$CURRENT_EXTERNAL_NAMES"

EXISTING_REGEX="$(grep '^TRUSTED_EXTERNAL_NAMES=' "$CONFIG_FILE" | sed -E 's/^TRUSTED_EXTERNAL_NAMES="(.*)"$/\1/' || true)"

if [ -z "$EXISTING_REGEX" ]; then
  NEW_REGEX="$CURRENT_REGEX"
else
  NEW_REGEX="$EXISTING_REGEX|$CURRENT_REGEX"
fi

NEW_REGEX="$(echo "$NEW_REGEX" | tr '|' '\n' | awk 'NF && !seen[$0]++' | paste -sd '|' -)"

cp "$CONFIG_FILE" "$CONFIG_FILE.bak"

perl -pi -e "s|^TRUSTED_EXTERNAL_NAMES=.*|TRUSTED_EXTERNAL_NAMES=\"$NEW_REGEX\"|" "$CONFIG_FILE"

echo "Trusted external display names updated:"
echo "  $NEW_REGEX"
echo
echo "Backup created:"
echo "  $CONFIG_FILE.bak"
