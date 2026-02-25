# Architecture Notes

## Repository Boundaries

- Runtime source and configuration live in version control.
- Local output, generated artifacts, and credentials stay out of committed history.
- Documentation should describe workflows that are expected to be repeated.

## Change Review

- Identify the entry point before modifying behavior.
- Keep validation steps near the changed area.
- Update release notes when the change affects setup, usage, or operations.
