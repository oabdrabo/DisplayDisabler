#!/bin/bash

# DisplayDisabler Installation Script

set -e

echo "=== DisplayDisabler Installation ==="
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: This tool is for macOS only"
    exit 1
fi

# Create bin directory
echo "1. Creating ~/bin directory..."
mkdir -p ~/bin

# Copy tool
echo "2. Installing display_disable tool..."
cp display_disable ~/bin/display_disable
chmod +x ~/bin/display_disable

# Test the tool
echo "3. Testing tool..."
~/bin/display_disable list

# Install automation script
echo "4. Installing automation script..."
cp auto_disable_builtin.sh ~/bin/auto_disable_builtin.sh
chmod +x ~/bin/auto_disable_builtin.sh

# Ask about LaunchAgent
echo ""
read -p "Install LaunchAgent (auto-run on login)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "5. Installing LaunchAgent..."
    cp com.user.displaydisabler.plist ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/com.user.displaydisabler.plist
    echo "✅ LaunchAgent installed and loaded"
else
    echo "5. Skipped LaunchAgent installation"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Usage:"
echo "  ~/bin/display_disable list              # List displays"
echo "  ~/bin/display_disable disable-builtin   # Disable built-in display"
echo ""
echo "To manually test:"
echo "  ~/bin/display_disable disable-builtin"
echo ""
