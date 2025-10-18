# DisplayDisabler — Lightweight Display Manager for macOS

A minimal, open-source menu bar app that disables your MacBook's built-in display when using external monitors. Uses the same private CoreGraphics API as BetterDisplay, in a ~100KB app with zero background overhead.

## Install

```bash
make
```

Then drag `DisplayDisabler.app` to `/Applications`. That's it.

Or use the shortcut:

```bash
make install
```

## What It Does

Click the display icon in your menu bar to:

- **See all displays** — names, status, resolution, refresh rate, HiDPI info
- **Disable / Enable** any display with one click
- **Browse all resolutions** — including every HiDPI (Retina) mode
- **Force HiDPI** on non-Retina displays via virtual display mirroring (macOS 14+)
- **Auto-disable built-in** when an external monitor is connected
- **Launch at Login** — starts silently in the menu bar

No dock icon. No terminal. No scripts. Just a clean menu bar utility.

## Menu Bar

```
DisplayDisabler v3.0
1 online, 1 active
─────────────────────────────────────────────
● Built-in Display — 0x1
  active  │  built-in  │  main
  3024 × 1964 @2x  120Hz
  ▶ All Resolutions              → submenu
  Force HiDPI                      (if no native HiDPI, macOS 14+)
  Disable This Display
─────────────────────────────────────────────
▶ Settings
  ├── ☐ Turn off laptop screen when external monitor is connected
  ├── ☑ Show notifications
  ├── ☐ Ask before disabling a display
  ├── ☑ Show all resolutions
  └── ☐ Launch at Login
─────────────────────────────────────────────
Quit DisplayDisabler                      ⌘Q
```

The **All Resolutions** submenu shows every available display mode — HiDPI and standard — with pixel dimensions, logical dimensions, scale factor, and refresh rate. All settings are toggleable and persist across app restarts.

## Build from Source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
make            # build DisplayDisabler.app
make install    # copy to /Applications
make clean      # remove build artifacts
make uninstall  # remove from /Applications
```

### Compilation details

```bash
clang -fobjc-arc -Wall -O2 -mmacosx-version-min=13.0 \
      -framework Cocoa -framework CoreGraphics -framework IOKit \
      -framework ServiceManagement -framework UserNotifications \
      main.m AppDelegate.m DisplayManager.m -o DisplayDisabler
```

## How It Works

The core functionality uses Apple's private CoreGraphics API:

```objc
CGBeginDisplayConfiguration(&config);
CGSConfigureDisplayEnabled(config, displayID, false);  // private API
CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
```

This is exactly what BetterDisplay does internally.

Force HiDPI works by creating a `CGVirtualDisplay` (private API, macOS 14+) with HiDPI enabled, then mirroring the physical display through it via `CGConfigureDisplayMirrorOfDisplay`.

The app monitors display changes via `CGDisplayRegisterReconfigurationCallback` and `NSApplicationDidChangeScreenParametersNotification`, and auto-refreshes the menu when you plug/unplug monitors.

## vs BetterDisplay

| | DisplayDisabler | BetterDisplay |
|---|---|---|
| **App size** | ~100KB | ~30MB |
| **Memory** | ~5MB | ~120MB |
| **Background CPU** | 0% | ~0.5% |
| **Open source** | Yes | No |
| **HiDPI mode listing** | Yes | Yes |
| **Force HiDPI** | Yes (macOS 14+) | Yes |
| **Auto-disable built-in** | Yes | Yes |
| **Launch at Login** | Yes | Yes |
| **HDR / DDC control** | No | Yes |
| **GUI settings** | Menu bar | Full GUI |

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon or Intel Mac

## Files

| File | Purpose |
|---|---|
| `main.m` | App entry point |
| `AppDelegate.h/m` | Menu bar UI, settings, auto-disable logic |
| `DisplayManager.h/m` | Display query, enable/disable, mode listing, HiDPI forcing, monitoring |
| `Info.plist` | App bundle metadata |
| `Makefile` | Build system |

## Security

- Uses official (though private) Apple APIs
- No network access, no data collection
- Source code fully auditable
- Does NOT require SIP disabled or root access
- Ad-hoc code signed (works locally, not notarized for distribution)

## License

MIT License — see [LICENSE](LICENSE)

---

**Version**: 3.0.0
**Compatible with**: macOS 13+ (Ventura and later), Apple Silicon & Intel
