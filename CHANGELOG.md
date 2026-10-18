# Changelog

## Unreleased

- Run isolated ChatGPT profiles next to Claude ones. Only the current
  ChatGPT app (`com.openai.codex`) is supported; ChatGPT Classic is refused.
  Default ChatGPT appears with the first ChatGPT profile.
- File → New ChatGPT Profile (⌥⌘N); the toolbar **+** offers both apps.
  Untitled Claude profiles are now named "New Claude Profile".
- Settings lists separate locations for Claude.app and ChatGPT.app.
- README and release notes describe the macOS 15 first launch (Open
  Anyway in Privacy & Security); Control-click → Open no longer works there.
- Clearing a profile's name while renaming keeps the old name instead of
  showing an error, as in Finder.
- Very long profile names no longer make Start fail with "File name too
  long": the name part of a data folder is capped at 64 bytes, and
  profiles saved with a longer, never-created folder get a capped one.
- A new profile's data folder is named after the name you give it, not
  "new-claude-profile". Folders that already exist are never moved.
- An unreadable `profiles.json` is kept as `profiles-unreadable-<date>.json`
  instead of being overwritten by the next change. Readable entries still
  load when others cannot be decoded.
- Unlisted Data: folders no profile uses, such as a deleted profile's, are
  listed below the profiles. Restore one to use that account again, or
  move it to the Trash (undoable). A folder an instance still runs in is
  never offered.
- Choosing a different app in Settings (say, Safari) is reported as the
  wrong app instead of failing on Start with a missing-file error. Claude
  is recognized by its bundle identifier.
- Lighter status checks: the two-second scan skips unrelated processes
  by their kernel command name, Start All scans once, and the list no
  longer reads app bundles or icons from disk while drawing.
- A profile that is shutting down shows "Stopping…" until its instance has
  quit, instead of a Start button that fails. Restart (⌘R) quits and reopens a profile;
  Open or Start All during shutdown start it again once it has quit.
- Stop asks the app to quit like ⌘Q, so it can save its state, then
  sends SIGTERM 10 seconds and SIGKILL 30 seconds after Stop (was
  SIGTERM, then SIGKILL after 5 seconds). Force Quit ends a stopping instance at once. An instance that
  not even SIGKILL ends shows as running again with an error instead of
  "Stopping…" forever.

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
