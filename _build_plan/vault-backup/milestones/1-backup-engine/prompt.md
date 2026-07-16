# Milestone 1 — The Backup Engine

You are entering plan mode to plan and then build milestone 1 of this feature.

## Context

- Read `@_build_plan/vault-backup/prd.md` for the full feature context, scope, data model, and the decisions the planning agent locked (including *why* this lives in Rapture rather than a helper app).
- This is milestone 1 — there is no prior milestone log to read.

### Repo truth (the PRD is the *what*; these are the *how*)

- **`@CLAUDE.md`** — repo conventions. Two are directly load-bearing here: (1) **tests run inside the app**, so `@main` startup runs during `xcodebuild test` — gate every side-effecting entry (spawning `git`, touching the network) behind `RuntimeEnvironment.isRunningXCTests`, the pattern `SystemEventKitClient`/`AnthropicEngine`/`URLSessionLinkFetcher` all use. (2) **Any new networking must update PRIVACY's grep claim in the same change** — a `git push` is networking even though it's a subprocess; milestone 2 owns the full docs pass, but do not *break* PRIVACY's claim in M1 (keep the `git` invocation confined to one file from the start so M2's grep update is a one-liner).
- **`@agent-os/product/mission.md`** and **`@agent-os/product/tech-stack.md`** — output neutrality and the enumerated-networking posture. This feature adds a fourth outbound path; it must be opt-in and confined.
- **`@agent-os/specs/2026-07-13-2230-triage-engine/`** — the durable spec for the AI/enrichment engines, which are the model for "a confined, opt-in, XCTest-guarded, injected-protocol subsystem." Mirror that shape.

### The exact files to read and mirror

- **`RaptureMac/RaptureMac/Reply/AppleScriptSender.swift`** — the app's existing `Foundation.Process` invocation: explicit executable, stdin/argv, **no login shell**, controlled environment. Your `git` runner is structurally the same. Copy its environment discipline (set an explicit `PATH`, exec `/usr/bin/git` directly) — this is exactly what the original brief demanded and what a login-shell approach gets wrong.
- **`RaptureMac/RaptureMac/Writer/DestinationGuard.swift`** — `classify` (pure, probe-injectable): `.available` / `.folderMissing` / `.volumeAbsent`. Gate the backup on `.available`. A path not under `/Volumes` is never `.volumeAbsent`, so internal drives are always "present" — this is what makes internal and external one code path.
- **`RaptureMac/RaptureMac/App/DestinationMonitor.swift`** — the 2s remount poll that flushes the offline spool. Your deferred-backup-runs-on-remount behavior hangs off the same signal; study how it re-checks conditions inside the gate before acting.
- **`RaptureMac/RaptureMac/UI/MenuBarView.swift`** — the status block and `secondaryLine` (today count · last time). The "last backup / last error" line is a sibling of what's already rendered. `MenuBarStatus.Kind` is a **closed enum**; a backup error is not a capture *status*, so surface it as an additional line (like the destination-offline caption at `MenuBarView.swift:48`), not a new `Kind`.
- **`RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`** — `outputFolderSection` and the inline `relocationStatusView` / `destinationOfflineStatusView` patterns. The setting and its status line live here, near the output folder, because this is destination safety.
- **`RaptureMac/RaptureMac/Models/Settings.swift`** — add `vaultBackupEnabled` (lenient `decodeIfPresent ?? false`, default false); follow the exact convention of `aiTriageEnabled` / `linkEnrichmentEnabled`.
- **`RaptureMac/RaptureMac/Models/PersistedState.swift`** — add `lastVaultBackupAt` and `lastVaultBackupError` at all the sites `triageIntroShown` touches (property, init default, assignment, `CodingKeys`, **lenient decode** — a strict key wipes every existing user's ledgers via `StateStore.load`'s fresh-state fallback).
- **`RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift`** — the resolved output-folder path; repo-root discovery walks up from the current output folder (read it live, don't cache — the folder can change).
- **`RaptureMac/RaptureMac/App/Pipeline.swift`** — where the subsystems are constructed and wired, and where capture-completion signals flow. The debounced-after-capture trigger keys off the same completion the reply/enrichment paths already observe; find that seam rather than inventing a new timer in isolation.
- **New code** goes in a new folder, e.g. `RaptureMac/RaptureMac/VaultBackup/`. Folder-sync project — **no pbxproj edits**.

### Design decisions already locked (do not re-litigate)

- **Opt-in, off by default.** When on but the destination isn't a git repo, the feature is inert and says so — not an error.
- **`git add -A`, never `-f`.** The vault's `.gitignore` was audited (2026-07-15) and correctly protects `Reference/Personal/Security/` and the SSN note. Plain `add -A` respects it; `-f` would leak secrets. This is a hard safety rule.
- **Commit only if staged; skip quietly when nothing changed.** No empty commits.
- **On non-fast-forward push rejection: rebase onto the remote, retry the push once.** Two committers (Obsidian, AI sessions, the user) means divergence is normal, and an unhandled rejection is a *silent failure* — the exact three-day disease this feature exists to cure. A conflict rebase can't resolve is surfaced as an error, **never force-pushed**.
- **In-flight guard**: never two backups concurrently; skip if one is running.
- **Trigger = debounced-after-capture + a daily floor.** Not a naive fixed interval.
- **Never fail silently.** Last-backup time and last error in the menu bar *and* Settings. This is the feature's whole justification for living in Rapture; it is not optional polish.
- **This install's remote is already SSH** (switched 2026-07-16, `git@github.com:NoiseMeld/second-brain.git`, push verified). Assume SSH works here; general HTTPS-remote handling and auth-failure UX are milestone 2 — but M1's error surfacing must not *crash or hang* on an auth failure, it must record it and move on.

### Verified facts — don't re-derive

- The app is **unsandboxed** (`RaptureMac.entitlements`) and already spawns `Process`; running `/usr/bin/git` needs no new entitlement.
- The vault (`/Volumes/Dock SSD/Obsidian/Second Brain`) is on an **external USB APFS volume**, and the output folder is `Rapture Inbox` *inside* it — so repo-root discovery genuinely must walk *up* past the output folder to the vault root. Do not assume output folder == repo root.
- `.git` is ~14 MB; commits/pushes are trivial in size.

## Your task

1. Plan the implementation for **only** milestone 1. Do not build milestone 2's auth-diagnosis UX or the documentation rewrite (but keep the `git` invocation confined to one file so M2's PRIVACY grep update is trivial).
2. After the user confirms the plan, build only milestone 1's scope.
3. Verify against the "Done when" criteria. Tests are **mandatory** and must run with **no real `git` and no network** (inject the git runner behind a protocol, like `EventKitClient`/`LinkFetcher`). Cover at minimum: repo-root discovery (found above the output folder; output folder *is* the root; no `.git` anywhere → inert), the nothing-to-commit skip, the in-flight guard, offline-defer-then-run-on-remount, and the rebase-retry-on-rejection path (with a fake runner simulating a non-fast-forward reject then success). Match the style in `RaptureMacTests` (see `AppStateRelocationTests`, `HandoffEnableFlowTests`, `FileSafetyTests`).
4. Do **not** let the setting's own UI copy lie — it must truthfully describe what M1 actually does, even though the full docs pass is M2.
5. When complete, write a `milestone-log.md` in this folder:
   - **Start with `## What's new in the app`** — a short, scannable, human-readable list of the user-facing changes, framed as capabilities.
   - Then, for M2's agent: what was built (files, the git-runner protocol seam, the trigger wiring), decisions made that weren't pre-specified, exactly how errors are recorded/surfaced (M2 builds the auth-failure UX on top), and any deviations from the PRD and why.

Ask clarifying questions with the AskUserQuestion tool to lock the plan.
