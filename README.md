# Claude Replicant

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

*Give Claude the Double Impact.*

<img src="media-sources/app-icon.png" alt="Claude Replicant icon with paired JCVD portraits" width="160" align="right">

**Latest release:** v<!-- version -->1.0.0<!-- /version --> · [Download](https://github.com/L-K-M/claude-many/releases/latest)

Run multiple Claude Desktop or ChatGPT instances side by side on one Mac,
each logged into a different account. There is no fixed limit — you add one
profile per login you have.

A tiny native macOS app (Swift/SwiftUI) that manages one private data
directory per profile and launches Claude Desktop or ChatGPT pointed at it.

## Install

Download the DMG or ZIP from the latest release and move
`Claude Replicant.app` to `/Applications`. The app is ad-hoc signed, not
notarized, so macOS blocks its first launch:

- **macOS 15 Sequoia and later:** open the app once and dismiss the warning,
  then open **System Settings → Privacy & Security**, click **Open Anyway**
  next to the Claude Replicant message, and confirm. Control-clicking and
  choosing Open no longer bypasses this check.
- **macOS 14 Sonoma:** Control-click the app in Finder, choose **Open**, and
  confirm.

## What it is

- **Default Claude** is always first in the list. It uses your existing
  normal Desktop login and Code settings, without directory overrides.
  Start/Stop and live status work for it too, including when you open Claude
  from the Dock. This built-in entry cannot be renamed or deleted.
- **ChatGPT profiles** work the same way with the current ChatGPT app.
  **Default ChatGPT** appears with your first ChatGPT profile and controls
  your normal ChatGPT login. ChatGPT Classic is not supported.
- **Profile manager** — add, rename, remove, start, and stop profiles. Each
  profile has a label, a Start/Stop control, and a running indicator.
- **Unlimited profiles** — as many as you have accounts. Profiles and their
  data directories persist across app restarts.
- **Isolated logins** — every profile owns a private data directory under
  `~/Library/Application Support/Claude-Many/Profiles/<slug>/`. That
  directory holds that instance's login tokens, cookies, config, and
  sessions, so each instance logs in and stays logged in independently.
- **Separate Code configuration** — each profile uses its own `.claude/`
  directory for Claude Code settings, history, plugins, and credentials.
  ChatGPT profiles use their own `.codex/` for Codex settings and login.
- **Native look** — SwiftUI, macOS 14+, universal binary. Ad-hoc signed, no
  developer account required.

## How it works

Claude Desktop (`/Applications/Claude.app`) is an Electron app. For isolated
profiles, Claude Replicant spawns `/Applications/Claude.app/Contents/MacOS/Claude` directly with
`--user-data-dir=<profile directory>` to select independent Desktop storage.
It also sets `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` to
`<profile directory>/.claude`, keeping Code configuration and its credential
namespace separate. Process discovery reads the directory from argv, so
restarting Claude Replicant can adopt instances it previously launched.

**Default Claude** runs the same executable with no `--user-data-dir`
argument. Inherited `CLAUDE_USER_DATA_DIR`, `CLAUDE_CONFIG_DIR`, and
`CLAUDE_SECURESTORAGE_CONFIG_DIR` overrides are removed for this launch.
Claude chooses its normal locations, just as when opened normally. The
manager does not create, copy, or delete files in the normal Claude data
directory, and the built-in entry is not saved in `profiles.json`.

While the list is open, running status is refreshed every two seconds.
Starting an entry checks again for an existing process before launching.
Process discovery is limited to your user account. Ambiguous legacy
environment-override launches are excluded rather than treated as default.

Current packaged Claude builds discard `CLAUDE_USER_DATA_DIR`; the launcher
removes that legacy variable even when inherited. This startup policy was
inspected in Claude Desktop **2.31226.1** from the official
[Mac release feed](https://downloads.claude.ai/releases/darwin/universal/RELEASES.json).
`--user-data-dir` is an Electron/Chromium switch, not a documented Claude
Desktop profile API. Updates can change its behavior. The live smoke test
checks the installed app; it does not verify signing in or running Code tasks.

Stopping a profile sends SIGTERM to its process (with a SIGKILL fallback
after 5 seconds), terminating only that instance — other profiles and
any separately launched Claude Desktop instances are unaffected.

### ChatGPT

The current ChatGPT app (`/Applications/ChatGPT.app`, bundle identifier
`com.openai.codex`) is also an Electron app. For isolated profiles, Claude
Replicant runs `Contents/MacOS/ChatGPT` with
`CODEX_ELECTRON_USER_DATA_PATH` and `--user-data-dir=` both set to the
profile directory, and `CODEX_HOME` set to `<profile directory>/.codex`.
Packaged ChatGPT replaces the switch with the variable and keeps
`CODEX_HOME` only alongside it. The switch is repeated for discovery, which
adopts an instance only when argv and the variable agree. ChatGPT allows
one instance per profile directory.

**Default ChatGPT** runs without these variables, which are removed even
when inherited. It is listed only while ChatGPT profiles exist, so Start All
never opens ChatGPT just because it is installed.

**ChatGPT Classic** (`com.openai.chat`, the native app that the current
ChatGPT renames to `ChatGPT Classic.app`) is not supported. Every copy reads
the same keychain login and it has no storage override, so its instances
would share one account. Claude Replicant refuses to start ChatGPT profiles
when Settings points at it.

These variables were inspected in ChatGPT **26.1007.71326**, whose own code
starts a second demo instance the same way. They are internal, not a
documented API, and updates can change them. The gated ChatGPT smoke test
checks the installed app; it does not verify signing in.

## Build

Requires Xcode (developed with Xcode 26.6 / Swift 6.3.3 on macOS 26;
deployment target is macOS 14+). The app is **ad-hoc signed** — no
developer account, no notarization.

```sh
scripts/build.sh            # runs tests, then builds build/Claude Replicant.app
scripts/build.sh --install  # also installs to /Applications
```

Or open `claude-many.xcodeproj` in Xcode and run the `claude-many` scheme.
The executable is `claude-replicant`. The project, scheme, and Swift module
keep their legacy `claude-many` names so hosted tests and upgrades continue
to work. The bundle identifier is `ch.lkmc.ClaudeReplicant`.

The icon master is `media-sources/app-icon.png`. To regenerate the Xcode icon
sizes, run `python3 scripts/generate-icons.py` with Pillow installed.

## Usage

1. Quit other instances of the same app before signing in to a new
   profile. Browser sign-in and connector callbacks can otherwise reach the
   wrong instance.
2. Launch Claude Replicant and press **⌘N** for a Claude profile or **⌥⌘N**
   for a ChatGPT profile (File menu, or the toolbar **+**), then type a name
   such as "Work" and press Return.
3. Click **Start**, sign into that account, then **Stop** it before setting
   up another profile. Check which account your browser is signed into.
4. Once each profile is signed in, start them together to work side by side —
   the **Profiles → Start All** menu item launches every profile at once.
   **Stop** quits that instance and preserves its login for next time.

Use **Default Claude** or **Default ChatGPT** for the account already signed
in through the normal app. Its controls operate on that normal instance, not
on an isolated profile.

When upgrading from the environment-variable launcher, quit existing Claude
instances first. Desktop profile directories and logins are reused. Each
profile's Code configuration starts fresh; existing shared `~/.claude`
settings and history stay on disk and are not copied automatically.

The rename from claude-many keeps `~/Library/Application Support/Claude-Many`
in place. If you installed the old `claude-many.app`, quit it and remove that
app copy after installing `Claude Replicant.app`; keep the profile data.

The profile list works like Finder: click to select (⇧/⌘ for multiples),
double-click to open a profile, press **Return** to rename it inline, **⌘⌫**
to delete, and drag to reorder profiles below the pinned Default entry.
Right-click a row (or use the **Profiles** menu) for Open, Stop, Rename,
Delete, Reveal in Finder, and Copy Data Folder Path. Add, rename, delete,
and reorder are all undoable via **⌘Z**. The window title bar shows how many
instances are running, and quitting the window quits the app; running Claude
instances keep running and are adopted on the next launch.

Deleting a profile only removes it from the list — the data directory stays
on disk so nothing is lost (remove it manually if you truly want to delete
the account data). Settings (**⌘,**) shows the Claude.app and ChatGPT.app
locations with a **Choose…** picker if either is not installed in
`/Applications`; the chosen paths persist across launches.

## Tests

Tests cover the profile store and manager, launch environment, and argv
parsing. Recording subprocesses check the actual launch arguments and macOS
process discovery without opening Claude:

```sh
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test
```

For account-level verification, sign into two scratch profiles one at a time,
then run a Code session in each. Check each account in Desktop, confirm that
settings/history remain separate, restart Claude Replicant while both are open,
and verify that Start does not duplicate them and Stop affects only its
profile. Repeat after a Claude update. This check requires real accounts and
is not run by CI.

A **live smoke test** (in `claude-manyTests/SmokeTests.swift`) launches two
real Claude instances against throwaway scratch directories under `/tmp`,
verifies two processes, two windows, and two independently populated data
directories, then stops both and verifies clean termination (a second variant
verifies leftover-instance reconciliation across an app relaunch). A ChatGPT
variant does the same with two ChatGPT profiles and is skipped unless the
current ChatGPT app is in `/Applications`. It is
gated so ordinary test runs never spawn real applications — either
`CLAUDE_MANY_SMOKE=1` or the flag file below opts in (xcodebuild does not
reliably pass env vars to hosted test processes, so the flag file is the
dependable route):

```sh
touch /tmp/claude-many-smoke-run   # opt in
xcodebuild -project claude-many.xcodeproj -scheme claude-many \
  -destination 'platform=macOS' test
```

## Developing

Standard branch → pull request flow on `main`; CI runs the unit tests and a
universal Release build on every push. `scripts/release.sh X.Y.Z --push`
cuts a tagged release that GitHub Actions turns into ZIP and DMG assets on
a draft GitHub release. The gated live smoke test is described under
[Tests](#tests).

## Behavior notes

- **Auto-updates apply to every profile.** The Claude.app bundle is shared;
  an update replaces the binary all profiles launch. Profile data is
  retained, but an updater relaunch may drop profile arguments. Quit profile
  instances before updating and reopen them through Claude Replicant
  afterwards.
- **Managed local storage is per profile**, under
  `~/Library/Application Support/Claude-Many/Profiles/<slug>/`, with Code
  configuration in `.claude/`. Claude Replicant does not copy or modify your
  default Desktop or Code profile. Claude's cloud data remains account-bound.
  Removing a profile directory manually also removes its Code configuration.
- **Default Claude keeps its existing normal storage.** Claude itself may
  write there as usual when launched from the built-in entry. The manager
  does not migrate or edit that data and does not offer Delete for this entry.
- **Local device pairing is disabled for relocated Desktop data directories**
  in Claude Desktop 2.31226.1. Other shared app services, such as Dock
  identity, sign-in callbacks, and logs, are not isolated by this launcher.
- **ChatGPT profiles share some services.** Sign-in returns through local
  ports 1455 and 1457, so finish one ChatGPT sign-in before starting
  another. Connector (MCP) sign-ins may use one keychain entry for all
  profiles. `codex://` links open in whichever instance macOS picks.
- **No fixed limit** on the number of profiles beyond disk space and memory.
- **Restarting the app adopts matching live profiles.** If Claude Replicant is
  quit while instances are still running, the next launch detects each
  profile's live instance (by its data directory), shows it as running, and
  refuses to start a second one into that data directory until the first has
  actually exited. Starting a profile right after stopping it is likewise
  refused until the previous instance has fully shut down.
  Discovery is best-effort when macOS cannot read a process snapshot.
- Claude Desktop's own settings (theme, etc.) are per profile too, since
  they are part of the userData directory.

## License

MIT — see [LICENSE](LICENSE).
