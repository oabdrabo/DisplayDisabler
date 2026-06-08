#!/bin/zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/lib/displaydisabler_smart_lib.sh" ]; then
  source "$SCRIPT_DIR/lib/displaydisabler_smart_lib.sh"
elif [ -f "$SCRIPT_DIR/displaydisabler_smart_lib.sh" ]; then
  source "$SCRIPT_DIR/displaydisabler_smart_lib.sh"
else
  echo "Missing displaydisabler smart library." >&2
  exit 1
fi

dd_source_config

usage() {
  cat <<EOF_USAGE
Usage: displaydisabler-smart <command>

Commands:
  status             Print current smart setup and display state
  doctor             Run lightweight setup checks; exits non-zero on failures
  safe-disable [id]  Disable the built-in display only when another display is active
  trust              Add currently connected stable external displays to the trusted list
  help               Show this help
EOF_USAGE
}

run_display_disable_list() {
  local __out_var="$1"
  local __status_var="$2"
  local output
  local cmd_status

  if [ ! -x "$DISPLAY_DISABLE" ]; then
    eval "$__out_var=''"
    eval "$__status_var=127"
    return
  fi

  set +e
  output="$("$DISPLAY_DISABLE" list 2>&1)"
  cmd_status=$?
  set -e

  eval "$__out_var=\"\$output\""
  eval "$__status_var=$cmd_status"
}

run_system_profiler_displays() {
  local __out_var="$1"
  local __status_var="$2"
  local output
  local cmd_status

  if [ ! -x /usr/sbin/system_profiler ]; then
    eval "$__out_var=''"
    eval "$__status_var=127"
    return
  fi

  set +e
  output="$(/usr/sbin/system_profiler SPDisplaysDataType 2>&1)"
  cmd_status=$?
  set -e

  eval "$__out_var=\"\$output\""
  eval "$__status_var=$cmd_status"
}

status_command() {
  local dd_output=""
  local dd_status=0
  local sp_output=""
  local sp_status=0
  local detected_builtin_id=""
  local active_count=0
  local builtin_active_count=0
  local display_names=""
  local external_names=""
  local external_count=0
  local trusted_count=0
  local suspicious_count=0
  local launchd_state="unknown"

  run_display_disable_list dd_output dd_status
  run_system_profiler_displays sp_output sp_status

  if [ "$dd_status" -eq 0 ]; then
    detected_builtin_id="$(echo "$dd_output" | dd_builtin_display_id_from_display_disable_output)"
    active_count="$(echo "$dd_output" | dd_active_display_count_from_display_disable_output)"
    builtin_active_count="$(echo "$dd_output" | dd_builtin_active_count_from_display_disable_output)"
  fi

  if [ "$sp_status" -eq 0 ]; then
    display_names="$(echo "$sp_output" | dd_display_names_from_system_profiler_output)"
    external_names="$(echo "$display_names" | dd_external_display_names_from_names)"
    external_count="$(echo "$external_names" | dd_nonempty_line_count)"
    trusted_count="$(dd_match_count "$external_names" "$TRUSTED_EXTERNAL_NAMES")"
    suspicious_count="$(dd_match_count "$external_names" "$SUSPICIOUS_DISPLAY_NAMES")"
  fi

  if command -v launchctl >/dev/null 2>&1; then
    if launchctl print "gui/$(id -u)/$DD_WATCHDOG_LABEL" >/dev/null 2>&1; then
      launchd_state="loaded"
    else
      launchd_state="not loaded"
    fi
  fi

  echo "DisplayDisabler smart status"
  echo "----------------------------"
  if [ -x "$DISPLAY_DISABLE" ]; then
    echo "binary: ok ($DISPLAY_DISABLE)"
  else
    echo "binary: missing ($DISPLAY_DISABLE)"
  fi
  echo "display_disable list: status=$dd_status"
  echo "config: $([ -f "$DD_CONFIG_FILE" ] && echo "ok" || echo "missing") ($DD_CONFIG_FILE)"
  echo "built-in id: ${BUILTIN_ID:-unset}"
  if [ -n "$detected_builtin_id" ]; then
    echo "detected built-in id: $detected_builtin_id"
  fi
  echo "active displays: $active_count"
  echo "built-in active count: $builtin_active_count"
  echo "trusted external regex: ${TRUSTED_EXTERNAL_NAMES:-unset}"
  echo "suspicious external regex: ${SUSPICIOUS_DISPLAY_NAMES:-unset}"
  echo "system_profiler: status=$sp_status"
  echo "external display count: $external_count"
  echo "trusted external count: $trusted_count"
  echo "suspicious external count: $suspicious_count"
  echo "watchdog plist: $([ -f "$DD_PLIST_PATH" ] && echo "present" || echo "missing") ($DD_PLIST_PATH)"
  echo "watchdog launchd: $launchd_state"
  echo "logging: ENABLE_LOGGING=$ENABLE_LOGGING DEBUG_LOGGING=$DEBUG_LOGGING MAX_LOG_SIZE_KB=$MAX_LOG_SIZE_KB"

  if [ -n "$external_names" ]; then
    echo
    echo "external displays:"
    echo "$external_names" | sed 's/^/  - /'
  fi
}

doctor_command() {
  local failures=0
  local dd_output=""
  local dd_status=0

  echo "DisplayDisabler smart doctor"
  echo "----------------------------"

  if [ -x "$DISPLAY_DISABLE" ]; then
    echo "ok: display_disable is executable"
  else
    echo "fail: display_disable is missing or not executable at $DISPLAY_DISABLE"
    failures=$((failures + 1))
  fi

  if [ -f "$DD_CONFIG_FILE" ]; then
    echo "ok: config exists"
  else
    echo "warn: config is missing at $DD_CONFIG_FILE"
  fi

  if [ -n "$BUILTIN_ID" ]; then
    echo "ok: built-in id is set to $BUILTIN_ID"
  else
    echo "fail: built-in id is not set"
    failures=$((failures + 1))
  fi

  run_display_disable_list dd_output dd_status
  if [ "$dd_status" -eq 0 ]; then
    echo "ok: display_disable list succeeded"
  else
    echo "fail: display_disable list failed with status $dd_status"
    failures=$((failures + 1))
  fi

  if [ -f "$DD_PLIST_PATH" ]; then
    if command -v plutil >/dev/null 2>&1; then
      if plutil -lint "$DD_PLIST_PATH" >/dev/null 2>&1; then
        echo "ok: watchdog plist is valid"
      else
        echo "fail: watchdog plist is not valid"
        failures=$((failures + 1))
      fi
    else
      echo "warn: plutil is unavailable, plist not checked"
    fi
  else
    echo "warn: watchdog plist is not installed"
  fi

  if command -v launchctl >/dev/null 2>&1 && [ -f "$DD_PLIST_PATH" ]; then
    if launchctl print "gui/$(id -u)/$DD_WATCHDOG_LABEL" >/dev/null 2>&1; then
      echo "ok: watchdog LaunchAgent is loaded"
    else
      echo "warn: watchdog LaunchAgent is not loaded"
    fi
  fi

  if [ "$failures" -eq 0 ]; then
    echo "doctor: ok"
  else
    echo "doctor: $failures failure(s)"
  fi

  return "$failures"
}

safe_disable_command() {
  local target_id="${1:-$BUILTIN_ID}"
  local dd_output=""
  local dd_status=0
  local active_count=0
  local builtin_active_count=0

  if [ -z "$target_id" ]; then
    echo "No built-in display id configured." >&2
    exit 1
  fi

  if [ ! -x "$DISPLAY_DISABLE" ]; then
    echo "display_disable is missing or not executable at $DISPLAY_DISABLE" >&2
    exit 1
  fi

  run_display_disable_list dd_output dd_status
  if [ "$dd_status" -ne 0 ]; then
    echo "display_disable list failed; refusing to disable a display." >&2
    echo "$dd_output" >&2
    exit 1
  fi

  active_count="$(echo "$dd_output" | dd_active_display_count_from_display_disable_output)"
  builtin_active_count="$(echo "$dd_output" | dd_builtin_active_count_from_display_disable_output)"

  if [ "$builtin_active_count" -eq 0 ]; then
    echo "Built-in display already appears inactive; nothing to do."
    exit 0
  fi

  if [ "$active_count" -le 1 ]; then
    echo "Refusing to disable the built-in display because it appears to be the only active display." >&2
    exit 2
  fi

  echo "Disabling built-in display $target_id with safety check passed ($active_count active displays)."
  "$DISPLAY_DISABLE" disable "$target_id"
}

trust_command() {
  local sp_output=""
  local sp_status=0
  local display_names=""
  local current_regex=""
  local existing_regex=""
  local new_regex=""

  if [ ! -f "$DD_CONFIG_FILE" ]; then
    echo "Config file not found: $DD_CONFIG_FILE" >&2
    echo "Run ./scripts/install_smart.sh first." >&2
    exit 1
  fi

  run_system_profiler_displays sp_output sp_status
  if [ "$sp_status" -ne 0 ]; then
    echo "system_profiler failed with status $sp_status" >&2
    echo "$sp_output" >&2
    exit 1
  fi

  display_names="$(echo "$sp_output" | dd_display_names_from_system_profiler_output)"
  current_regex="$(echo "$display_names" | dd_trusted_external_names_regex_from_names)"

  if [ -z "$current_regex" ]; then
    echo "No stable external display names detected."
    echo
    echo "Displays named 'Display' or 'Unknown Display' are not added automatically"
    echo "because they are treated as suspicious fallback names."
    echo
    echo "You can edit the config manually if needed:"
    echo "  $DD_CONFIG_FILE"
    exit 1
  fi

  existing_regex="$(grep '^TRUSTED_EXTERNAL_NAMES=' "$DD_CONFIG_FILE" | sed -E 's/^TRUSTED_EXTERNAL_NAMES="(.*)"$/\1/' || true)"
  if [ -z "$existing_regex" ]; then
    new_regex="$current_regex"
  else
    new_regex="$(printf '%s|%s\n' "$existing_regex" "$current_regex" | dd_join_regex_unique)"
  fi

  cp "$DD_CONFIG_FILE" "$DD_CONFIG_FILE.bak"
  dd_write_trusted_regex_to_config "$DD_CONFIG_FILE" "$new_regex"

  echo "Trusted external display names updated:"
  echo "  $new_regex"
  echo
  echo "Backup created:"
  echo "  $DD_CONFIG_FILE.bak"
}

COMMAND="${1:-status}"
if [ "$#" -gt 0 ]; then
  shift
fi

case "$COMMAND" in
  status)
    status_command "$@"
    ;;
  doctor)
    doctor_command "$@"
    ;;
  safe-disable)
    safe_disable_command "$@"
    ;;
  trust)
    trust_command "$@"
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage >&2
    exit 1
    ;;
esac
