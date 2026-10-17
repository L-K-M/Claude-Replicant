# Changelog

## Unreleased

- Run isolated ChatGPT profiles next to Claude ones. Only the current
  ChatGPT app (`com.openai.codex`) is supported; ChatGPT Classic is refused.
  Default ChatGPT appears with the first ChatGPT profile.
- File → New ChatGPT Profile (⌥⌘N); the toolbar **+** offers both apps.
  Untitled Claude profiles are now named "New Claude Profile".
- Settings lists separate locations for Claude.app and ChatGPT.app.
- Optional menu bar item (Settings → Show in menu bar) to open, stop, and
  switch profiles without the window. While it is on, closing the window
  keeps the app running.
- Open at Launch, per profile, starts it when Claude Replicant starts;
  Settings → Open Claude Replicant at login adds it to Login Items.

## 1.0.0

- Run multiple Claude Desktop instances side by side on one Mac, each with
  an isolated data directory and independent login (Swift/SwiftUI, macOS
  14+, universal, ad-hoc signed).
- Default Claude entry: start/stop and live status for the normal,
  non-isolated Claude Desktop instance.
- Per-profile Claude Code configuration via `CLAUDE_CONFIG_DIR` and
  `CLAUDE_SECURESTORAGE_CONFIG_DIR`.
- Renamed from claude-many to Claude Replicant; the project, scheme, Swift
  module, and `Claude-Many` storage paths keep their legacy names.
- macOS tooling: `scripts/build.sh` (unit tests, universal Release build,
  ad-hoc sign + verify, `--install` to /Applications),
  `scripts/release.sh`, CI, and a tag-triggered release workflow that
  publishes ZIP/DMG assets with SHA-256 checksums.
