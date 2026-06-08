#!/bin/zsh

# Shared helpers for the lightweight smart installer/watchdog scripts.
# Keep this file side-effect free: callers decide when to read hardware,
# write files, or invoke display_disable.

dd_init_defaults() {
  DISPLAY_DISABLE="${DISPLAY_DISABLE:-/usr/local/bin/display_disable}"
  DD_APP_PATH="${DD_APP_PATH:-/Applications/DisplayDisabler.app}"
  DD_CONFIG_FILE="${DD_CONFIG_FILE:-$HOME/.displaydisabler-watchdog.conf}"
  DD_LOG_FILE="${DD_LOG_FILE:-$HOME/Library/Logs/displaydisabler-watchdog.log}"
  DD_STATE_FILE="${DD_STATE_FILE:-$HOME/Library/Logs/displaydisabler-watchdog-suspicious-count}"
  DD_WATCHDOG_LABEL="${DD_WATCHDOG_LABEL:-com.displaydisabler.watchdog}"
  DD_PLIST_PATH="${DD_PLIST_PATH:-$HOME/Library/LaunchAgents/$DD_WATCHDOG_LABEL.plist}"

  DD_INSTALL_PROFILE="${DD_INSTALL_PROFILE:-}"
  BUILTIN_ID="${BUILTIN_ID:-1}"
  TRUSTED_EXTERNAL_NAMES="${TRUSTED_EXTERNAL_NAMES:-}"
  SUSPICIOUS_DISPLAY_NAMES="${SUSPICIOUS_DISPLAY_NAMES:-Display|Unknown Display}"
  CHECK_CONFIRMATIONS="${CHECK_CONFIRMATIONS:-2}"
  ENABLE_LOGGING="${ENABLE_LOGGING:-0}"
  DEBUG_LOGGING="${DEBUG_LOGGING:-0}"
  MAX_LOG_SIZE_KB="${MAX_LOG_SIZE_KB:-1024}"
}

dd_source_config() {
  dd_init_defaults
  if [ -f "$DD_CONFIG_FILE" ]; then
    source "$DD_CONFIG_FILE"
  fi
  dd_init_defaults
}

dd_escape_regex_name() {
  echo "$1" | sed -E 's/[][(){}.^$+*?|\\]/\\&/g'
}

dd_nonempty_line_count() {
  sed '/^[[:space:]]*$/d' | wc -l | tr -d ' '
}

dd_display_names_from_system_profiler_output() {
  awk '
    /Displays:/ { in_displays=1; next }

    in_displays && /^[[:space:]]{8}[^[:space:]].*:$/ {
      name=$0
      sub(/^[[:space:]]+/, "", name)
      sub(/:$/, "", name)
      print name
    }
  '
}

dd_external_display_names_from_names() {
  grep -v "^Color LCD$" | sed '/^[[:space:]]*$/d' || true
}

dd_trusted_external_names_regex_from_names() {
  local trusted=""
  local line
  local escaped

  while IFS= read -r line; do
    if [ -z "$line" ]; then
      continue
    fi

    if [ "$line" = "Color LCD" ]; then
      continue
    fi

    if [ "$line" = "Display" ] || [ "$line" = "Unknown Display" ]; then
      continue
    fi

    escaped="$(dd_escape_regex_name "$line")"

    if [ -z "$trusted" ]; then
      trusted="$escaped"
    else
      trusted="$trusted|$escaped"
    fi
  done

  echo "$trusted"
}

dd_match_count() {
  local names="$1"
  local regex="$2"

  if [ -z "$regex" ]; then
    echo 0
    return
  fi

  echo "$names" | grep -E -c "^(${regex})$" || true
}

dd_active_section_from_display_disable_output() {
  awk '
    /=== Active Displays ===/ { flag=1; next }
    /^=== / && flag { flag=0 }
    flag
  '
}

dd_builtin_display_id_from_display_disable_output() {
  awk '
    /Display [0-9]+:/ {
      id=""
    }

    /ID:/ {
      line=$0
      if (line ~ /\([^)]+\)/) {
        sub(/^.*\(/, "", line)
        sub(/\).*$/, "", line)
        id=line
      } else {
        sub(/^.*ID:[[:space:]]*/, "", line)
        sub(/[[:space:]].*$/, "", line)
        id=line
      }
    }

    /Built-in: YES/ {
      print id
      exit
    }
  '
}

dd_active_display_count_from_display_disable_output() {
  dd_active_section_from_display_disable_output | awk '
    /Display [0-9]+:/ { count++ }
    END { print count + 0 }
  '
}

dd_builtin_active_count_from_display_disable_output() {
  dd_active_section_from_display_disable_output | grep -c "Built-in: YES" || true
}

dd_join_regex_unique() {
  tr '|' '\n' | awk 'NF && !seen[$0]++' | paste -sd '|' -
}

dd_write_trusted_regex_to_config() {
  local config_file="$1"
  local new_regex="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v new_regex="$new_regex" '
    BEGIN { written=0 }
    /^TRUSTED_EXTERNAL_NAMES=/ {
      print "TRUSTED_EXTERNAL_NAMES=\"" new_regex "\""
      written=1
      next
    }
    { print }
    END {
      if (!written) {
        print "TRUSTED_EXTERNAL_NAMES=\"" new_regex "\""
      }
    }
  ' "$config_file" > "$tmp_file"

  mv "$tmp_file" "$config_file"
}
