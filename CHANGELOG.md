# Changelog

All notable changes to DisplayDeck are documented here. Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [2.1.0] — 2026-06-15

### Changed
- **Renamed from DisplayDisabler to DisplayDeck** — the app does far more than disable displays (resolutions, brightness, warmth, window control, keep-awake), so the name now reflects the scope. Bundle id, paths, Homebrew cask (`oabdrabo/tap/displaydeck`), and website all moved accordingly. The old repo URL redirects.

## [2.0.0] — 2026-06-15

### Added
- **Warmth** — per-display color-temperature slider (6500 K → ~3400 K) via gamma ramps, persisted, restores native ColorSync at 0%.
- **EDR brightness boost above 100%**, clamped to the display's real, learned headroom; auto-suspends during Mission Control.
- **Inline auto-brightness** toggle on the brightness row.
- **Window transparency** for any app via a self-contained scripting addition injected into Dock, plus **frosted-glass blur**, per-app **keep-on-top**, and **picture-in-picture**.
- **Force HiDPI** "More Space" supersampling tier and persistent crisp-HiDPI override plists.
- **Disable failsafe** — re-enables the built-in display if a disconnect (or a stale/phantom external) would otherwise leave no usable screen.
- Launch-at-login on by default.

### Changed
- Curated, correctly ordered resolution picker (★ = panel-native); removed duplicate/sub-60 Hz/absurd entries.

## [1.0.0] — 2025-10-08

### Added
- Initial release: disable/enable any display, Force HiDPI via a mirrored virtual display, brightness control, and keep-awake.

[2.1.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.1.0
[2.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.0.0
[1.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v1.0.0
