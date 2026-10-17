# Claude Replicant: analysis and backlog

Last full review: 2026-10-17, against `main` at 4915075. Sources: a full
read of `claude-many/`, the tests, scripts, CI, README, and the Claude
Desktop 2.31226.1 bundle in `build/investigation/`, plus six independent
helper-model reviews (bugs, UI, performance, UX, visuals, platform).
Every item below was checked against the code.

How to use this file:

- Each backlog item is self-contained: problem, where it lives (types and
  functions, not line numbers, which drift), a fix plan, and how to test.
- **Priority:** P1 correctness, data, or platform risk; P2 clear user
  value; P3 polish. **Effort:** S under an hour, M a few hours, L a day
  or more.
- **Verify** marks claims about macOS behavior that need a real Mac. Do
  the check before building on the claim.
- Model code (`claude-many/Models/`) builds and tests on Linux with a
  stub launcher (see "Testing without a Mac"); views compile only in CI.
- When an item is done, delete it here and add a CHANGELOG entry.

---

## In flight: open pull requests

These were opened on 2026-10-17 and await review. Each was reviewed by
helper models until two consecutive rounds had no important findings.
The GLM reviewer job never runs here: the `ZAI_API_KEY` secret is unset,
so it skips in seconds (it did on #7 and #8 too).

| PR | Change |
|----|--------|
| #9 | An undecodable `profiles.json` (or undecodable entries) is kept as `profiles-unreadable-<date>.json` instead of being overwritten; readable entries still load. A list that cannot be opened at all is left in place and changes are refused, before anything is touched, until the next load. |
| #10 | A new profile's data folder follows the name you give it (`work`, not `new-claude-profile-3`) until its first start. Folder names are never reused within a session, so undo cannot bind a profile to another's data. |
| #11 | Discovery prefilters on the kernel command name (`p_comm`) before any per-process syscall; views read cached bundle status; icons cached; Start All scans once. |
| #12 | Explicit `InstanceState` (running, stopping, restarting, stopped), "Stopping…" rows, Restart (⌘R); Open and Start All queue a start behind a quitting instance; Stop cancels it. |
| #13 | Copy Terminal Environment: an `export` line that points `claude` or `codex` in Terminal at a profile's CLI settings and login. |
| #14 | Per-profile color and monogram avatar with an app badge; Color menu; Start and Stop share one bordered style and width. |
| #15 | Optional menu bar item (Settings → Show in menu bar) to open, stop, and switch profiles; app keeps running without its window. Activation now takes focus and yields it (macOS 14 cooperative activation). |
| #16 | README Install section and release notes describe the macOS 15 Open Anyway flow. |
| #17 | Bundles are identified by `CFBundleIdentifier`; another app or a non-app folder is reported as the wrong app. |
| #18 | First start of a never-used profile while other instances of the same app run offers to quit them, so the sign-in reaches the new one. |
| #19 | Clearing a name during rename keeps the old name instead of an error alert. |
| #20 | Sections ("Default", "Profiles"), no zebra stripes, empty state in the list, running count in the window subtitle. |
| #21 | Data folder names capped at 64 bytes; saved profiles with an over-long, never-created folder are repaired on load. |

Merge notes: #11, #12, #13, #14, #17, #18, #19, and #20 touch
`ContentView` and/or `ProfileRowView`; expect textual conflicts after the
first merges. #12 changes `ProfilesMenuBridge` indices (13 items). #10
and #21 add the same `ClaudeProfile.withDataDirectory` helper (identical
text) so #14's `color` survives relocation. #17 changes test fixtures
(`TestBundle`): other PRs' new tests use `makeBundle()`, which #17
updates.

Leftovers from those reviews are in the backlog below (tagged with the
PR).

---

## Backlog

### P1: correctness, data, platform

#### B1. Launch through LaunchServices so TCC attributes instances to Claude (H, M, verify)
**Problem.** `RealClaudeLauncher.launch` spawns `Contents/MacOS/Claude`
with Foundation `Process` (posix_spawn). macOS treats the parent as the
"responsible process" for privacy (TCC) checks, the same reason apps
started from Terminal prompt as Terminal. Claude declares
`NSMicrophoneUsageDescription` (dictation), `NSCameraUsageDescription`,
and `NSAppleEventsUsageDescription`; Claude Replicant declares none.
Likely effects in isolated profiles only: dictation and camera silently
denied or prompting as "Claude Replicant", Files & Folders prompts for
Code sessions in `~/Documents` attributed to Replicant, and grants reset
whenever Replicant's ad-hoc signature changes (every build). Two
independent reviews reached the same conclusion.
**Verify first.** Start an isolated profile, use dictation, and watch
`log stream --predicate 'subsystem == "com.apple.TCC"'` for the
responsible identifier. Compare with Default Claude started from the
Dock.
**Fix.** Launch with `NSWorkspace.shared.openApplication(at:configuration:)`:
`createsNewApplicationInstance = true` for every launch (otherwise
LaunchServices just activates the running bundle, e.g. an isolated
instance, instead of starting Default), `arguments`, `environment`,
`activates = true`, `addsToRecentItems = false`. Wrap the returned
`NSRunningApplication` like `AttachedClaudeProcess` (pid + start time).
`ClaudeLauncher.launch` becomes async, so `ProfileManager.start` and its
callers do too. Verify that `OpenConfiguration.environment` reaches the
child: the ChatGPT mechanism depends on `CODEX_ELECTRON_USER_DATA_PATH`.
LaunchServices starts from launchd's environment, which also fixes B6.
Tests: `ClaudeLauncherTests` launch a shell script as "Claude"; an
LS-launched fixture needs a real `.app` bundle in a temp folder.

#### B2. Quit gracefully before killing (M, S)
**Problem.** `ProfileManager.stop` sends SIGTERM and SIGKILL after 5 s
(`forceKillTasks`). Electron's quit handlers run on the quit Apple Event
(Cmd-Q); SIGTERM may skip them, and SIGKILL mid-flush risks LevelDB and
IndexedDB state (worst case a signed-out profile). A "quit while a task
runs?" prompt can also outlast 5 s.
**Fix.** First `NSRunningApplication(processIdentifier:)?.terminate()`
(works for adopted pids too), then SIGTERM, and SIGKILL only after a
longer grace (15–20 s) or from an explicit Force Quit item while a row is
"Stopping…" (needs #12). Keep `handleTermination` as the single place
that clears state.

#### B3. Bring back a running instance's window (M, M, verify)
**Problem.** `RealClaudeLauncher.activate` activates the app but does not
send the reopen event. Electron apps stay running with no windows, and
Claude recreates its window only on reopen (Dock click). Opening a
running profile whose window was closed shows only a menu bar.
**Fix.** After activating (see #15 for cooperative activation), send
`kAEReopenApplication` to the pid with an `NSAppleEventDescriptor`
targeted by process identifier. Verify whether that triggers an
Automation prompt; Claude declares `NSAppleEventsUsageDescription`, but
the sender is Replicant.

#### B4. Profiles menu enablement may never apply (M, S, verify)
**Problem.** `ProfilesMenuBridge.sync` sets `NSMenuItem.isEnabled`, but
AppKit ignores `isEnabled` while `NSMenu.autoenablesItems` is true (the
default). If SwiftUI's synthesized menu auto-enables, every Profiles item
is always enabled and acts as a no-op when it does not apply. "Rename…"
also owns a bare Return key equivalent (B5).
**Verify.** With nothing selected, open the Profiles menu: is Delete
disabled?
**Fix.** `menu.autoenablesItems = false` in `install()` right after
capturing the menu. While there, stop addressing items by index and a
hard-coded count (`menu.items.count == 12`, 13 after #12): match by
title or key equivalent, and log once when an expected item is missing.

#### B5. Return is a global key equivalent for Rename (L, S, verify)
**Problem.** `ProfileCommands` binds Rename to `.keyboardShortcut(.return,
modifiers: [])`. Whenever the item is enabled, Return anywhere in the app
(Settings, an open panel) can start a rename in the main window.
**Fix.** Drop the menu shortcut and handle Return on the list with
`.onKeyPress(.return)` while the list has focus and no edit is active.

#### B6. Replicant's identity leaks into instances' environment (M, S, verify)
**Problem.** `ClaudeLaunchConfiguration.environment(inheriting:)` starts
from Replicant's own environment and removes only the location
variables, so instances inherit `XPC_SERVICE_NAME=ch.lkmc.ClaudeReplicant`,
`XPC_FLAGS`, `__CFBundleIdentifier`, and terminal variables when
Replicant was started from a shell. Chromium reads `XPC_SERVICE_NAME` at
startup. Effects unverified.
**Fix.** Remove `XPC_*` and `__CFBundleIdentifier` there (with a test in
`ClaudeLaunchConfigurationTests`), or adopt B1, which starts from
launchd's environment. Also set `process.standardInput =
FileHandle.nullDevice`.

#### B7. Undo of "New Profile" while its name field is active (M, S)
**Problem.** The rename field's text undo shares the window's undo
manager. ⌘Z past the typed text undoes the profile's creation; the row
disappears, `editingID` still points at it, and the focus loss commits a
rename of a missing id ("That profile no longer exists"), or `editingID`
stays set and blocks Open and Rename.
**Fix.** In `ContentView`, `.onChange(of: manager.profiles)` clears
`editingID`, `editingDraft`, and focus when `editingID` is no longer
listed. Also commit an in-progress edit before `beginRename` on another
row, like Finder.

#### B8. Open does nothing for an instance not yet adopted (L, S)
**Problem.** `ProfileManager.open` checks `isRunning` before `start`
rescans. If Default Claude was opened from the Dock under 2 s ago,
`start` adopts it and returns without activating; a second click works.
Since #15 the menu bar item uses the same path.
**Fix.** Refresh at the top of `open`, then activate or start; check
`handle.isRunning` before activating (a recycled pid could otherwise
bring an unrelated app forward).

#### B9. Restart should not quit an instance it cannot start again (L, S) (#12)
**Problem.** With #12, Restart quits the instance, then the queued start
fails if Claude.app has since gone missing or become unsupported, leaving
the profile stopped.
**Fix.** Offer Restart only when `lastKnownBundleStatus(for:) ==
.available` (#11) or `bundleStatus(for:)`, in the menus and in
`ProfileManager.restart`.

#### B10. A process that never exits leaves "Stopping…" forever (L, M) (#12)
**Problem.** After SIGKILL nothing is retried. A zombie (`kill(pid, 0)`
succeeds) or a process stuck in the kernel keeps its handle, so the row
stays "Stopping…" and `start` keeps refusing.
**Fix.** Treat `kp_proc.p_stat == SZOMB` as exited in
`AttachedClaudeProcess.sameProcessExists`; after SIGKILL plus a timeout,
drop the handle and report an error naming the pid.

#### B11. Failed saves leave memory and disk different (L, M)
**Problem.** `addProfile`, `renameProfile`, `removeProfile`, and
`moveProfiles` change `profiles` before `persist()`. If the save fails,
the window shows a change that is gone after relaunch, and
`ContentView.performProfileEdit` registers no undo for it. (#9 handles
the case where the list could not be opened; this is a save failure on
a readable list.)
**Fix.** Compute the new list, save it, then assign; or roll back on
failure. Register undo only for applied changes.

#### B12. Smaller correctness items (L, S each)
- `RealClaudeProcess.terminate` calls `Process.terminate()`, reachable
  for a process that already exited; signal with `kill(pid, SIGTERM)` as
  `AttachedClaudeProcess` does (ESRCH is harmless). Verify whether
  Foundation raises.
- `RealClaudeProcess.terminationHandler` reads a closure on Foundation's
  queue that the main actor writes; capture the closure in the installed
  handler and assign `nil` to `process.terminationHandler` to detach.
- `RealClaudeLauncher.executableMatches` accepts any path that starts
  with the target and ends in `" (deleted)"`. That suffix is Linux
  `/proc` behavior, not macOS; remove the branch.
- Loaded profiles are not validated: duplicate ids, two entries sharing a
  data folder, or relative paths (only by editing `profiles.json`) could
  launch two instances into one folder. Validate in `load()` and report
  dropped entries.
- Escape in the rename field may end editing before `.onKeyPress(.escape)`
  runs, so the blur commits; prefer `.onExitCommand` (verify).
- Undo of a delete restores rows but not the selection; after Delete,
  select the next row like Finder.
- `startAll` reports only the last failure and still tries apps whose
  bundle is missing, though `canStartAll` ignores them; skip entries
  whose app is not `.available` and aggregate the remaining failures.
- Quitting Replicant during a stop's grace period drops the pending
  SIGKILL; finish pending stops in `applicationWillTerminate`.
- Accessibility: label the row's … menu ("More actions for Work"), name
  the profile in Start/Stop, combine the row into one VoiceOver element.

### P2: features with clear user value

#### F1. Recover removed profiles; delete data on purpose (M)
Delete keeps the data folder, but once the undo stack is gone there is no
way back in the app, and re-adding "Work" gets a fresh folder (a new
login). In `load()`, list folders under `dataRootDirectory` that no
profile references; offer **Restore** (an `addProfile(adopting:)` that
takes the existing folder and guesses `app` from `.claude`/`.codex`) and
**Move to Trash** (`FileManager.trashItem`, never `removeItem`). Add a
"Move its data to the Trash" checkbox to the delete alert. Tests: orphan
detection and adoption in `ProfileManagerTests`.

#### F2. Open profiles automatically (M)
Per-profile "Open when Claude Replicant starts" (optional Codable field,
default false; started after `load()`), plus a Settings toggle for
opening Replicant at login via `SMAppService.mainApp`. With #15 the app
can then live in the menu bar from login on.

#### F3. Notice app updates (M)
Record each app's `CFBundleShortVersionString` when profiles start; when
the bundle's version changes while they run, show a banner "Claude was
updated. Restart running profiles to use it." with Restart All (#12).
Claude's updater may relaunch without `--user-data-dir`, turning a
profile into Default (README warns); detect an isolated instance
vanishing while the executable's mtime changed and say so. Show the
installed version in Settings and flag versions newer than the ones the
mechanism was verified with (README: Claude 2.31226.1, ChatGPT
26.1007.71326).

#### F4. Find a profile's window (M)
From a row, flash an outline over that pid's windows (frames from
`CGWindowListCopyWindowInfo` filtered by owner pid; `SmokeTests` already
counts windows this way) and bring them forward. On-brand name:
"Voight-Kampff spotlight".

#### F5. Diagnostics (M)
Instances' stdout/stderr go to `/dev/null`, nothing logs, and a crash
looks like a Stop. Mark expected terminations in `stop`; post a
`UNUserNotificationCenter` notice when an instance exits on its own;
route instance stderr to `~/Library/Logs/Claude Replicant/<slug>.log`;
add Settings → Copy Diagnostics (versions, bundle paths, last errors).

#### F6. More ways in (S–M each)
- Dock menu (`applicationDockMenu`) listing profiles.
- URL scheme `claude-replicant://open?profile=<id or slug>` handled with
  `.onOpenURL`, for Raycast, Alfred, and Stream Deck.
- App Intents (Open Profile, Stop All) for Shortcuts and Spotlight.
- Global hotkeys per profile.
- Profile launchers: `Claude – Work.app` stubs in `~/Applications` that
  call the URL scheme, so Spotlight and the Dock can start one account.

#### F7. Smaller ideas (S each unless noted)
- Account note: optional text (the email) shown in the row subtitle
  instead of the folder path.
- Tip in the empty state: Claude's appearance settings are per profile,
  so a different theme per profile tells windows apart.
- When `/Applications/Claude.app` is missing, offer copies registered
  with LaunchServices (`NSWorkspace.urlForApplication(
  withBundleIdentifier:)`), e.g. in `~/Applications`.
- Uptime or "last opened" in the subtitle.
- Memory per instance (sum of the process tree via `proc_pid_rusage`) (M).
- "Include in Start All" per profile, off for Default entries; or Start
  Selected.
- Warn without blocking when a rename duplicates another name.
- Opening several running profiles activates each in turn; activate only
  the last.
- Dock tile badge with the running count (`NSApp.dockTile.badgeLabel`).
- An inspector ("Replicant ID card"): color, account note, folder size,
  window count, Copy Terminal Environment, last opened (M).
- New profile from another's Code settings (`settings.json`, plugins;
  never credentials) (M).
- Scroll to a new profile's row so its rename field is visible
  (`ScrollViewReader`).
- Sort and filter once there are many profiles; String Catalog for
  localization (M).

### P3: performance follow-ups (after #11)

- **Exit events instead of polling** (M): `AttachedClaudeProcess` polls
  every 500 ms per handle. Use `DispatchSource.makeProcessSource(
  identifier:eventMask: .exit)`, re-checking `sameProcessExists` after
  creating the source (pid reuse).
- **Instant outside changes** (S): observe
  `NSWorkspace.didLaunchApplicationNotification` and
  `didTerminateApplicationNotification` to refresh immediately; then
  lengthen the 2 s interval and pause while the window is occluded
  (`NSWindow.occlusionState`).
- **Scan off the main actor** (M): with the `p_comm` prefilter a scan is
  cheap, but `runningHandles` could still run detached and hand results
  back; keep `start`'s synchronous pre-launch scan.
- **Rows re-render on any change** (S): rows read the whole running set
  through the manager. Pass each row its own `InstanceState` and icon as
  values and make it `Equatable`.
- **Small items**: replace `commandContextSignature`'s string building
  with a `Hashable` struct; precompute resolved profile paths for
  `profileID(owning:)`; scan `KERN_PROCARGS2` bytes for the needed
  `NAME=` prefixes instead of decoding the whole environment; stop
  re-filtering `listedProfiles` several times per render.

### P3: visual and layout

- Row titles are all `.headline`; use `.body` with `.fontWeight(.medium)`.
- Status is a 10 pt dot, color only (green, gray, orange with #12); add
  a shape change or a word ("Running") for color-blind users.
- The status line counts running instances only; mention stopping ones
  ("1 stopping, 2 of 4 running") after #12.
- The rounded-border rename field is taller than the title; the row
  jumps. Use a plain style at the title's height.
- Settings: drop `.padding()` around the grouped form; make the
  headerless paragraph the Data section's footer in `.callout`.
- One presenter (title, symbol, tint) for bundle status, used by the
  banner and Settings; today their wording differs.
- Banner: make "Locate …" the prominent action; merge stacked banners.
- The row's `ellipsis.circle` at `.frame(width: 16)` is faint; use
  `ellipsis` at 24×24 in `.secondary`.
- Toolbar "New Profile" may render as icon, text, and chevron on macOS
  26; `.labelStyle(.iconOnly)` (verify).

### P3: theming and delight

- An `AccentColor` from the icon's warm/cool split (warm for Claude,
  cool for ChatGPT); today the app is system blue.
- Show `media-sources/replicant-portraits.png` in the empty state and the
  About panel with the unused `AppBranding.subtitle` ("Give Claude the
  Double Impact"); set `NSHumanReadableCopyright` (empty) from LICENSE.
- **Voight-Kampff test** (M): an Isolation Check sheet that inspects each
  running instance (argv, environment, data folder, Code config folder,
  keychain namespace) and reports whether it is really isolated.
- **Double Impact** (S): with exactly two instances running, the status
  reads "Double Impact".
- **Side by side** (L): tile two instances left and right (needs
  Accessibility permission).
- **Retire** (S): opt-in Blade Runner wording for Delete, never the
  default.
- Not recommended: per-profile app copies for distinct Dock icons
  (modifying the bundle breaks its signature, copies do not update, and
  TCC sees a new app).

### P3: code health, CI, docs

- Three hand-written copies of the action set (Profiles menu, context
  menu, row … menu) already differ. Derive them from one action model,
  and move `commandContext` into a pure, unit-tested function.
- `ProfileCommandContext.selectionCount` is never read.
- CI builds on `macos-15` with its default Xcode while AGENTS.md names
  Xcode 26.6 / Swift 6.3.3; pin `DEVELOPER_DIR` in `ci.yml` and
  `release.yml`, or document the floor.
- Started from Terminal, Replicant's children share its process group,
  so Ctrl-C in that Terminal also kills the Claude instances (development
  only); B1 removes this, otherwise spawn in a new process group.
- Turn on the hardened runtime (`ENABLE_HARDENED_RUNTIME`); free for
  this app and required for notarization.
- An interrupted smoke run leaves `/tmp/claude-many-smoke-run`, so the
  next `scripts/build.sh` opens real Claude windows; ignore stale flags.
- Discovery finds instances only by the configured bundle's executable
  path; fall back to `NSRunningApplication.runningApplications(
  withBundleIdentifier:)` for moved bundles.
- README's top Download link uses the old `L-K-M/claude-many` path
  (works through GitHub's redirect). The release body is a YAML literal
  block, so line breaks there may show in the rendered notes (#16).
- After #12, README says "A stopped profile shows Stopping…"; it should
  say a profile that is shutting down, and that `start` itself still
  refuses during shutdown (only Open and Start All queue).
- `p_comm` prefilter (#11) misses an instance started through a hard
  link with another name; pathological.
- After #21: a dash fused with a trailing combining mark survives the
  trailing-dash strip in `slug(for:)` (cosmetic); the repair's length
  check measures the decomposed name, which over-repairs some never-
  created names that were legal (harmless); no test covers a repaired
  name colliding with an existing capped folder.
- After #9: a refused undo (list blocked) still registers a redo in
  `ContentView.registerRestore`; have `restoreProfiles` report whether it
  ran. Add a test that a refused `removeProfile` does not quit a running
  instance. Treat a list that disappears between a failed decode and the
  set-aside as set aside, not as blocked.
- After #10: `restoreProfiles` could also add restored folder names to
  the session's claimed set (defensive; every name is claimed today), and
  `keepingDataDirectoryInUse` could read `location.dataDirectory` rather
  than `dataDirectory`, which falls back to the app's real folder for
  Default entries. Assert in `testUndoNeverPointsAProfileAtAnother…`
  that the second profile gets a numbered folder, so dropping the claim
  set fails a test. Removing a folder that a failed launch created would
  stop it pinning the placeholder name (a delete; weigh carefully).
- The menu bar preference (#15) is read from `UserDefaults.standard` in
  the app delegate; inject it if that needs a test.
- Menu bar item (#15): a running profile's row is disabled when its
  bundle has gone missing, though bringing it forward needs no bundle;
  File → New Profile stays enabled with the window closed but does
  nothing; a pending error reopens the window on the next menu action.

---

## Testing without a Mac

The model layer compiles on Linux with Swift 6.3 (swiftly) when
`ClaudeProcess.swift` is replaced by its protocols plus a stub
`RealClaudeLauncher`, and SwiftUI's `move(fromOffsets:toOffset:)` is
supplied for arrays. Linux XCTest cannot run synchronous `@MainActor`
test methods, so the harness rewrites them as `async` and `wait(for:)`
as `await fulfillment(of:)`. `ClaudeLauncherTests`, `SmokeTests`, and
all views need macOS; CI (`scripts/build.sh --clean` on `macos-15`)
covers them.

## Checks only a Mac can do

- B1 TCC attribution and `OpenConfiguration.environment`.
- B3 reopen event and any Automation prompt.
- B4 menu enablement with `autoenablesItems`.
- #14 avatars and Color menu swatches, light and dark mode.
- #15 the label's `.task` keeps status current with the window closed;
  activation from the menu bar brings the instance forward (`NSApp.activate()`
  may not be granted synchronously before `yieldActivation(to:)`; if not,
  yield on the next run loop turn); the Dock icon reopens the window.
- #20 subtitle placement on macOS 14, 15, and 26.
