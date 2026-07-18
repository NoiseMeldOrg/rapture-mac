# Milestone 1 — The Backup-Health Watchdog — Build Log

> Built 2026-07-17. Single milestone, complete. Durable design: `_build_plan/vault-backup/prd.md`.

## What's new in the app

**Rapture now tells you when your notes folder's backup has fallen behind.** If that folder lives inside a git repository, Rapture watches whether it's actually being backed up — and if uncommitted or unpushed work has sat for more than a day, it can raise a loud menu-bar warning so a silently-dead backup can't strand a week of notes unnoticed again.

- **Settings → General** now shows a plain-language backup line whenever the notes folder is a git repo — "Backed up · last commit 2h ago", "Not backed up in 2 days — 27 uncommitted changes", or "Destination isn't a git repository — nothing to back up". It's always there, one glance away.
- A new **"Warn me when the notes folder isn't backed up"** toggle (off by default) escalates the at-risk case to an always-visible menu-bar warning.
- It **only reads local git state** — it never commits, pushes, fetches, or connects to anything. Whatever already backs up your vault (obsidian-git, a scheduled `git push`, hand-commits) keeps doing it; Rapture just verifies the result and shouts when it stops.
- Quiet when healthy, and inert (a calm status line, nothing in the menu bar) when the folder isn't a git repo. If the drive is unplugged, it reads "can't check — drive not connected," never a false "backup failed."

## What was built

New folder `RaptureMac/RaptureMac/VaultBackup/` (folder-sync project — no `.pbxproj` edits):

- **`BackupHealth.swift`** — the observable `BackupHealth` enum (`unknown` / `notARepo` / `cannotCheck` / `backedUp(lastCommit:pendingChanges:)` / `atRisk(since:uncommitted:unpushed:)`) published on `AppState`, plus `BackupHealthPresentation` — pure, deterministic presenters for the Settings line and the menu-bar warning. Separating presentation from the views (house "pure-helper" style) is what makes the toggle behavior and wording unit-testable with no SwiftUI host.
- **`GitStateReader.swift`** — the injectable seam: `GitRepoState` (raw read-only facts) + `protocol GitStateReading` (`@MainActor`, mirroring `LinkFetching`). `GitReadError` for failures.
- **`SystemGitStateReader.swift`** — the production reader, modeled on `AppleScriptSender`'s `Process` pattern: hardcoded `/usr/bin/git`, a tight explicit environment (`GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, minimal `PATH`), read-only subcommands only (`rev-parse @{u}`, `status --porcelain -z`, `rev-list --count`, `log --format=%ct`) plus a `stat` of dirty files. Front-guarded on XCTest so the hosted suite spawns no real `git`; the blocking work runs in `Task.detached` off the main actor.
- **`BackupHealthEvaluator.swift`** — pure logic: `discoverRepoRoot(from:hasGitEntry:)` (walks *up* from the output folder — the real vault nests the output folder inside the repo) and `evaluate(state:now:threshold:)` (the staleness decision).
- **`BackupHealthMonitor.swift`** — `@MainActor`, mirrors `DestinationMonitor`: a single low-frequency `Task` loop (300s) with an immediate first check, an internal `tick()` for deterministic tests. Reads the live output folder, reuses `DestinationGuard` for the volume-absent state (checked *before* discovery), discovers the repo root, reads state through the injected reader, evaluates, and publishes `AppState.backupHealth`.

Edits: `Settings.swift` (+`vaultBackupWarningsEnabled`, `decodeIfPresent ?? false`), `AppState.swift` (+`backupHealth`), `Pipeline.swift` (own/start/stop the monitor, injecting `SystemGitStateReader`; starts alongside `DestinationMonitor`, independent of FDA, never under XCTest via the existing `start()` guard), `MenuBarView.swift` (an additional caption in `statusBlock` — no new `MenuBarStatus.Kind`), `SettingsGeneralView.swift` (the always-shown status line + the toggle), and one `README.md` line.

## Decisions not pre-specified (and one confirmed with the user)

- **Staleness anchor — age the *actual work*, not the last-commit clock (confirmed with the user during planning).** Unpushed work ages from the oldest unpushed commit's date; uncommitted work ages from the oldest dirty file's mtime; "un-backed-up since" is the earliest of whichever applies, and it's at risk only past the threshold. This is the key anti-false-alarm choice: a fresh edit after an idle weekend reads as fresh (silent), while 3-day-stranded notes correctly age past threshold. The rejected alternative (anchor on last-commit time) would false-alarm for up to one backup interval after any 24h+ idle gap.
- **Grace threshold = 24h**, a fixed default (no UI knob this milestone), per PRD.
- **Check cadence = 300s** via a dedicated `BackupHealthMonitor` rather than piggybacking `DestinationMonitor`'s 2s tick (too hot for spawning `git`). Immediate first check so Settings is never blank.
- **The toggle gates the menu-bar warning only.** The Settings status line is shown whenever the folder is a git repo, independent of the toggle — proven directly in `BackupHealthPresentationTests` (same at-risk state ⇒ `settingsLine` non-nil regardless, while `menuWarning` is nil when disabled and non-nil when enabled).
- **`GitStateReading` is `@MainActor`** (mirroring `LinkFetching`), not `nonisolated` like `AppleScriptSending`. The XCTest front-guard reads the MainActor-isolated `isRunningXCTests`, so the seam must be MainActor; the reader hops to `Task.detached` for the subprocess so the main actor is never held. (Modeling the isolation on `AppleScriptSender` first produced a compile error — `AppleScriptSender` doesn't do the XCTest check — corrected before the green build.)
- **No-upstream degrade:** with no `@{u}`, the unpushed branch is skipped; a clean no-upstream repo reads as backed up (we don't cry wolf on what can't be measured), and old uncommitted work still warns.

## Verification

- **Full suite green:** `xcodebuild … -scheme RaptureMac -configuration Debug build test` → **`** TEST SUCCEEDED **`, 779 tests, 0 failures** (was 745; +34 across `BackupHealthEvaluatorTests`, `BackupHealthPresentationTests`, `BackupHealthMonitorTests`, `SystemGitStateReaderTests`, `GitStateReaderGuardTests`). Tests spawn **no real git** (reader front-guarded + injected fake) and make **no network call**.
- **No networking added / PRIVACY unchanged.** `grep -RlE "URLSession\.|URLRequest|NWConnection|NWListener" RaptureMac/RaptureMac/` still returns exactly **three files** — `Enrichment/URLSessionLinkFetcher.swift`, `TriageAI/AnthropicEngine.swift`, `TriageAI/AnthropicWire.swift`. The new `VaultBackup/` code touches no network API (verified: `grep -RnE "URLSession|URLRequest|NWConnection|NWListener|Network\." RaptureMac/RaptureMac/VaultBackup/` → none). The feature opens no socket; it reads local git refs via `Process`.

## Deviations from the PRD

None material. The PRD proposed the threshold and cadence as defaults ("revisit if noisy") and left the exact age-signal open between last-commit time and dirty-duration; the build takes the more-correct dirty-mtime + oldest-unpushed-commit anchor (user-confirmed), which is squarely within the PRD's stated intent ("so a normal same-session edit doesn't trigger a warning").
