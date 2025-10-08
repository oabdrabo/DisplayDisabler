#!/bin/bash

# Auto-Disable Built-in Display on Login
# Install: Copy to ~/bin/auto_disable_builtin.sh
# Add to Login Items or create LaunchAgent

TOOL_PATH="$HOME/bin/display_disable"

# Check if external display is connected
EXTERNAL_COUNT=$(system_profiler SPDisplaysDataType -json | python3 -c "import sys, json; data=json.load(sys.stdin); displays = data['SPDisplaysDataType'][0]['spdisplays_ndrvs']; print(sum(1 for d in displays if not d.get('_name', '').startswith('Color')))")

if [ "$EXTERNAL_COUNT" -gt 0 ]; then
    echo "External display detected, disabling built-in..."
    "$TOOL_PATH" disable-builtin
else
    echo "No external display, keeping built-in active"
fi
