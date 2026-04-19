# DisplayDisabler — Minimal macOS Display Utility

A menu bar app that replaces much of what BetterDisplay does — disable/enable displays, HiDPI at any resolution (including the ones Apple doesn't advertise), brightness over DDC or DisplayServices, auto-manage the built-in when an external is connected — in ~1,700 lines of Objective-C with zero background CPU.

## Install

```bash
make install
```

Builds and copies `DisplayDisabler.app` to `/Applications`. Launches as a menu bar item (no dock icon, no window). Ad-hoc signed.

## What it does

### Disable / Enable displays
One-click toggle per display via the private `CGSConfigureDisplayEnabled` API — same mechanism BetterDisplay uses. Refuses to disable the last active display. Confirmation dialog by default.

### Auto-manage the built-in
Toggle in Settings: turn off the MacBook's internal panel whenever an external monitor is connected, turn it back on when the external goes away. Debounced so hot-plug bursts don't flicker the menu.

### Browse every display mode
Each active display has an **All Resolutions** submenu listing every mode the panel reports — pixels, logical size, Standard vs. HiDPI, refresh rate. Click to switch. Dedup key includes `IOFlags` so modes that differ by pixel encoding don't collide.

### Force HiDPI (at any resolution)

Every display gets a **Force HiDPI ▶** submenu with three kinds of row:

- **◎ native** — pixel size the panel already advertises. Forcing here does HiDPI supersampling at that pixel resolution; always pixel-perfect (mirror is exact 2× downscale from the virtual buffer).
- **⚡ force** — Standard-only pixel size with no native HiDPI variant. Force is the only way to get a Retina-sharp render at that resolution.
- **⊕ custom** / **⊕ custom (scaled)** — curated common logical sizes (1280×800 through 3840×2160) that aren't in the panel's advertised mode list. The first tag marks sizes where the panel has a mode at exactly 2×target (1:1 mirror, pixel-perfect). `(scaled)` means no such match exists, so the mirror is resampled — we pick the closest panel mode to minimize the scale factor (typically 0.98× on the built-in).

**Architecture note:** `CGVirtualDisplay` has two runtime limits on macOS 13–26 that the naive mirror approach trips over — (1) a mirrored VD doesn't tear down reliably via ARC, and (2) only one VD works per process. We use a single process-wide shared `CGVirtualDisplay` (sized 10240×5760), kept alive for the process lifetime, with `applySettings:` re-invoked per force to retarget. Mirror is always configured before the panel mode switch — the other order fails with `CGError 1001` on macOS 26.

Virtual descriptor uses **Display P3** primaries with D65 white point so wide-gamut content passes through on modern Apple displays. The physical panel's gamma table is copied onto the virtual via `CGSetDisplayTransferByTable` after mirror so transfer curves match.

### Crisp HiDPI (system-level)
For truly pixel-perfect HiDPI at resolutions your panel doesn't advertise at all (1920×1080, 1440×900, etc. on the built-in), the menu offers **Install Crisp HiDPI (admin + reboot)**. Writes a `DisplayVendorID-<v>/DisplayProductID-<p>` plist to `/Library/Displays/Contents/Resources/Overrides` so macOS's own mode list grows those sizes as native HiDPI. After reboot, the injected modes show up in System Settings → Displays and in our All Resolutions submenu, driven by the panel at 1:1 — no virtual display in the loop.

For Apple Silicon built-ins, the plist target is resolved from `AppleCLCD2 → DisplayAttributes → ProductAttributes.ProductID`, not `CGDisplayModelNumber` (the two disagree and windowserver matches on the former).

### Brightness
Per-display **Brightness ▶** submenu with 10/25/50/75/100% quick-pick. Built-in panels go through the private `DisplayServicesSetBrightness` (same path as F1/F2); externals use VESA DDC/CI over Apple Silicon's `IOAVService` (VCP 0x10 via `IOAVServiceWriteI2C`). Intel Macs aren't supported for DDC in this build.

### Other
- **Launch at Login** via `SMAppService`.
- **Notifications** are opt-in (checkbox); auth is requested lazily on the first actual post, not at launch.
- Menu-bar icon switches to a `display.trianglebadge.exclamationmark` glyph whenever anything is disabled or forced.

## Menu

```
DisplayDisabler v3.0
2 connected, 2 active
─────────────────────────────────────────────
● Built-in Display — 0x1
  active  │  built-in  │  main
  3420 × 2224 @2x  60Hz
  ▶ All Resolutions
  ▶ Force HiDPI
  ▶ Brightness
    Install Crisp HiDPI (admin + reboot)…
    Disable This Display
─────────────────────────────────────────────
● External Display — 0x3
  active
  5120 × 2880 @2x  60Hz
  ▶ All Resolutions
  ▶ Force HiDPI
  ▶ Brightness
    Install Crisp HiDPI (admin + reboot)…
    Disable This Display
─────────────────────────────────────────────
▶ Settings
  ├── ☐ Turn off laptop screen when external monitor is connected
  ├── ☑ Show notifications
  ├── ☑ Ask before disabling a display
  ├── ☑ Show all resolutions
  └── ☐ Launch at Login
─────────────────────────────────────────────
Quit DisplayDisabler                      ⌘Q
```

## Build

Requires Xcode Command Line Tools.

```bash
make            # build DisplayDisabler.app
make install    # copy to /Applications
make clean      # remove build artifacts
make uninstall  # remove from /Applications
```

Sources:

```
main.m             Entry point (NSApplicationMain + delegate install)
AppDelegate.m      Menu bar UI, settings, auto-manage, injector UI
DisplayManager.m   Display query, mode switching, force HiDPI pipeline
Brightness.m       DDC/CI for external + DisplayServices for built-in
HiDPIInjector.m    System-level mode-list override plist generator
Info.plist         Bundle metadata (LSUIElement = true, no dock)
Makefile           Three-sign clang flow (executable + bundle, ad-hoc)
```

## Requirements

- macOS 14 Sonoma or later (Force HiDPI needs the private `CGVirtualDisplay`, first shipped in 14)
- Apple Silicon recommended (Intel Macs work for everything except DDC brightness on external displays)
- Crisp HiDPI install requires admin credentials and a reboot

## Files written outside the app bundle

| Path | Written by | Why |
|---|---|---|
| `~/Library/Preferences/com.local.DisplayDisabler.plist` | NSUserDefaults | app settings |
| `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-<v>/DisplayProductID-<p>` | Crisp HiDPI install (admin) | extra native HiDPI modes |
| `/Library/Preferences/com.apple.windowserver.plist` | Crisp HiDPI install (admin) | `DisplayResolutionEnabled=YES` so windowserver picks up overrides |

Uninstall removes the per-display `DisplayVendorID-*` directory only; leaves `DisplayResolutionEnabled` alone because other tools may rely on it.

## vs BetterDisplay

| | DisplayDisabler | BetterDisplay |
|---|---|---|
| **App size** | ~140 KB | ~30 MB |
| **Memory** | ~50 MB RSS, ~14 MB dirty | ~120 MB |
| **Background CPU** | 0% | ~0.5% |
| **Open source** | Yes (MIT) | No |
| **Disable/enable** | Yes | Yes |
| **Force HiDPI (virtual display)** | Yes — per-panel aspect-locked options, shared-VD arch, hard-aspect-constrained mode pick | Yes |
| **Crisp HiDPI (plist injection)** | Yes | Yes (a.k.a. "Fully-scalable HiDPI") |
| **DDC brightness (external)** | Yes (Apple Silicon only) | Yes (Intel + Apple Silicon) |
| **Brightness on built-in** | Yes (DisplayServices) | Yes |
| **Auto-disable built-in** | Yes | Yes |
| **Launch at Login** | Yes | Yes |
| **EDID override** | No | Yes |
| **XDR / HDR extra brightness** | No | Yes |
| **GUI settings** | Menu bar only | Full GUI |

## How the force HiDPI path actually works

```
User picks target T in the Force HiDPI submenu.

1. If T is a native row (real modeRef)
   → switch panel to T
   → virtual at 2×T, mirror panel→virtual (mirror ratio 2:1 = pixel-perfect)

2. If T is custom (no modeRef) and panel has a mode at 2×T
   → switch panel to the 2×T mode
   → virtual at 2×T, mirror 1:1 (pixel-perfect)

3. If T is custom (no modeRef) and panel doesn't have 2×T
   → switch panel to the closest-ratio mode (min max-axis deviation)
   → virtual at 2×T, mirror scaled by that ratio (typically 0.95–0.99)

In all cases:
   - Shared CGVirtualDisplay is ensured (create-or-reuse, applySettings)
   - Mirror is configured FIRST, panel mode switch LAST
   - Gamma table copied panel → virtual after mirror
   - Pre-force panel mode captured so Stop can restore it
```

## Reverse-engineering credits

- DDC/CI packet layout & `IOAVService*` entry points — [waydabber/m1ddc](https://github.com/waydabber/m1ddc)
- Persistent-VD pattern — [sammcj/force-hidpi](https://github.com/sammcj/force-hidpi)
- Crisp-HiDPI plist format — [xzhih/one-key-hidpi](https://github.com/xzhih/one-key-hidpi)
- Fully-scalable HiDPI technique — [waydabber/BetterDisplay](https://github.com/waydabber/BetterDisplay)

## License

MIT — see [LICENSE](LICENSE).
