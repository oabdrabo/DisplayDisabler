# Display Disabler - Installation Guide

## What This Does
Replaces BetterDisplay with a lightweight tool that uses the same private CoreGraphics API to disable your built-in display.

## Installation Steps

### 1. Create ~/bin directory
```bash
mkdir -p ~/bin
```

### 2. Copy the compiled tool
```bash
cp /tmp/display_disable ~/bin/display_disable
chmod +x ~/bin/display_disable
```

### 3. Test it manually
```bash
~/bin/display_disable list
~/bin/display_disable disable-builtin
```

### 4. Install automation script
```bash
cp /tmp/auto_disable_builtin.sh ~/bin/auto_disable_builtin.sh
chmod +x ~/bin/auto_disable_builtin.sh
```

### 5. Install LaunchAgent (auto-run on login)
```bash
cp /tmp/com.user.displaydisabler.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.user.displaydisabler.plist
```

### 6. Remove BetterDisplay (optional)
```bash
# Remove from Login Items first (System Preferences)
osascript -e 'tell application "System Events" to delete login item "BetterDisplay"'

# Quit BetterDisplay
killall BetterDisplay

# Remove app (optional - keep as backup)
# rm -rf /Applications/BetterDisplay.app
```

## Usage

### Manual Commands
```bash
# List all displays
~/bin/display_disable list

# Disable built-in display
~/bin/display_disable disable-builtin

# Disable specific display by ID
~/bin/display_disable disable 0x2

# Re-enable a display
~/bin/display_disable enable 0x2
```

### Automatic (via LaunchAgent)
Once installed, the LaunchAgent will automatically disable the built-in display on every login when an external display is detected.

## Verification
```bash
# Check LaunchAgent status
launchctl list | grep displaydisabler

# Check logs
cat /tmp/displaydisabler.log
cat /tmp/displaydisabler.error.log

# Verify display count
system_profiler SPDisplaysDataType | grep -E "DELL|Color LCD"
```

## Uninstall
```bash
# Remove LaunchAgent
launchctl unload ~/Library/LaunchAgents/com.user.displaydisabler.plist
rm ~/Library/LaunchAgents/com.user.displaydisabler.plist

# Remove tool
rm ~/bin/display_disable
rm ~/bin/auto_disable_builtin.sh
```

## How It Works
Uses the same private CoreGraphics API as BetterDisplay:
```c
CGSConfigureDisplayEnabled(config, displayID, false);
```

This removes the display from CoreGraphics' active display list, making it invisible to macOS and all applications.

## Advantages Over BetterDisplay
- ✅ Lightweight (single binary, ~50KB vs 30MB app)
- ✅ No background process (only runs on login)
- ✅ Open source (you can audit/modify the code)
- ✅ No dependencies
- ✅ Same exact functionality for display disable
- ✅ Complete control over your system

## Technical Details
See the included source code (`display_disable.m`) for full implementation details.
