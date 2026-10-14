# AGENTS.md

## Tooling

Requires Xcode (developed with Xcode 26.6 / Swift 6.3.3; `.swift-version`
pins it). Deployment target is macOS 14+. The project is a plain
`claude-many.xcodeproj` — no XcodeGen or SwiftPM manifest to regenerate.

- `scripts/build.sh [--clean] [--run] [--install]` runs the unit tests,
  builds a universal Release app into `build/Claude Replicant.app` and ad-hoc
  signs it. `--install` replaces `/Applications/Claude Replicant.app`.
- `scripts/release.sh X.Y.Z [--push]` bumps `MARKETING_VERSION` and
  `CURRENT_PROJECT_VERSION` in `project.pbxproj` and the README version
  marker, verifies, commits, and tags.
- `xcodebuild -project claude-many.xcodeproj -scheme claude-many
  -destination 'platform=macOS' test` runs the tests directly.
- The live smoke test (`claude-manyTests/SmokeTests.swift`) launches real
  Claude Desktop instances and runs only when `/tmp/claude-many-smoke-run`
  exists or `CLAUDE_MANY_SMOKE=1`. Never enable it casually — real app
  windows appear on screen.

## Architecture

- Branding: Claude Replicant, executable `claude-replicant`, bundle
  identifier `ch.lkmc.ClaudeReplicant`. The project, scheme, Swift module,
  and `Claude-Many` storage paths retain their legacy `claude-many` names
  to preserve upgrades and hosted tests.
- Icon master: `media-sources/app-icon.png`; regenerate the committed Xcode
  icon sizes with `python3 scripts/generate-icons.py` (requires Pillow).
- Mechanism: launch `/Applications/Claude.app/Contents/MacOS/Claude` with
  `--user-data-dir=<profile>`. Packaged Claude ignores `CLAUDE_USER_DATA_DIR`.
  `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR` point to the
  profile's `.claude/`; discovery matches argv, never the legacy environment.
  Default Claude launches without directory/config overrides and is a built-in,
  non-persisted entry. Discovery rejects legacy environment hints and processes
  owned by other users; standard and isolated instances are tracked separately.
  Evidence, callback/pairing limits, and upgrade behavior are in README.md
  ("How it works"). Keep them accurate when the mechanism changes.
- ChatGPT mechanism: launch `/Applications/ChatGPT.app/Contents/MacOS/ChatGPT`
  (bundle `com.openai.codex` only) with `CODEX_ELECTRON_USER_DATA_PATH` and
  `--user-data-dir` both set to the profile, and `CODEX_HOME` to its
  `.codex/`. Packaged ChatGPT overrides the switch with the variable; discovery
  adopts an instance only when both agree. ChatGPT Classic (`com.openai.chat`)
  cannot isolate logins and is refused. Default ChatGPT is listed only while
  ChatGPT profiles exist.
- `ManagedApp` holds per-app facts. Types keep their `Claude` prefixes from
  before ChatGPT support; they serve both apps.
- `claude-many/Models/` owns the testable core: `ProfileStore`
  (persistence), `ProfileManager` (start/stop, injected launcher),
  `ClaudeProcess`, `ClaudeProfile`. `claude-many/Views/` is SwiftUI only.
- The profile list lives in `~/Library/Application
  Support/Claude-Many/profiles.json`, per-profile data dirs under
  `.../Profiles/<slug>/`. Never create, copy, or delete normal app data in
  `~/Library/Application Support/Claude`, `~/Library/Application
  Support/Codex`, or `~/.codex`. Only each app manages those when the user
  launches its Default entry.

## Releases

Release tags are annotated `vX.Y.Z` tags on `main`. GitHub Actions verifies
the tag against `MARKETING_VERSION` in `project.pbxproj`, requires the
tagged commit to be on `main`, rebuilds the app, produces ZIP and DMG
assets with SHA-256 checksums, verifies the uploaded bytes, and leaves the
release as a draft.

Builds are ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`). Do not describe them
as notarized or Developer ID signed.

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->
