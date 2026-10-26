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
- Item IDs (B1, F4, …) are stable; gaps are items that moved to an open
  pull request below. PR descriptions refer to these IDs.

---

## In flight: open pull requests

All opened on 2026-10-17 and awaiting the owner's review; none is merged.
Each was reviewed by helper models until two consecutive rounds had no
important findings; every important finding was fixed with a regression
test where one was possible. Reviewers: devin swe-2-max throughout, and
DeepSeek V4.1 Flash through opencode until its Venice credit ran out;
later rounds of #23, #24, #26, and #27 had devin alone or with Meituan
LongCat 2.5 (free). The GLM reviewer job never runs here: the
`ZAI_API_KEY` secret is unset, so it skips in seconds.

**Merge order.** Six PRs are stacked on another open PR (base branch in
the table). Merge the base first; with "delete branch on merge" on,
GitHub retargets the stacked PR to `main` by itself.

| PR | Base | Change |
|----|------|--------|
| #9 | main | An undecodable `profiles.json` (or undecodable entries) is kept as `profiles-unreadable-<date>.json` instead of being overwritten; readable entries still load and are saved, also when the file vanishes mid-load. A list that cannot be opened at all is left in place and changes are refused, before anything is touched, until the next load; a refused Undo registers no Redo. |
| #10 | main | A new profile's data folder follows the name you give it (`work`, not `new-claude-profile-3`) until its first start. Folder names are never reused within a session (restored names stay claimed), so undo cannot bind a profile to another's data. |
| #11 | main | Discovery prefilters on the kernel command name (`p_comm`) before any per-process syscall; views read cached bundle status; icons cached; Start All scans once. |
| #12 | main | Explicit `InstanceState` (running, stopping, restarting, stopped), "Stopping…" rows, Restart (⌘R), offered and allowed only while the app can start again (was B9); Open and Start All queue a start behind a quitting instance; Stop cancels it. |
| #13 | main | Copy Terminal Environment: an `export` line that points `claude` or `codex` in Terminal at a profile's CLI settings and login. |
| #14 | main | Per-profile color and monogram avatar with an app badge; Color menu; Start and Stop share one bordered style and width. |
| #15 | main | Optional menu bar item (Settings → Show in menu bar) to open, stop, and switch profiles; app keeps running without its window. Activation takes focus and yields it (macOS 14 cooperative activation). With the window closed, File → New Profile opens it and Open Profiles Folder works; a running profile stays selectable when its app is missing; an error nobody saw no longer reopens the window later. |
| #16 | main | README Install section and release notes describe the macOS 15 Open Anyway flow; Download link points at the renamed repository. |
| #17 | main | Bundles are identified by `CFBundleIdentifier`; another app or a non-app folder is reported as the wrong app. |
| #18 | main | First start of a never-used profile while other instances of the same app run offers to quit them, so the sign-in reaches the new one. |
| #19 | main | Clearing a name during rename keeps the old name instead of an error alert. |
| #20 | main | Sections ("Default", "Profiles"), no zebra stripes, empty state in the list, running count in the window subtitle. |
| #21 | main | Data folder names capped at 64 bytes, with no dash left fused to a combining mark; saved profiles with an over-long, never-created folder are repaired on load. |
| #22 | #12 | Stop sends the quit Apple event ⌘Q sends, then SIGTERM after 10 s and SIGKILL after 20 more, each only while the process runs (`StopTimeline`). Force Quit while stopping. A process that outlives SIGKILL shows as running again with an error (a deleted profile's is let go); zombies count as exited. Was B2, B10. |
| #23 | #12 | Profiles menu enablement sticks: auto-enabling off, items matched by title instead of index, re-synced whenever a menu opens. Rename's bare Return moved from the menu to the list (plain Return only). Was B4, B5. |
| #24 | #12 | Update awareness: banner to restart instances still on an old app version (or postpone), banner when a profile quit for an update (the updater reopens it as Default), app version in Settings with a note past the checked version. Was F3. |
| #25 | #15 | Opening a running profile also sends the reopen Apple event a Dock click sends, so a closed window comes back. Was B3. |
| #26 | #15 | Open at Launch per entry (Default entries too), started once per run from the window or the menu bar item; Settings → Open Claude Replicant at login (`SMAppService`). Was F2. |
| #27 | #9 | Unlisted Data: folders no profile uses (a deleted profile's, or all of them after a lost list) can be restored as profiles or moved to the Trash (undoable). Nothing is offered while the list cannot be opened or while an instance runs in the folder. Was F1. |

Merge notes:

- #11, #12, #13, #14, #17, #18, #19, #20, #22, #23, #24, #26 and #27
  touch `ContentView` and/or `ProfileRowView`; expect textual conflicts
  after the first merges. #20's sections and #27's Unlisted Data section
  both restructure the `List`.
- #10 and #21 add the same `ClaudeProfile.withDataDirectory` helper
  (identical text) so #14's `color` survives relocation.
- #17 changes test fixtures (`TestBundle`): other PRs' new tests use
  `makeBundle()`, which #17 updates; #24's tests write their own
  Info.plist.
- #15 and #23 both edit the Profiles menu's "Open Profiles Folder in
  Finder" button: keep #23's `ProfilesMenu.Item.openFolder.title` with
  #15's `MacPlatform.revealProfilesFolder()` action.
- #22 and #25 add the same `NSAppleEventsUsageDescription` line
  (identical text), which merges cleanly.
- #22, #24 and #27 extend `ProfileManager` in separate regions; #24 and
  #26 both edit `SettingsView`.

Leftovers from all these reviews are in the backlog below (tagged with
the PR).

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
- `startAll` can lose failures entirely: `start` sets `lastError = nil`
  on success, so a failed entry followed by a started one shows nothing
  (the menu bar item's `perform` from #15 inherits this). It also still
  tries apps whose bundle is missing, though `canStartAll` ignores them.
  Skip entries whose app is not `.available`, collect failures, and
  report them after the loop.
- Quitting Replicant while a stop escalates drops the remaining steps
  (with #22 the escalation lasts up to 35 s); finish or hand off pending
  stops in `applicationWillTerminate`.
- Accessibility: label the row's … menu ("More actions for Work"), name
  the profile in Start/Stop, combine the row into one VoiceOver element.

### P2: features with clear user value

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
  Double Impact").
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
- Turn on the hardened runtime (`ENABLE_HARDENED_RUNTIME`); required for
  notarization. Since #22 and #25 send Apple events, it then also needs
  the `com.apple.security.automation.apple-events` entitlement.
- An interrupted smoke run leaves `/tmp/claude-many-smoke-run`, so the
  next `scripts/build.sh` opens real Claude windows; ignore stale flags.
- Discovery finds instances only by the configured bundle's executable
  path; fall back to `NSRunningApplication.runningApplications(
  withBundleIdentifier:)` for moved bundles.
- `p_comm` prefilter (#11) misses an instance started through a hard
  link with another name; pathological.
- #9: the race where `profiles.json` vanishes between a failed read and
  setting it aside has no test (it needs the file to disappear mid-load;
  a `ProfileStore` seam would allow one).
- #10: a removed folder name stays claimed for the session, so names
  "burn forward" (`work-2` after an undone rename; intended for undo
  safety). The "already fits" check accepts `work-0` or `work-007`.
  `testUndoKeepsTheUsedFolderWhenTheOldNameExistsToo` passes on the
  running-handle branch alone; add a stopped-instance case. Removing a
  folder that a failed launch created would stop it pinning the
  placeholder name, but would be the first code path that deletes
  profile data (declined so far).
- #12: disabled items still show zero counts ("Restart 0 Profiles"); a
  start queued behind a stopping instance reports a missing bundle only
  after the old process exits; the Profiles menu says "Stop" where the
  row menu says "Cancel Restart" for a restarting entry.
- #15: the menu bar preference is read from `UserDefaults.standard` in
  the app delegate (inject it if a test needs it); ⌘N then ⌥⌘N with the
  window closed creates only the second profile (`pendingNewProfile` is
  one slot); the label keeps the 2 s scan running all the time, so slow
  it down or pause it while the app is inactive; an identical error
  repeated while the window is minimized does not bring it forward;
  `perform` drops an error nobody saw yet (say a load error at a
  windowless login) before the next menu action.
- #16: the release notes repeat README's Install steps and can drift.
- #21: the repair measures names decomposed, so it re-slugs a few
  never-created names that were legal on APFS (harmless; declined).
  Folder uniqueness compares raw path strings, so an NFD label and an
  NFC one could get the same never-created folder (rare; also in
  `addProfile`): compare precomposed names.
- #22: clicking Force Quit repeatedly restarts the 5 s give-up wait; a
  process that is not a running app gets SIGTERM twice; Force Quit is
  not offered once an unkillable instance counts as running again, and
  on a "Restarting…" row it ends the old instance and lets the restart
  proceed (intended; the label could say so); a deleted profile's
  give-up error names only the PID; zombies-as-exited has no test
  (needs a real process); `start(id:)` does not clear stop bookkeeping
  if called while stopping (no UI path); no test drives a handle whose
  quit request is ignored through the real `terminate()` path.
- #23: with Full Keyboard Access focus on a row's button, Return starts a
  rename; Return that does not apply now beeps instead of being eaten by
  the menu item; the re-sync runs on every menu tracking session, not
  just the menu bar's; a menu SwiftUI fills partially could still use up
  the one-time missing-item log (re-arm it once all items are found);
  `matchedItems` would mislabel an `NSMenuItem` SwiftUI reused for
  another command (not observed).
- #24: Later and the quit-for-update notice live in memory only (moot
  until instance versions survive a relaunch, which needs reading a
  running process's version); the installed version is read every scan
  (cache by Info.plist modification date); an instance started while the
  bundle was mid-replacement is stamped with the new version; a quit
  whose termination arrives after a scan already saw the new version is
  missed (track the version last seen while each instance ran); a nil
  version at quit time (app removed, then reinstalled within two
  minutes) is reported as an update; the restart banner counts Default
  Claude among "profiles" and Restart All restarts it too; a downgrade
  reads as "previous version"; Later is pinned to a version string, so
  a downgrade and upgrade back stay hidden.
- #25: the reopen event goes to a PID on a background queue without
  rechecking that the process is still the same (`guard handle.isRunning`
  in the closure closes it); repeated Opens on a hung instance each park
  a worker thread (dedupe in-flight sends); the reopen sender is not
  injectable, so no test pins it off the main thread; the first reopen is
  lost while the Automation prompt shows (documented).
- #26: a failed first `load()` still uses up the once-per-run start, and
  a launch failure replaces a load error instead of adding to it;
  `load()` never clears an old load error after the file is fixed;
  marked profiles start only from the window or the menu bar label, so a
  launch with neither (menu bar item off, window restored closed) starts
  nothing until the window opens; each marked profile triggers its own
  process scan (scan once before the loop); Default ChatGPT stays marked
  while unlisted and opens again when re-listed; deleted profiles' IDs
  stay in `opensAtLaunchProfileIDs`; `SMAppService.Status.notFound`
  shows as Off. Reviewers claimed `unregister()` only exists as async;
  CI compiled the synchronous `try` with no "no throwing call" warning,
  so the error path is live.
- #27: putting back to a path that is occupied again surfaces the raw
  Cocoa error; trashing happens before the undo manager is resolved, so
  with no undo manager the promised ⌘Z is missing; `FileTrash.system`
  falls back to the original URL when `trashItem` returns none, which
  breaks that undo; an instance whose argv and environment disagree is
  invisible to the in-use check (count argv-only directories too);
  discovery only finds instances of the configured bundle path, so a
  wrong path in Settings hides running instances from it; folders added
  in Finder, or an untracked instance starting in an offered folder,
  show only after the next rescan (load or a list change); the
  untagged rows' own context menu may lose to the list's
  `contextMenu(forSelectionType:)` (verify on a Mac); after a failed
  rewrite of a partly unreadable list hides the section, the next
  successful save does not rescan, so it stays empty until a reload;
  `putBackTrashedData` does not check whether a profile claimed the
  original path meanwhile (undo order makes that unreachable today);
  the equal-date row order has no test; no "move its data to the Trash"
  option in the delete alert (SwiftUI alerts take no checkbox; deleting
  then trashing covers it).

---

## Testing without a Mac

The model layer compiles on Linux with Swift 6.3 (swiftly) when
`ClaudeProcess.swift` is replaced by its protocols plus a stub
`RealClaudeLauncher`, and SwiftUI's `move(fromOffsets:toOffset:)` is
supplied for arrays. Linux XCTest cannot run synchronous `@MainActor`
test methods, so the harness rewrites them as `async` and `wait(for:)`
as `await fulfillment(of:)`. `ClaudeLauncherTests`, `SmokeTests`, and
all views need macOS; CI (`scripts/build.sh --clean` on `macos-15`)
covers them. Linux Foundation has no `FileManager.trashItem`: with #27
the harness replaces `FileTrash.system`'s body (tests inject their own
trash), and the `ProfilesMenuBridgeTests` from #23 need AppKit.

## Checks only a Mac can do

- B1 TCC attribution and `OpenConfiguration.environment`.
- #14 avatars and Color menu swatches, light and dark mode.
- #15 the label's `.task` keeps status current with the window closed;
  activation from the menu bar brings the instance forward (`NSApp.activate()`
  may not be granted synchronously before `yieldActivation(to:)`; if not,
  yield on the next run loop turn); the Dock icon reopens the window.
- #20 subtitle placement on macOS 14, 15, and 26.
- #22 Stop quits like ⌘Q (no crash report, state kept); whether
  `NSRunningApplication.terminate()` triggers an Automation prompt.
- #23 with nothing selected, Profiles → Delete, Stop, and Restart are
  greyed; Return in a Settings field does not start a rename, Return on a
  row does, ⌘Return opens.
- #24 "Restart to update" inside an isolated profile: the quit-for-update
  banner appears and Default Claude shows as running.
- #25 a closed instance window comes back on Open; the Automation prompt
  and the first, lost reopen.
- #26 `SMAppService.mainApp.register()` with an ad-hoc signed build;
  after a login with the window closed at quit, marked profiles start.
- #27 restore a deleted, started profile from Unlisted Data: still
  signed in. Trash one and press ⌘Z.
