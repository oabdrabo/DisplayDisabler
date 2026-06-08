# Smoke Validation

This directory tracks lightweight checks for `oabdrabo/DisplayDisabler`.

## Checks

- Documentation files exist under `docs/`.
- Example configuration is valid JSON.
- Smart shell scripts pass `zsh -n`.
- Smart parser fixtures cover `display_disable list` and `system_profiler` output.
- Smart status/doctor checks cover app-only and CLI-required profiles.
- CI can inspect the repository on `main`.
- Release notes explain maintenance-facing changes.
