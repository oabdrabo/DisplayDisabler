#!/bin/zsh

DISPLAY_DISABLE="/usr/local/bin/display_disable"
CONFIG_FILE="$HOME/.displaydisabler-watchdog.conf"
LOG_FILE="$HOME/Library/Logs/displaydisabler-watchdog.log"
STATE_FILE="$HOME/Library/Logs/displaydisabler-watchdog-suspicious-count"

BUILTIN_ID="1"
TRUSTED_EXTERNAL_NAMES=""
SUSPICIOUS_DISPLAY_NAMES="Display|Unknown Display"
CHECK_CONFIRMATIONS="2"
ENABLE_LOGGING="0"
DEBUG_LOGGING="0"
MAX_LOG_SIZE_KB="1024"

if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
fi

rotate_log_if_needed() {
  if [ "$ENABLE_LOGGING" != "1" ]; then
    return
  fi

  if [ ! -f "$LOG_FILE" ]; then
    return
  fi

  LOG_SIZE_KB="$(du -k "$LOG_FILE" 2>/dev/null | awk '{print $1}')"

  if [ -z "$LOG_SIZE_KB" ]; then
    return
  fi

  if [ "$LOG_SIZE_KB" -ge "$MAX_LOG_SIZE_KB" ]; then
    mv "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || true
  fi
}

log() {
  if [ "$ENABLE_LOGGING" = "1" ]; then
    rotate_log_if_needed
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
  fi
}

debug_log() {
  if [ "$ENABLE_LOGGING" = "1" ] && [ "$DEBUG_LOGGING" = "1" ]; then
    rotate_log_if_needed
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
  fi
}

if [ ! -x "$DISPLAY_DISABLE" ]; then
  log "display_disable not found or not executable"
  exit 0
fi

DD_OUTPUT="$($DISPLAY_DISABLE list 2>&1)"
DD_STATUS=$?

log "watchdog tick, display_disable status=$DD_STATUS"
debug_log "$DD_OUTPUT"

if [ "$DD_STATUS" -ne 0 ]; then
  log "display_disable list failed, trying to enable built-in display $BUILTIN_ID"
  "$DISPLAY_DISABLE" enable "$BUILTIN_ID" >> "$LOG_FILE" 2>&1
  exit 0
fi

ACTIVE_SECTION="$(echo "$DD_OUTPUT" | awk '
  /=== Active Displays ===/ { flag=1; next }
  /=== Online Displays ===/ { flag=0 }
  flag
')"

DD_BUILTIN_ACTIVE_COUNT="$(echo "$ACTIVE_SECTION" | grep -c "Built-in: YES")"

SP_OUTPUT="$(/usr/sbin/system_profiler SPDisplaysDataType 2>&1)"
SP_STATUS=$?

log "system_profiler status=$SP_STATUS"
debug_log "$SP_OUTPUT"

SP_DISPLAY_NAMES="$(echo "$SP_OUTPUT" | awk '
  /Displays:/ { in_displays=1; next }

  in_displays && /^[[:space:]]{8}[^[:space:]].*:$/ {
    name=$0
    sub(/^[[:space:]]+/, "", name)
    sub(/:$/, "", name)
    print name
  }
')"

SP_EXTERNAL_NAMES="$(echo "$SP_DISPLAY_NAMES" | grep -v "^Color LCD$" || true)"
SP_EXTERNAL_COUNT="$(echo "$SP_EXTERNAL_NAMES" | sed '/^$/d' | wc -l | tr -d ' ')"

TRUSTED_COUNT=0
SUSPICIOUS_NAME_COUNT=0

if [ -n "$TRUSTED_EXTERNAL_NAMES" ]; then
  TRUSTED_COUNT="$(echo "$SP_EXTERNAL_NAMES" | grep -E -c "^(${TRUSTED_EXTERNAL_NAMES})$" || true)"
fi

if [ -n "$SUSPICIOUS_DISPLAY_NAMES" ]; then
  SUSPICIOUS_NAME_COUNT="$(echo "$SP_EXTERNAL_NAMES" | grep -E -c "^(${SUSPICIOUS_DISPLAY_NAMES})$" || true)"
fi

log "display_names=$(echo "$SP_DISPLAY_NAMES" | tr '\n' ',' )"
log "external_count=$SP_EXTERNAL_COUNT trusted_count=$TRUSTED_COUNT suspicious_name_count=$SUSPICIOUS_NAME_COUNT builtin_active=$DD_BUILTIN_ACTIVE_COUNT"

# If the built-in display is already active, reset state and do nothing.
if [ "$DD_BUILTIN_ACTIVE_COUNT" -gt 0 ]; then
  echo 0 > "$STATE_FILE"
  log "built-in already active, nothing to do"
  exit 0
fi

# If the built-in display is inactive but a trusted external display is present,
# keep the built-in display disabled.
if [ "$TRUSTED_COUNT" -gt 0 ]; then
  echo 0 > "$STATE_FILE"
  log "built-in inactive, trusted external display detected, nothing to do"
  exit 0
fi

SHOULD_ENABLE="0"

# If no external displays are reported, it is unsafe to keep the built-in display disabled.
if [ "$SP_EXTERNAL_COUNT" -eq 0 ]; then
  SHOULD_ENABLE="1"
  log "built-in inactive and no external display names detected"
fi

# If only suspicious/untrusted external display names are reported, it may be a
# stale/fallback display entry after a disconnect event.
if [ "$SUSPICIOUS_NAME_COUNT" -gt 0 ] && [ "$TRUSTED_COUNT" -eq 0 ]; then
  SHOULD_ENABLE="1"
  log "built-in inactive and suspicious/untrusted external display detected"
fi

if [ "$SHOULD_ENABLE" = "1" ]; then
  CONFIRMATION_COUNT=0

  if [ -f "$STATE_FILE" ]; then
    CONFIRMATION_COUNT="$(cat "$STATE_FILE" 2>/dev/null)"
  fi

  CONFIRMATION_COUNT=$((CONFIRMATION_COUNT + 1))
  echo "$CONFIRMATION_COUNT" > "$STATE_FILE"

  log "unsafe display state confirmation count=$CONFIRMATION_COUNT"

  if [ "$CONFIRMATION_COUNT" -ge "$CHECK_CONFIRMATIONS" ]; then
    log "enabling built-in display $BUILTIN_ID"
    "$DISPLAY_DISABLE" enable "$BUILTIN_ID" >> "$LOG_FILE" 2>&1
    echo 0 > "$STATE_FILE"
    exit 0
  fi

  log "waiting for more confirmations before enabling built-in"
  exit 0
fi

log "built-in inactive but external display state is not recognized as unsafe, nothing to do"
