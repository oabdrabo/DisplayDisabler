#!/bin/zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/lib/displaydisabler_smart_lib.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"

  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $label" >&2
    echo "expected: [$expected]" >&2
    echo "actual:   [$actual]" >&2
    exit 1
  fi
}

DD_FIXTURE="$(cat "$SCRIPT_DIR/fixtures/display_disable_list.txt")"
SP_FIXTURE="$(cat "$SCRIPT_DIR/fixtures/system_profiler_displays.txt")"

assert_eq "built-in id" \
  "$(echo "$DD_FIXTURE" | dd_builtin_display_id_from_display_disable_output)" \
  "1"

assert_eq "active display count" \
  "$(echo "$DD_FIXTURE" | dd_active_display_count_from_display_disable_output)" \
  "2"

assert_eq "built-in active count" \
  "$(echo "$DD_FIXTURE" | dd_builtin_active_count_from_display_disable_output)" \
  "1"

DISPLAY_NAMES="$(echo "$SP_FIXTURE" | dd_display_names_from_system_profiler_output)"
assert_eq "display names" "$DISPLAY_NAMES" $'Color LCD\nDELL U2720Q\nDisplay'

EXTERNAL_NAMES="$(echo "$DISPLAY_NAMES" | dd_external_display_names_from_names)"
assert_eq "external names" "$EXTERNAL_NAMES" $'DELL U2720Q\nDisplay'

TRUSTED_REGEX="$(echo "$DISPLAY_NAMES" | dd_trusted_external_names_regex_from_names)"
assert_eq "trusted regex" "$TRUSTED_REGEX" "DELL U2720Q"

assert_eq "trusted count" "$(dd_match_count "$EXTERNAL_NAMES" "$TRUSTED_REGEX")" "1"
assert_eq "suspicious count" "$(dd_match_count "$EXTERNAL_NAMES" "Display|Unknown Display")" "1"

echo "smart parser smoke tests passed"
