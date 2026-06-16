# Changelog

All notable changes to DisplayDeck are documented here. Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [2.3.1] — 2026-06-16

### Fixed
- **Accessibility no longer re-prompts after every update.** The app now signs with a stable code-signing identity instead of ad-hoc. An ad-hoc signature changes identity (cdhash) on every build, which silently invalidated the Accessibility grant that window snapping and Picture-in-Picture rely on — even though System Settings still showed it enabled. With a stable identity the grant persists across updates.
- **The "Window" menu no longer widens the menu** — its labels are now compact ("Snap Window", "Enable Snapping…") so the section fits the standard menu width.

## [2.3.0] — 2026-06-16

### Added
- **Window management (tiling / snapping).** Snap the focused window to **halves, quarters, thirds & two-thirds, maximize, center, or restore** — three ways:
  - **Global keyboard shortcuts** — `⌃⌥` + arrows (halves), `⌃⌥` + U/I/J/K (quarters), `⌃⌥` + D/F/G (thirds), `⌃⌥` + E/T (two-thirds), `⌃⌥` + Return (maximize), `⌃⌥` + C (center), `⌃⌥` + Z (restore).
  - **Drag to snap** — drag a window to a screen edge or corner and it tiles, with a live preview (Magnet-style).
  - **Menu** — a "Window" section listing every layout.

  Uses the Accessibility API (the same permission as Picture-in-Picture) — works on a stock machine, no SIP changes. Keyboard shortcuts and drag-to-snap can each be toggled under **Settings → Window**.

## [2.2.2] — 2026-06-16

### Fixed
- **Brightness boost above 100% works again.** A prior "no-washout" change clamped the EDR overlay to the display's live headroom, which silently turned the boost into a no-op on panels that report no grantable headroom (e.g. the built-in MacBook Air display). The overlay now presents the full requested boost again — genuinely brightening the screen — while still auto-suspending during Mission Control. On XDR/HDR panels it rides real headroom with detail intact; on standard panels it lifts overall luminance (with some highlight washout toward the top of the slider).

## [2.2.1] — 2026-06-16

### Changed
- **Text smoothing** is now an inline segmented control (Off · Light · Medium · Strong) in the main menu, instead of a submenu — one click, with the active level always visible.

## [2.2.0] — 2026-06-16

### Added
- **Text smoothing** control (Off → Strong) — adjusts macOS's grayscale antialiasing so text isn't thin or fuzzy on external, non-Retina, or scaled monitors. Top-level in the menu; applies after a re-login.

### Changed
- **Force HiDPI** offers more "looks-like" resolutions, now gated by a **GPU-tuned rendered-framebuffer ceiling** (auto-scaled from the Metal memory budget — 5K/6K/8K/10K tiers) instead of a flat 1.5× cap. Small / 2K panels get more options; large panels stay protected from oversized buffers.

### Fixed
- The **pin**, **picture-in-picture**, and **auto-brightness** row toggles now show an active state (accent-tinted icon) instead of looking unchanged after a click.

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

[2.3.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.1
[2.3.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.0
[2.2.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.2
[2.2.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.1
[2.2.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.0
[2.1.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.1.0
[2.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.0.0
[1.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v1.0.0
