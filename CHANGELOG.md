# Changelog

All notable changes to DisplayDeck are documented here. Format follows [Keep a Changelog](https://keepachangelog.com); versions follow [SemVer](https://semver.org).

## [2.7.1] — 2026-06-19

### Changed
- **Internal cleanup only — no user-facing change.** Removed dead code carried since earlier releases: an unused virtual-display termination handler (and its deferred-teardown bookkeeping) and three unused single-field relay setters. Behaviour is identical to 2.7.0.

## [2.7.0] — 2026-06-18

### Changed
- **Force HiDPI offers higher "looks like" resolutions.** It previously stopped at **3200×2000**; on 8 GB+ GPUs it now goes up to **3840×2400**, with **3360×2100** and **3456×2160** added in between. Force HiDPI renders to a virtual display at **2× the chosen size**, and the per-GPU framebuffer ceiling that gates this was conservative — a 3840×2400 target is a ~150 MB buffer, far under budget — so the ceiling was raised and finer scale steps added. (The window server redraws everything at that 2× size each frame, so the largest options ask more of the GPU.)

## [2.6.2] — 2026-06-18

### Fixed
- **The Warmth slider is live across its whole range again.** The 2.6.1 auto-night change clamped warmth to a floor when auto was on, so dragging the lower part of the slider did nothing at night. Auto-night now treats the slider as the night **peak** and scales it by the schedule, so the slider always changes the warmth; with auto off it stays a direct, constant warmth.

## [2.6.1] — 2026-06-18

### Fixed
- **Warmth now sticks across display changes.** macOS wipes the gamma table on resolution/HiDPI changes and sleep-wake, which silently dropped warmth until the night schedule next moved — the "sometimes warm, sometimes not". DisplayDeck now re-applies warmth right after a display reconfiguration and re-asserts it every minute, so it stays put.
- **Auto-night no longer cancels your manual warmth during the day.** Turning on the moon (auto) used to set the screen neutral until evening; now auto only ever *adds* night warmth on top of whatever you've set, so your manual warmth always holds. (The moon lights only the **auto-night schedule** — your warmth can be on from the slider with the moon off.)

## [2.6.0] — 2026-06-18

### Added
- **Help & support in Settings** — quick links to **support the app**, **report a bug**, and **request a feature** (opens a pre-labeled GitHub issue).

### Fixed
- **Brightness and Warmth no longer disappear when a display's HiDPI is forced.** Forcing a resolution collapsed that display's section to just "Stop Forced HiDPI" — the brightness and warmth sliders were dropped, even though both still drive the real panel while it's mirrored. They're back. (Resolution, Force HiDPI, Crisp HiDPI and Disable stay hidden during a force on purpose — changing the physical mode would fight the active mirror, so stop the force first.)

## [2.5.3] — 2026-06-18

### Changed
- **Row alignment made consistent across the rest of the menu.** The remaining icon-less informational rows now carry icons too, so none read as indented: the **inactive-display info line** (resolution/HiDPI/Hz) and the Transparency **"Backend not loaded"** / **"No windows"** states. The other submenus — Resolution, Force HiDPI, Snap Window, Settings, Keep-Awake durations — already used consistent column/checkmark layouts and were left as-is.

## [2.5.2] — 2026-06-18

### Changed
- **Remote Access menu rows line up consistently now.** The status, "This Mac", and per-Mac rows were plain text with an empty icon gutter, so they read as oddly indented next to the rows that had icons. Every row now carries an icon — a status dot, a desktop glyph for this Mac, and a **filled circle (online) / hollow circle (offline)** per Mac — so it reads as one uniform list instead of mixed indentation.

## [2.5.1] — 2026-06-18

### Changed
- **Remote Access now lists this Mac too**, marked **(this Mac)** with its live ● online / ○ offline status, so the device list is a complete view of every Mac on the relay — not just the others. (Shown for status; there's nothing to connect to on yourself, so it has no actions.)

## [2.5.0] — 2026-06-18

### Added
- **Remote Access — file transfer (SFTP).** Each discovered Mac now has a **Files** action that opens an SFTP session over the same relay tunnel, so you can move files to/from it alongside Screen Share and SSH.
- **Live peer online status.** Discovered Macs show **● online / ○ offline** — the relay now reports whether each Mac's tunnel is actually up, instead of just listing every authorized Mac, so you don't click into a peer that isn't there.
- **Keep awake while on.** An optional (default on) toggle holds an idle-sleep assertion while Remote Access is enabled, so the Mac stays reachable instead of dozing off and dropping the tunnel. (Idle sleep only — a closed laptop lid still sleeps.)
- **Connection error reasons.** When the tunnel can't connect, the status line now says *why* — "Relay unreachable", "Relay rejected the key", "Relay port already in use", "Relay host not found", etc. — instead of an endless "Connecting…".

## [2.4.4] — 2026-06-18

### Fixed
- **Quitting now tears down Remote Access cleanly.** The reverse-SSH tunnel (and any Screen-Sharing forwards) were left running orphaned after the app quit, holding the relay's ports — so the next launch couldn't rebind them and the tunnel was stuck reconnecting. They're now stopped on quit, while the on/off setting is preserved so it still auto-restores next launch.
- **Quitting now restores windows you'd made transparent**, matching the documented behaviour. Previously they stayed transparent (the Dock-side overlay outlives the app) until the affected apps were relaunched.

### Changed
- Internal cleanup: removed dead code (an unused connect-command builder and a redundant font-smoothing branch). No behaviour change.

## [2.4.3] — 2026-06-18

### Changed
- **Text smoothing is now a simple On/Off toggle** instead of a multi-level control. Pixel-diffing rendered text confirmed that modern macOS treats `AppleFontSmoothing` as binary: levels Light/Medium/Strong come out **byte-identical** — only **Off vs On** actually changes how glyphs are drawn (off = thinner/lighter, on = dilated). The old strength gradient was removed by macOS years ago, so a slider implied distinctions that don't exist. On writes the standard level; Off disables smoothing. (Still applies after a re-login, since apps read it at launch.)

## [2.4.2] — 2026-06-18

### Changed
- **Text smoothing is now a slider, not four spelled-out buttons.** It's a single discrete control — the same icon + slider + value layout as the Brightness and Warmth rows — that snaps **Off · Light · Medium · Strong** with the level name as its live label. Takes far less width and reads as one interactive control. It also **always shows your current level**: previously, when the system key was unset (the default state) nothing was highlighted, so you couldn't tell where you were; it now reflects the macOS default (Medium). Strong is the real ceiling — macOS's `AppleFontSmoothing` tops out at that level.

## [2.4.1] — 2026-06-18

### Fixed
- **Stopping Force HiDPI no longer leaves a phantom display that can freeze the pointer.** Turning off a forced HiDPI resolution un-mirrored your panel but left the backing **virtual display** (a 2×-resolution framebuffer, e.g. 6400×4000) alive and parked in the display arrangement. That orphaned screen kept loading the WindowServer and could strand the mouse/trackpad off-screen — recoverable only by quitting the app. Stop now **destroys** the virtual display and flushes the removal with a display-reconfiguration pass (the same teardown the disconnect path uses), so the arrangement returns to just your real screen(s). Verified with an integration test across repeated force/stop cycles.

## [2.4.0] — 2026-06-16

### Added
- **Remote Access — reach your Mac (and your other Macs) from anywhere, nothing to install.** DisplayDeck holds an auto-reconnecting reverse-SSH tunnel through a relay host you control (e.g. your own server), forwarding this Mac's **SSH** and **Screen Sharing** — no Tailscale, Headscale, or third-party agent. It's also a **client**: your other Macs on the same relay are **auto-discovered**, so you can **Screen Share** or **SSH** into them straight from the menu. The relay is set inline as a single `user@host:port` field; the on/off switch lives on the menu's Remote Access row.
- **Automatic night warmth.** Warmth now eases on in the evening and back off by morning on a schedule (dusk/dawn ramps), so the screen warms automatically without touching the slider. Toggle it with the **moon** button on the Warmth row — on by default.

### Changed
- **Menu sweep for consistency.** **Keep Awake** and **Remote Access** are each a single row with an inline on/off **toggle** plus a **›** chevron that opens its options (Keep Awake's timed durations; Remote's relay + connect list). Submenus size to their content instead of a fixed wide frame, the **Snap by dragging** / **Keyboard shortcuts** toggles moved into the **Window** submenu, and the **Text smoothing** control got a proper section header.

## [2.3.5] — 2026-06-16

### Fixed
- **Menu-bar mug icon no longer looks oversized or clipped on some Macs.** It now scales to the actual menu-bar height (clamped to the standard 15–18pt glyph range) instead of a fixed point size, so it fits correctly on standard (non-notched) menu bars and external displays, not just notched MacBooks.

## [2.3.4] — 2026-06-16

### Fixed
- **Homebrew install now works on macOS 14 and later.** The cask was mistakenly pinned to *exactly* Sonoma (`depends_on macos: :sonoma`), so installs on Sequoia / macOS 26 were rejected with "does not run on macOS versions other than Sonoma." It now allows `>= :sonoma`.

### Changed
- Clarified that the app is **self-signed** (not ad-hoc), and documented the macOS 15+ Gatekeeper path (**System Settings → Privacy & Security → Open Anyway**, since right-click → Open was removed). The Homebrew cask still strips the quarantine flag automatically.

## [2.3.3] — 2026-06-16

### Changed
- Window snap-menu glyphs now use a **16:10 screen aspect** instead of the previous too-wide (~16:9) shape, so they read as a real Mac display.

## [2.3.2] — 2026-06-16

### Added
- The **Window** snap menu now shows a **layout glyph** next to each item — a shaded region on a screen outline (Rectangle/Magnet style) — so each snap target is identifiable at a glance. Adapts to light/dark.

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

[2.7.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.7.1
[2.7.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.7.0
[2.6.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.6.2
[2.6.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.6.1
[2.6.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.6.0
[2.5.3]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.5.3
[2.5.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.5.2
[2.5.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.5.1
[2.5.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.5.0
[2.4.4]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.4.4
[2.4.3]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.4.3
[2.4.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.4.2
[2.4.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.4.1
[2.4.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.4.0
[2.3.5]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.5
[2.3.4]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.4
[2.3.3]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.3
[2.3.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.2
[2.3.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.1
[2.3.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.3.0
[2.2.2]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.2
[2.2.1]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.1
[2.2.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.2.0
[2.1.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.1.0
[2.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v2.0.0
[1.0.0]: https://github.com/oabdrabo/DisplayDeck/releases/tag/v1.0.0
