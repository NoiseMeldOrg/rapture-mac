# Milestone 1 — Triage Engine Core

You are entering plan mode to plan and then build milestone 1 of the triage-engine feature.

## Context

- Read `@_build_plan/triage-engine/prd.md` for the locked scope, capture contract, data model, and milestone boundaries. This is milestone 1 — there are no prior milestone logs.
- Read the repo `@CLAUDE.md` and `@CONTRIBUTING.md` (architecture and code style) first. The repo and its `agent-os/specs/` folders are the technical truth; the PRD is the milestone wrapper.
- **Extend the existing pipeline — do not build a parallel system.** Key files to read before planning:
  - `RaptureMac/RaptureMac/App/Pipeline.swift` — startup wiring; note the `isRunningXCTests` guard on line 1 of `start()` (the XCTest bundle is hosted in the app; any new startup machinery needs the same gating)
  - `RaptureMac/RaptureMac/App/BatchProcessor.swift` and `App/RelayProcessor.swift` — the two capture processors; their post-write success sites, `CaptureGate.withLock` usage, and pause/relocation defer semantics are the patterns to follow
  - `RaptureMac/RaptureMac/App/CaptureGate.swift` — the single serialization point around the output folder; the triage engine is a third actor on that tree and must decide explicitly how it participates
  - `RaptureMac/RaptureMac/Writer/FileWriter.swift` and `Writer/RelayFiler.swift` — filename collision walk (`uniqueDestination`), body composition, attachment sibling-folder conventions to reuse
  - `RaptureMac/RaptureMac/Watcher/RelayWatcher.swift` — the house idiom for a folder watcher: poll + full snapshot + pure planner (`static func plan(entries:firstSeen:now:)`), fully unit-testable. **There is no FSEvents precedent anywhere in the app.** The user's stated preference is event-driven watching (FSEvents) with debounce and settle-detection; the poll-plus-pure-planner idiom is the tested alternative. Decide in plan mode — either is acceptable if sync-delivered and hand-dropped files are caught reliably and arrival-to-filed stays within a few seconds.
  - `RaptureMac/RaptureMac/Models/Settings.swift` + `Persistence/SettingsStore.swift`, `Models/PersistedState.swift` + `Persistence/StateStore.swift` — new fields must follow the lenient `decodeIfPresent ?? default` pattern
  - `RaptureMac/RaptureMac/Filter/RelayFiledLedger.swift` — the ledger shape (TTL + capacity + pure `nonisolated static` helpers) to clone for the triage ledger
  - `RaptureMac/RaptureMac/UI/SettingsGeneralView.swift` (`relaySection`) — precedent for adding a Settings section; `UI/MenuBarView.swift` + `UI/MenuBarStatus.swift` for status surfacing
  - `RaptureMac/RaptureMac/Persistence/OutputFolderScaffold.swift` — the seeded template `CLAUDE.md` and `processed//in-progress/` conventions predate built-in triage; decide how the scaffold coexists with (or is superseded by) the new subfolder layout
  - `RaptureMac/RaptureMac/Persistence/OutputFolderMigrator.swift` — note the `.md`-preserve-on-collision rule; relocation must keep working over the triaged tree
  - `RaptureMac/RaptureMac/Filter/MessageFilter.swift` (`looksLikeAppConfirmation` / `looksLikeNoteFilename`) — the `✓ Saved` reply will now reference `.md` filenames; verify echo suppression still matches
- Plan-mode questions to settle explicitly: (a) whether app-written iMessage captures short-circuit in-process or round-trip through the same on-disk `.txt` → triage path as sync arrivals — either way, sync-arrived and hand-dropped `.txt` must triage identically; (b) today-count semantics — a triaged capture was already counted at capture time and must not count twice.
- Tests: follow the injected-directory pattern from `RaptureMacTests/RelayProcessorTests.swift` (commit `98d3f6a`) — per-test temp dirs, never the live container. `RelayScanPlanTests` shows how to test a pure planner with zero I/O. The `tdd` and `swift-concurrency` skills apply.
- DEBUG builds use isolated containers and folders (`AppSupportDirectory`, `Rapture Notes (Debug)`) — keep that isolation intact for anything new.

## Your task

1. Plan the implementation for **only** milestone 1 as defined in the PRD (on-arrival triage, capture contract, deterministic classification, backlog catch-up, raw-mode escape hatch, menu bar/Settings surfacing). Do not plan or build anything from later milestones (no EventKit, no AI, no enrichment, no offline spool).
2. After the user confirms the plan, build only what is in milestone 1's scope.
3. Keep `README.md`/`PRIVACY.md` factually accurate about the new `.md` output where they currently describe raw `.txt` (minimal truth patch + CHANGELOG entry — the full story rewrite is milestone 5).
4. Verify your work against the "Done when" criteria for milestone 1 in the PRD, including a live end-to-end check and a full test-suite run.
5. When complete, write a `milestone-log.md` in this folder (`_build_plan/triage-engine/milestones/1-triage-engine-core/milestone-log.md`) summarizing:
   - What was built (files created/changed, new types, settings/state fields)
   - Decisions made during implementation that weren't pre-specified in the PRD (especially the watcher mechanism and the in-process vs on-disk path question)
   - Anything the next milestone will need to know
   - Any deviations from the PRD and why

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
