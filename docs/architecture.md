# Architecture Notes

## Repository Boundaries

- Runtime source and configuration live in version control.
- Local output, generated artifacts, and credentials stay out of committed history.
- Documentation should describe workflows that are expected to be repeated.

## App-First Smart Safety

- The menu-bar app is the primary safety surface for everyday use.
- Trusted external displays are stored in user defaults and managed through the app menu.
- Built-in display recovery is event-driven through display reconfiguration callbacks, with a short debounce before acting.
- The LaunchAgent watchdog remains a CLI fallback for users who install the smart shell helpers.

## Change Review

- Identify the entry point before modifying behavior.
- Keep validation steps near the changed area.
- Update release notes when the change affects setup, usage, or operations.
