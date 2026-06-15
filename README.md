# DisplayDisabler

A tiny macOS **menu-bar app** for MacBook display control, built on private CoreGraphics / SkyLight APIs — a lightweight alternative to large commercial display utilities.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Features

- **Disable / enable any display** — e.g. turn off the built-in panel in clamshell/headless setups so it stays off when the lid opens. Optionally auto-disable the built-in display whenever an external monitor is connected.
- **Force HiDPI** — add scaled (retina) resolutions to displays that don't natively offer them, via a mirrored private `SLVirtualDisplay`. Also installs persistent "crisp HiDPI" override plists.
- **Brightness** — built-in panel via `DisplayServices`, external monitors via DDC/CI, plus an inline **Auto-brightness** toggle (ambient-light compensation) on supported displays. Above 100% it engages an EDR overlay boost (the [xdr-boost](https://github.com/levelsio/xdr-boost)/Vivid multiply-blend technique) **clamped to the display's real EDR headroom**, which it measures and remembers at runtime — so the slider settles at what the panel can actually deliver (a mild ~1.25× on a typical built-in panel, much more on a true XDR/HDR display) with colors preserved and no clipping. The overlay brightens window/desktop content and auto-suspends during Mission Control / Launchpad so they don't wash out.
- **Warmth** — a per-display color-temperature slider (f.lux/Night-Shift style) that warms the screen by loading gamma ramps via `CGSetDisplayTransferByTable` (6500K neutral → ~3400K warm). Works on the built-in panel, persists across launches, restores native ColorSync at 0%.
- **Window transparency** — set per-app or all-window opacity for *any* application, using a self-contained scripting addition the app injects into Dock (no external tools). Optional **frosted glass**: transparent windows get a `SLSSetWindowBackgroundBlurRadius` backdrop blur scaled to the opacity. Per-app **Keep on top** pins a window above others via `SLSSetWindowLevel` (reversible). Per-app **Picture in Picture** shrinks a window into a floating, always-on-top corner thumbnail you can still use (resizes the real window via the Accessibility API; toggle off to restore its size and position). PiP needs Accessibility permission (prompted once).
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

Requires Xcode Command Line Tools (`xcode-select --install`). It launches at login by default; toggle that off under the menu-bar icon → **Settings → Launch at Login**.

## Project layout

```
src/
  main.m              app entry point
  app/                AppDelegate — status item, menu, UI
  display/            DisplayManager, HiDPIInjector, Brightness,
                      BrightnessBooster (EDR boost), ColorTemperature (warmth)
  transparency/       WindowTransparency — in-app client for the Dock payload
  window/             WindowPiP — Accessibility-based picture-in-picture
  power/              Caffeine — keep-awake power assertion
  common/             DDUtil — shared error/AppleScript helpers
sa/                   scripting addition injected into Dock (loader.m, payload.m)
tools/                build_icon.m — generates AppIcon.icns
resources/            Info.plist
```

## How it works

- Disabling uses the private `CGSConfigureDisplayEnabled`; Force HiDPI mirrors the panel onto a private `SLVirtualDisplay` pinned to the desired logical size, and "crisp HiDPI" writes display-override plists under `/Library/Displays/.../Overrides`.
- Transparency injects a payload into Dock (`task_for_pid` + an arm64e bootstrap) that calls `SLSSetWindowAlpha` / `SLSSetWindowBackgroundBlurRadius` / `SLSSetWindowLevel` over a private unix socket. The injection technique is adapted from [yabai](https://github.com/koekeishiya/yabai) (MIT); see `sa/loader.m`.
- Warmth loads per-channel gamma ramps with the public `CGSetDisplayTransferByTable`; the brightness boost is a borderless EDR overlay (`CAMetalLayer`, multiply blend) clamped each frame to the live `maximumExtendedDynamicRangeColorComponentValue`.
- Picture-in-Picture resizes/moves the real window through the Accessibility API (`AXUIElement`) and reuses Keep-on-top for the float.

Because these are private APIs, behaviour can change between macOS releases.

## License

MIT. See [LICENSE](LICENSE).
