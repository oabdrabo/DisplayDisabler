# DisplayDisabler

Disable a MacBook's built-in display using private Apple CoreGraphics APIs. A 51 KB open-source alternative to BetterDisplay (30+ MB commercial app) for users who only need the disable-internal-display feature on headless / clamshell-mode MacBook setups.

[![Latest release](https://img.shields.io/github/v/release/oabdrabo/DisplayDisabler?label=release)](https://github.com/oabdrabo/DisplayDisabler/releases)
[![License](https://img.shields.io/github/license/oabdrabo/DisplayDisabler)](LICENSE)

## Why

Closing a MacBook in clamshell mode and connecting an external display works, but the *moment the lid opens* the internal display reactivates. For headless / docked / external-monitor-only setups, you want the internal display permanently disabled until you explicitly re-enable it.

Existing tools:

| Tool | Size | Notes |
|---|---|---|
| **BetterDisplay** | 30+ MB | Full-featured display management; overkill if you only need one feature |
| **DisplayDisabler** | 51 KB | Single-purpose, single-binary, no UI background process |

## Install

```sh
# Download the latest binary
curl -L -o DisplayDisabler https://github.com/oabdrabo/DisplayDisabler/releases/latest/download/DisplayDisabler
chmod +x DisplayDisabler
sudo mv DisplayDisabler /usr/local/bin/
```

Or build from source — see below.

## Usage

```sh
# Disable the internal display
DisplayDisabler disable

# Re-enable
DisplayDisabler enable

# Toggle
DisplayDisabler toggle
```

## How it works

Uses the private `CGSConfigureDisplayEnabled` Core Graphics function (part of `SkyLight.framework`) to flip the enabled state of the built-in display ID. The internal display retains its hardware identification but stops being part of the active display set.

Because this is a private API, the behaviour can change between macOS releases. Tested on macOS 13–14.

## Build from source

```sh
git clone https://github.com/oabdrabo/DisplayDisabler.git
cd DisplayDisabler
make
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## License

MIT. See [LICENSE](LICENSE).

## Author

[Omar Abdrabo](https://github.com/oabdrabo) · [LinkedIn](https://linkedin.com/in/oabdrabo)
