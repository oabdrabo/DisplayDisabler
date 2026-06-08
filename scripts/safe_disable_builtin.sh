#!/bin/zsh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -x "$SCRIPT_DIR/displaydisabler-smart" ]; then
  exec "$SCRIPT_DIR/displaydisabler-smart" safe-disable "$@"
fi

exec "$SCRIPT_DIR/displaydisabler_smart.sh" safe-disable "$@"
