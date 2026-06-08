---

## Menu-bar app smart safety

`DisplayDisabler.app` is the primary lightweight experience. It runs as a
macOS menu-bar app, not as a Dock app, and manages displays from the status
item menu.

The app now includes:

- safe built-in display disable: the built-in display is kept off only when a
  trusted active external display is available
- trusted external displays managed from the Settings menu, without exposing
  regex configuration to normal users
- event-driven smart recovery: display change callbacks trigger a short
  debounce check, then the app re-enables the built-in display if no trusted
  external monitor remains active
- an internal safety watchdog that runs only while the built-in display is
  inactive, so disconnect recovery can still happen when CoreGraphics stops
  reporting the disabled built-in panel as an online display
- a fallback disabled built-in row in the menu when the app knows the last
  built-in display ID but macOS is no longer listing that panel
- manual brightness presets for displays supported by macOS DisplayServices or
  DDC/CI; the app sets brightness on demand and does not keep enforcing it
- System Status and Doctor menu actions for a lightweight, copyable runtime
  report
- Launch at Login and trusted-display auto-manage from the app UI

The app recovery path starts from display-change events. If the built-in display
is inactive, the app also arms a lightweight in-process watchdog that checks
roughly every two seconds and stops again once the built-in display is active.

If you manually choose `Enable` on the built-in display, the app turns
Auto-manage off and briefly suppresses auto-disable. This prevents the built-in
panel from being re-disabled immediately while a trusted external monitor is
still connected.

The Settings switches use app-rendered blue/gray controls so their color stays
consistent after reopening the submenu.

## Unified installer

Use the installer as the single entry point:

```bash
./scripts/install_smart.sh
```

It asks which profile to install:

- `app`: menu-bar app only, recommended
- `cli`: shell aliases/helpers only
- `full`: menu-bar app plus CLI fallback

Non-interactive profile flags are also available:

```bash
./scripts/install_smart.sh --app
./scripts/install_smart.sh --cli
./scripts/install_smart.sh --full
```

After an app or full install, open:

```bash
open /Applications/DisplayDisabler.app
```

Then use `Settings -> Trusted Displays` from the menu-bar app to trust your
current external monitor.

## CLI aliases and safety watchdog

This fork also keeps an optional smart installer on top of the original
`display_disable` binary for CLI users.

The smart installer can:

- install `display_disable` if it is missing
- detect the built-in display ID automatically
- create shell aliases such as `s-off`, `s-on` and `dd-status`
- route `s-off` through a safety wrapper before disabling the built-in display
- install an optional safety watchdog
- register trusted external displays
- run lightweight status and doctor checks
- fully uninstall the smart setup and the `display_disable` binary

### CLI install

Run the installer in CLI mode:

```bash
./scripts/install_smart.sh --cli
```

Useful installer options:

```bash
./scripts/install_smart.sh --full
./scripts/install_smart.sh --dry-run
./scripts/install_smart.sh --repair
./scripts/install_smart.sh --no-watchdog
./scripts/install_smart.sh --no-download
./scripts/install_smart.sh --yes
```

The installer detects the built-in display ID using:

```bash
display_disable list
```

Default aliases:

```bash
s-off
s-on
trust-displays
dd-status
```

Where:

- `s-off` safely disables the built-in display only when another active display is present
- `s-on` re-enables the built-in display
- `trust-displays` adds the currently connected external displays to the trusted display list
- `dd-status` prints the smart setup and current display state

After installation, reload your shell:

```bash
source ~/.zshrc
```

The aliases are written inside a marked block in `~/.zshrc`, so rerunning the
installer updates that block instead of appending duplicate aliases.

### Smart status and doctor

The installer adds:

```bash
~/Scripts/displaydisabler-smart
```

Available commands:

```bash
~/Scripts/displaydisabler-smart status
~/Scripts/displaydisabler-smart doctor
~/Scripts/displaydisabler-smart safe-disable
~/Scripts/displaydisabler-smart trust
```

`status` reports the detected install profile, menu-bar app path, binary path,
config, detected built-in display, app safety defaults, active display count,
trusted external display count and watchdog LaunchAgent state.

`doctor` runs lightweight setup checks and is profile-aware. In app-only
installs, missing CLI pieces are reported as `info`; in CLI/full installs,
missing `display_disable`, config or failing `display_disable list` checks are
reported as failures and return a non-zero exit code.

The menu-bar app also has its own `System Status...` and `Run Doctor...`
actions. Those report the app runtime state from CoreGraphics and app defaults,
including Auto-manage, Smart Recovery, Launch at Login, trusted displays and
CLI fallback availability. The shell `displaydisabler-smart` command is the
diagnostic surface for installer profile, CLI fallback and LaunchAgent watchdog
state.

### CLI safety watchdog

The optional watchdog is designed to avoid being left without an active built-in display when the external display is disconnected.

The LaunchAgent watchdog remains a lightweight CLI fallback. The menu-bar app
keeps its own launch-at-login, trusted-display auto-manage and event-driven
recovery flow, while the smart shell path shares the same parser/helper library
across `safe-disable`, `status`, `doctor`, `trust` and the LaunchAgent
watchdog.

It is installed as:

```text
~/Scripts/DisplayDisabler-Watchdog
```

and runs through this LaunchAgent:

```text
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
```

LaunchAgent label:

```text
com.displaydisabler.watchdog
```

If the built-in display is disabled and no trusted external display is detected, the watchdog waits for a configurable number of unsafe confirmations and then runs:

```bash
display_disable enable <built-in-display-id>
```

Default behavior:

- check interval: `10` seconds
- unsafe confirmations: `2`
- logging disabled by default

### Configuration

The installer creates:

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

`TRUSTED_EXTERNAL_NAMES` contains external display names that are considered safe while the built-in display is disabled.

`SUSPICIOUS_DISPLAY_NAMES` contains generic or fallback display names that may appear after a disconnect event.

### Using multiple external monitors

If you use different monitors at home, at work, or through different docks, connect the new monitor and run:

```bash
trust-displays
```

This adds the currently connected stable external display names to:

```bash
~/.displaydisabler-watchdog.conf
```

Example:

```bash
TRUSTED_EXTERNAL_NAMES="Q27G4|DELL U2720Q|Studio Display"
```

Displays named `Display` or `Unknown Display` are not added automatically because those names are treated as suspicious fallback names.

### Logs and retention

Logging is disabled by default.

If lightweight logging is enabled, logs are written to:

```bash
~/Library/Logs/displaydisabler-watchdog.log
```

The watchdog rotates the log when it reaches `MAX_LOG_SIZE_KB`.

Default:

```bash
MAX_LOG_SIZE_KB="1024"
```

One rotated backup is kept:

```bash
~/Library/Logs/displaydisabler-watchdog.log.1
```

`DEBUG_LOGGING="0"` keeps the log lightweight.

Set:

```bash
DEBUG_LOGGING="1"
```

only when troubleshooting, because it writes full command output from `display_disable` and `system_profiler`.

### Uninstall

Run:

```bash
./scripts/uninstall_smart.sh
```

Useful uninstaller options:

```bash
./scripts/uninstall_smart.sh --app
./scripts/uninstall_smart.sh --cli
./scripts/uninstall_smart.sh --full
./scripts/uninstall_smart.sh --dry-run
./scripts/uninstall_smart.sh --yes
./scripts/uninstall_smart.sh --keep-app
./scripts/uninstall_smart.sh --keep-binary
./scripts/uninstall_smart.sh --keep-config
./scripts/uninstall_smart.sh --keep-logs
```

The uninstaller removes:

- the menu-bar app, when using `--app` or `--full`
- the LaunchAgent
- the old LaunchAgent name, if present
- the watchdog script
- the old watchdog script name, if present
- the smart status/doctor command
- the safe-disable wrapper
- the trust-displays helper
- the shared smart helper library
- the watchdog configuration file
- the watchdog state file
- aliases from the marked block in `~/.zshrc`
- optionally the watchdog log file
- `/usr/local/bin/display_disable`

### Files added by this fork

```text
scripts/
├── install_smart.sh
├── uninstall_smart.sh
├── auto_enable_builtin_on_external_disconnect.sh
├── displaydisabler_smart.sh
├── safe_disable_builtin.sh
├── trust_current_external_displays.sh
└── lib/displaydisabler_smart_lib.sh
```

User-level files created by `--app`:

```text
/Applications/DisplayDisabler.app
```

Additional user-level files created by `--cli` or `--full`:

```text
~/.displaydisabler-watchdog.conf
~/Scripts/displaydisabler-smart
~/Scripts/displaydisabler_smart_lib.sh
~/Scripts/safe_disable_builtin.sh
~/Scripts/DisplayDisabler-Watchdog
~/Scripts/trust_current_external_displays.sh
~/Library/LaunchAgents/com.displaydisabler.watchdog.plist
~/Library/Logs/displaydisabler-watchdog.log
```

### Lightweight validation

Run the shell/parser smoke checks with:

```bash
make test-smart
```
