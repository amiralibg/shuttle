# shuttle — agent notes

## Commits
- Never add `Co-Authored-By: Claude ...`, `Claude-Session: ...`, or any other
  AI co-authorship / session trailer to commit messages. No exceptions.
- A `commit-msg` hook enforces this and rejects offending messages.
- After cloning, enable the versioned hooks once:
  `git config core.hooksPath .githooks`

## Versions & Releases
- Initial development line is `0.1.*` (`0.1.0`, `0.1.1`, ...).
- The version string lives in `Sources/ShuttleCore/Version.swift`.
- Git release tags are `v` plus the version string (e.g., `v0.1.0`).

## Relationship to weft
- Shuttle is a scroll-based window manager (niri / PaperWM style) with smooth animations,
  keyboard-driven space navigation, and trackpad/mouse strip manipulation.
- Shuttle uses `WeftKit` from `weft` (via local path `../weft` during development or
  as a package dependency) for shared lower-level macOS mechanics:
  - Private SkyLight / CGS shims (`SkyLightShim`)
  - Accessibility & platform helpers (`WeftPlatform`)
  - Global event taps & hotkeys (`WeftInput`)
  - IPC sockets (`WeftIPC`)
