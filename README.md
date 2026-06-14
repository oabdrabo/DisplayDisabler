# DisplayDisabler

A tiny macOS **menu-bar app** for MacBook display control, built on private CoreGraphics / SkyLight APIs — a lightweight alternative to large commercial display utilities.

[![License](https://img.shields.io/github/license/oabdrabo/DisplayDisabler)](LICENSE)

## Features

- **Disable / enable any display** — e.g. turn off the built-in panel in clamshell/headless setups so it stays off when the lid opens. Optionally auto-disable the built-in display whenever an external monitor is connected.
- **Force HiDPI** — add scaled (retina) resolutions to displays that don't natively offer them, via a mirrored private `SLVirtualDisplay`. Also installs persistent "crisp HiDPI" override plists.
- **Brightness** — built-in panel via `DisplayServices`, external monitors via DDC/CI, plus an **Auto-brightness** toggle (ambient-light compensation) on supported displays. On XDR/EDR displays the slider goes **above 100%**: it pins the backlight at 100% and engages the HDR headroom with a multiply-blend EDR overlay (the [xdr-boost](https://github.com/levelsio/xdr-boost)/Vivid technique), scaling the whole screen brighter while preserving colors.
- **Window transparency** — set per-app or all-window opacity for *any* application, using a self-contained scripting addition the app injects into Dock (no external tools). Optional **frosted glass**: transparent windows get a `SLSSetWindowBackgroundBlurRadius` backdrop blur scaled to the opacity. Per-app **Keep on top** pins a window above others via `SLSSetWindowLevel` (reversible).
- **Keep awake** — a built-in caffeine/keep-awake (IOKit power assertion) so the Mac and its display don't sleep, indefinitely or for a set duration — a replacement for KeepingYouAwake.

The menu-bar icon is an interactive **coffee mug**: left-click toggles keep-awake (filled cup = awake), right-click (or control-click) opens the menu — Displays, Transparency, and keep-awake options.

## Requirements

- macOS 14+ (Apple Silicon).
- **Window transparency only:** System Integrity Protection disabled and the `-arm64e_preview_abi` boot-arg set — these are what allow injecting the opacity payload into Dock. (Display/HiDPI/brightness features work without them.) First use prompts once for an admin password to install the scripting addition; afterwards it loads silently.

## Build & install

```sh
git clone https://github.com/oabdrabo/DisplayDisabler.git
cd DisplayDisabler
make install      # builds, signs (ad-hoc), and copies to /Applications
```

Requires Xcode Command Line Tools (`xcode-select --install`). Use the menu-bar icon → **Settings → Launch at Login** to start it automatically.

## Project layout

```
src/
  main.m              app entry point
  app/                AppDelegate — status item, menu, UI
  display/            DisplayManager, HiDPIInjector, Brightness, BrightnessBooster
  transparency/       WindowTransparency — in-app client for the Dock payload
  power/              Caffeine — keep-awake power assertion
  common/             DDUtil — shared error/AppleScript helpers
sa/                   scripting addition injected into Dock (loader.m, payload.m)
tools/                build_icon.m — generates AppIcon.icns
resources/            Info.plist
```

## How it works

- Disabling uses the private `CGSConfigureDisplayEnabled`; Force HiDPI mirrors the panel onto a private `SLVirtualDisplay` pinned to the desired logical size.
- Transparency injects a payload into Dock (`task_for_pid` + an arm64e bootstrap) that calls `SLSSetWindowAlpha` over a private unix socket. The injection technique is adapted from [yabai](https://github.com/koekeishiya/yabai) (MIT); see `sa/loader.m`.

Because these are private APIs, behaviour can change between macOS releases.

## License

MIT. See [LICENSE](LICENSE).
