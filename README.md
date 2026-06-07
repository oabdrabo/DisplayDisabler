# DisplayDisabler

A small macOS command-line utility to disable and re-enable displays by display ID.

This fork adds a smart installer, configurable shell aliases, an optional safety watchdog, and a helper to trust additional external displays.

The safety watchdog is useful when using a MacBook with an external monitor: if the built-in display is disabled and the external display is disconnected, the watchdog can automatically re-enable the built-in display.

> Note: this project uses private macOS display APIs. Future macOS updates may change or break this behavior.

---

## Features

- Disable a display by ID
- Enable a display by ID
- List active and online displays
- Automatically detect the built-in display ID during setup
- Create convenient shell aliases such as `s-off` and `s-on`
- Optionally install a LaunchAgent watchdog
- Re-enable the built-in display when the external display disappears or becomes a generic fallback entry
- Trust additional external displays later with `trust-displays`
- Fully uninstall the smart setup and `/usr/local/bin/display_disable`

---

## Install

Run:

```bash
./scripts/install_smart.sh
```

The installer can:

- install `display_disable` if it is missing
- detect the built-in display ID automatically
- create convenient shell aliases
- detect currently connected external display names
- save trusted external display names in a config file
- install the optional LaunchAgent safety watchdog

Default aliases:

```bash
s-off
s-on
trust-displays
```

Where:

- `s-off` disables the built-in display
- `s-on` re-enables the built-in display
- `trust-displays` adds the currently connected external displays to the trusted display list

After installation, reload your shell:

```bash
source ~/.zshrc
```

---

## Manual usage

List displays:

```bash
display_disable list
```

Example output:

```text
=== Active Displays ===

Display 0:
  ID: 0x3 (3)
  Built-in: NO
  Main: YES
  Resolution: 2560 x 1440
  Active: YES

Display 1:
  ID: 0x1 (1)
  Built-in: YES
  Main: NO
  Resolution: 1512 x 982
  Active: YES

=== Online Displays ===
Online display count: 2
```

Disable the built-in display:

```bash
display_disable disable 1
```

Re-enable the built-in display:

```bash
display_disable enable 1
```

If you run `disable` while the display is already disabled, macOS may return:

```text
Error: Failed to commit display configuration (error 1001)
```

This usually means there was no display configuration change to commit.

---

## Safety watchdog

The optional watchdog is installed as:

```text
~/Scripts/DisplayDisabler-Watchdog
```

and runs through this LaunchAgent:

```text
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
```

The LaunchAgent label is:

```text
com.displaydisabler.watchdog
```

The watchdog is designed to prevent this situation:

1. the built-in display is disabled
2. the external monitor is disconnected
3. macOS still reports a stale or generic external display entry
4. the user is left without the built-in display enabled

If the built-in display is disabled and no trusted external display is detected, it waits for a configurable number of unsafe confirmations and then runs:

```bash
display_disable enable <built-in-display-id>
```

By default, the smart installer uses:

- check interval: `10` seconds
- unsafe confirmations: `2`

With the default configuration, the built-in display may be re-enabled after about 10-20 seconds.

---

## Watchdog configuration

The smart installer creates this file:

```bash
~/.displaydisabler-watchdog.conf
```

Example:

```bash
BUILTIN_ID="1"
TRUSTED_EXTERNAL_NAMES="DELL U2720Q|LG HDR 4K|Q27G4"
SUSPICIOUS_DISPLAY_NAMES="Display|Unknown Display"
CHECK_CONFIRMATIONS="2"
ENABLE_LOGGING="0"
DEBUG_LOGGING="0"
MAX_LOG_SIZE_KB="1024"
```

`TRUSTED_EXTERNAL_NAMES` is an extended regular expression of external display names that are considered safe while the built-in display is disabled.

`SUSPICIOUS_DISPLAY_NAMES` contains generic or fallback names that may appear after a disconnect event.

`MAX_LOG_SIZE_KB` rotates the log when it reaches the configured size. One backup is kept as `.1`.

`DEBUG_LOGGING` controls whether full command output from `display_disable` and `system_profiler` is written to the log.

---

## Using multiple external monitors

If you use different monitors at home, at work, or through different docks, connect the new monitor and run:

```bash
trust-displays
```

This adds the currently connected stable external display names to `TRUSTED_EXTERNAL_NAMES`.

Example:

```bash
TRUSTED_EXTERNAL_NAMES="Q27G4|DELL U2720Q|Studio Display"
```

Displays named `Display` or `Unknown Display` are not added automatically because those names are treated as suspicious fallback names.

If your monitor appears only as `Display` or `Unknown Display`, edit the config manually:

```bash
nano ~/.displaydisabler-watchdog.conf
```

---

## Logs and retention

Logging is disabled by default.

If lightweight logging is enabled, logs are written to:

```bash
~/Library/Logs/displaydisabler-watchdog.log
```

The watchdog rotates the log when it reaches `MAX_LOG_SIZE_KB`. By default:

```bash
MAX_LOG_SIZE_KB="1024"
```

One rotated backup is kept:

```bash
~/Library/Logs/displaydisabler-watchdog.log.1
```

`DEBUG_LOGGING="0"` keeps the log lightweight and avoids writing full `system_profiler` output on every check.

Set:

```bash
DEBUG_LOGGING="1"
```

only when troubleshooting, because it writes much more data.

Inspect the log:

```bash
tail -f ~/Library/Logs/displaydisabler-watchdog.log
```

---

## Uninstall

Run:

```bash
./scripts/uninstall_smart.sh
```

The uninstaller removes:

- the LaunchAgent
- the old LaunchAgent name, if present
- the watchdog script
- the old watchdog script name, if present
- the trust-displays helper
- the watchdog configuration file
- the watchdog state file
- aliases from `~/.zshrc`
- optionally the watchdog log file
- `/usr/local/bin/display_disable`

---

## LaunchAgent management

Check whether the watchdog is loaded:

```bash
launchctl list | grep displaydisabler
```

Inspect the watchdog:

```bash
launchctl print gui/$(id -u)/com.displaydisabler.watchdog
```

Restart the watchdog manually:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.displaydisabler.watchdog.plist 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
launchctl enable gui/$(id -u)/com.displaydisabler.watchdog
launchctl kickstart -k gui/$(id -u)/com.displaydisabler.watchdog
```

---

## Recommended workflow

1. Connect your external monitor.
2. Run `s-off`.
3. Use the external monitor normally.
4. If the external monitor is disconnected, the watchdog should re-enable the built-in display automatically.
5. Manually re-enable the built-in display anytime with `s-on`.
6. When using a new monitor, run `trust-displays`.

---

## Files added by this fork

```text
scripts/
├── install_smart.sh
├── uninstall_smart.sh
├── auto_enable_builtin_on_external_disconnect.sh
└── trust_current_external_displays.sh
```

User-level files created by the smart installer:

```text
~/.displaydisabler-watchdog.conf
~/Scripts/DisplayDisabler-Watchdog
~/Scripts/trust_current_external_displays.sh
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
~/Library/Logs/displaydisabler-watchdog.log
```

---

## Limitations

The safety watchdog relies on display information reported by macOS, especially:

```bash
display_disable list
```

and:

```bash
system_profiler SPDisplaysDataType
```

This means:

- external display names may vary depending on dock, cable, adapter, or macOS version
- some docks may expose generic names such as `Display`
- some displays may briefly appear as stale or fallback entries after disconnecting
- users may need to edit `~/.displaydisabler-watchdog.conf` manually
- the watchdog is a safety mechanism, not a guaranteed universal display-detection system

The watchdog is intentionally conservative and waits for multiple unsafe checks before re-enabling the built-in display.

---

## Disclaimer

This project uses private macOS display APIs. Use it at your own risk.

Behavior may vary depending on:

- macOS version
- Apple Silicon vs Intel Mac
- external monitor model
- dock or adapter
- cable type
- display firmware
