# Changelog

## Unreleased

- Run isolated ChatGPT profiles next to Claude ones. Only the current
  ChatGPT app (`com.openai.codex`) is supported; ChatGPT Classic is refused.
  Default ChatGPT appears with the first ChatGPT profile.
- File → New ChatGPT Profile (⌥⌘N); the toolbar **+** offers both apps.
  Untitled Claude profiles are now named "New Claude Profile".
- Settings lists separate locations for Claude.app and ChatGPT.app.
- Very long profile names no longer make Start fail with "File name too
  long": the name part of a data folder is capped at 64 bytes, and
  profiles saved with a longer, never-created folder get a capped one.

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
