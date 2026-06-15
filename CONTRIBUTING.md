# Contributing to DisplayDeck

Thanks for your interest! Bug reports, ideas, and PRs are all welcome.

## Build & run

```sh
make            # build the .app bundle (arm64 app + arm64e scripting addition)
make install    # build, ad-hoc sign, copy to /Applications, launch
make clean      # remove build artifacts
make zip        # produce DisplayDeck.app.zip (release artifact)
```

You need **Xcode Command Line Tools** (`xcode-select --install`) and **macOS 14+ on Apple Silicon**.

## Testing the private-API features

Most features (display enable/disable, HiDPI, brightness, warmth) work on a stock machine. A few need extra setup:

- **Window transparency / blur / keep-on-top** — require **SIP disabled** and the `-arm64e_preview_abi` boot-arg, which let the app inject its scripting addition into Dock. First launch prompts once for an admin password to install it.
- **Picture-in-Picture** — needs Accessibility permission (prompted once).

If you don't have SIP disabled, you can still develop and test everything else.

## Project layout

See the [Project layout](README.md#%EF%B8%8F-project-layout) section of the README. In short: feature-grouped modules under `src/`, the Dock payload under `sa/`, helpers in `tools/`.

## Code style

- Objective-C with ARC; match the surrounding style (naming, spacing, idioms).
- Keep changes focused and minimal; prefer the existing patterns over new abstractions.
- The build must stay **warning-free** (`-Wall -Wextra`) and **`clang --analyze`-clean**. Please run a quick analyze pass on files you touch.
- These features lean on **private CoreGraphics / SkyLight / DisplayServices APIs** — be conservative, prefer documented/observed behavior, and clamp/guard anything that could fail across macOS versions.

## Before you start

For anything beyond a small fix, **open an issue first** — it's better to agree on direction before investing significant work. If you use AI tools in any way, your contribution must follow the **[AI Contribution Policy](AI_POLICY.md)** (disclose what you used, understand your own code, and only submit focused, genuinely-needed changes).

## Pull requests

1. Branch off `main`.
2. **Keep it focused — one concern per PR** (a single bug or feature). Avoid unrelated changes such as whitespace fixes or rewording comments elsewhere in the codebase.
3. **Follow the existing coding conventions** (see [Code style](#code-style)).
4. Describe what changed and why; note anything you couldn't verify (e.g. behavior that needs a reboot, multiple displays, or SIP disabled).
5. Verify it builds (`make`) and the features you touched still work end-to-end. Tests and verification notes are very welcome.

By submitting a pull request, you agree that your contribution will be licensed under the project's **[MIT License](LICENSE)**.

Because everything here rides on private APIs, behavior can change between macOS releases — real-device verification matters more than usual. Thanks for helping keep it solid.

## Releasing (maintainers)

1. `make zip` → produces `DisplayDeck.app.zip`.
2. `gh release create vX.Y.Z --latest --title … --notes …` and upload the zip:
   `gh release upload vX.Y.Z DisplayDeck.app.zip`.
3. The Homebrew tap (`oabdrabo/homebrew-tap`) auto-bumps its cask — a scheduled
   workflow there detects the new release, recomputes the sha256, and commits.
   No manual cask edit needed (run its `Update DisplayDeck cask` workflow
   manually if you don't want to wait for the schedule).
