# Remove the autonomous watcher; keep the SessionStart hook

> Shaped 2026-06-04 via `/accountability-panel` then `/agent-os:shape-spec`.
> Companion: `shape.md` (decisions + panel critique), `references.md` (related artifacts), `standards.md` (N/A).

## Context

Rapture for Mac currently ships two ways to consume the notes folder via Claude Code:

1. **SessionStart hook** (`Scripts/install-claude-hook.sh`) — when Claude Code opens, a small script reports the count of pending `.txt` files and Claude offers to triage per `~/Documents/Rapture Notes/CLAUDE.md`. On-demand. Inherits TCC from the user's terminal. In production.
2. **launchd autonomous watcher** (`Scripts/install-claude-watch.sh`) — installs a `~/Library/LaunchAgents/com.user.rapture-notes-watch.plist` agent that runs `~/.claude/scripts/rapture-notes-watch.sh`. Uses `fswatch` to fire `claude -p` against each new note. Always-on background processing. Surfaced as the second `installs[]` entry on the Claude Code card in the v1.0.64 Integrations panel.

**What prompted this.** On 2026-06-04 we discovered the watcher had been silently broken for two days — a `claude -p` invocation hung, the script's for-loop blocked, fswatch events piled up un-drained, three orphan bash processes were racing on the same stream. After kickstart-restarting we immediately hit `EPERM: operation not permitted, lstat '/Volumes/Dock SSD/Source/Repos/simonc602/agentic-os'` — launchd's process context can't `lstat` the external volume where `agentic-os` (the watcher's `WORKDIR`) lives. Fixing would mean granting Full Disk Access to `/bin/bash` and `/opt/homebrew/bin/claude` plus adding a `timeout` wrapper to prevent the next hang.

**Decision.** Remove the launchd layer entirely. The SessionStart hook covers the same need with the right shape of tool (interactive Claude Code, inherited TCC, on-demand processing). See `shape.md` for the accountability-panel rationale.

**Intended outcome.** Less surface area, fewer failure modes, no TCC dance for launchd contexts, no orphan-process risk, no claude-`-p`-hang risk, no ongoing maintenance tax. Cost: notes are only processed when Claude Code is opened, not on arrival.

## Scope

- **Watcher-only removal.** Integrations panel UI stays. Claude Code card stays — it collapses from a two-install card (hook + watcher) into a one-install card (hook only). OpenClaw / Hermes / Generic CLI cards untouched.
- **Live uninstall runs as part of this work** (not deferred).
- **Standards:** N/A — matching the precedent in `2026-05-16-1854-rapture-mac-v1-local-capture`.
- **Visuals:** none.

## Task 1: Save spec documentation

Already complete (this folder).

## Task 2: Live uninstall

Run `Scripts/uninstall-claude-watch.sh`. Verify:
- `launchctl list | grep rapture-notes-watch` is empty
- `~/Library/LaunchAgents/com.user.rapture-notes-watch.plist` is gone
- `~/.claude/scripts/rapture-notes-watch.sh` is gone
- `pgrep -fl rapture-notes-watch.sh` is empty
- `pgrep -fl 'fswatch.*Rapture Notes'` is empty

Do this before Task 4 (deleting the uninstaller) so the script exists when needed.

## Task 3: Trim `examples/claude-code/manifest.json`

- Remove the entire `claude-watch` entry from `installs[]` (lines 22-62).
- Remove the `"Autonomous mode"` entry from `docs[]` (line 6).
- Update the top-level `description` to drop the autonomous-half.

## Task 4: Delete watcher-only repo files

- `Scripts/install-claude-watch.sh`
- `Scripts/uninstall-claude-watch.sh`
- `Scripts/start-watch.sh`
- `Scripts/stop-watch.sh`
- `Scripts/restart-watch.sh`
- `examples/claude-code/autonomous.md`
- `examples/watch.env.example`

Trim `Scripts/status.sh` to drop watcher references.

## Task 5: Trim Swift integration sources

Read each before deciding delete-vs-trim:

- `RaptureMac/Integrations/WatcherConfigStore.swift` — watcher-specific env-file editor. Likely deletes whole.
- `RaptureMac/Integrations/IntegrationRunner.swift` — drop start/stop/restart paths; install/uninstall stay (hook uses them).
- `RaptureMac/Integrations/Prerequisites.swift` — drop watcher-specific prereqs (`fswatch`, Reminders TCC); keep `claude` / `jq`.
- `RaptureMac/Integrations/StatusParser.swift` — drop `watcher`-keyed branches; keep `hook` parsing.
- `RaptureMac/Integrations/IntegrationsState.swift` — drop watcher state shape.
- `RaptureMac/Integrations/IntegrationDiscovery.swift` — verify it still surfaces cards correctly with a one-install manifest; no functional change expected.
- `RaptureMac/Integrations/BundledResources.swift` — verify the resource copy step still references only files that exist.
- `RaptureMac/UI/SettingsIntegrationsView.swift` — remove watcher controls from the Claude Code card.

## Task 6: Update routing rules + top-level docs

- `examples/claude-code/CLAUDE.md`:
  - Change the `✓ Saved` reference in the "Don't" section to `✅ Saved` (matches the v1.0.65 reply-format change from earlier today).
  - Drop the "the worker runs media notes on a stronger model (see `install-claude-watch.sh`)" reference.
- `README.md` (top-level) — stop advertising the watcher.
- `examples/README.md` — stop advertising the watcher.

## Task 7: Trim tests

Per-file review:

- `RaptureMacTests/WatcherConfigStoreTests.swift` (25) — deletes whole.
- `RaptureMacTests/IntegrationDiscoveryTests.swift` (30) — keep card-discovery tests; delete watcher-specific cases.
- `RaptureMacTests/IntegrationRunnerTests.swift` (14) — keep install/uninstall; delete start/stop/restart.
- `RaptureMacTests/PrerequisitesTests.swift` (12) — keep `claude`/`jq`; delete `fswatch`/Reminders-TCC.
- `RaptureMacTests/StatusParserTests.swift` (24) — drop `watcher`-status cases.
- `RaptureMacTests/StatusPillResolutionTests.swift` (11) — drop `watcher`-pill cases.

Expect ~70-90 tests removed from the current 243. Final ~150-170.

## Task 8: Patch `CHANGELOG.md`

Add a `### Removed` block under `[Unreleased]` (which already contains today's dedup + reply-format fix). Cite:
- The silent-failure-for-2-days incident discovered today
- The TCC/EPERM friction
- The architectural mismatch (`claude -p` is the wrong shape for freeform routing; the hook gives the right shape already)

Leave the v1.0.64 historical entry intact.

## Task 9: Build, test, deploy

1. `xcodebuild -scheme RaptureMac -configuration Release build` → 0 errors.
2. `xcodebuild test -scheme RaptureMac -destination 'platform=macOS'` → all remaining pass.
3. Quit `/Applications/Rapture.app`, replace with new build, relaunch.
4. Open Settings → Integrations. Claude Code card has one install option, not two.
5. Single commit on `main`. Auto-versioner bumps the patch version.

## End-to-end verification

1. Capture a fresh Siri note. Rapture writes the `.txt` and sends `✅ Saved`. **No autonomous processing** (no `/tmp/rapture-notes-watch.*.log` activity).
2. Open a new Claude Code session. SessionStart hook reports the pending note count and Claude offers to triage per `~/Documents/Rapture Notes/CLAUDE.md`.
3. Triage runs interactively. No EPERM on `/Volumes/Dock SSD`. Note ends up in `processed/2026-06/`.
4. `launchctl list | grep rapture-notes-watch` empty; `pgrep -fl rapture-notes-watch.sh` empty.
