# Milestone 2 — Destination Resilience

You are entering plan mode to plan and then build milestone 2 of the triage-engine feature.

## Context

- Read `@_build_plan/triage-engine/prd.md` for the locked scope and this milestone's boundaries.
- Read `@_build_plan/triage-engine/milestones/1-triage-engine-core/milestone-log.md` to understand what milestone 1 built (the triage engine you are hardening).
- Read the repo `@CLAUDE.md` and `@CONTRIBUTING.md`. Key files to read before planning:
  - `RaptureMac/RaptureMac/App/AppState.swift` (`setOutputFolder`, line ~75) — the single entry point for destination changes, and how it quiesces the pipeline via `CaptureGate` during relocation
  - `RaptureMac/RaptureMac/Persistence/OutputFolderMigrator.swift` — same-volume vs cross-volume handling, merge-never-clobber, verification; the closest existing code to "reason about volumes"
  - `RaptureMac/RaptureMac/Persistence/SettingsStore.swift` (`ensureDefaultOutputFolder`) — **this auto-creates the folder when missing; that behavior is exactly wrong for an unplugged external volume.** The core of this milestone is distinguishing "volume absent" (queue, don't create) from "folder missing on a mounted volume" (create as today). Never write a shadow folder under `/Volumes/<name>` on the boot volume.
  - `RaptureMac/RaptureMac/App/Pipeline.swift` — the FDA retry-polling pattern (`fdaRetryInterval`) is the house idiom for "poll until a precondition appears" (here: destination availability)
  - `RaptureMac/RaptureMac/Persistence/AppSupportDirectory.swift` — the app's support container is the natural home for the spool; keep the DEBUG-isolation idiom
  - `RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift` — the public path contract; decide what the sidecar should say while the destination is offline
  - `RaptureMac/RaptureMac/Writer/FileWriter.swift` + `App/BatchProcessor.swift` and `App/RelayProcessor.swift` — where writes currently fail when the destination is unavailable; all capture sources must spool instead of erroring or stalling. Note the relay's own defer-and-reappear semantics (files stay in the relay folder) — decide deliberately whether relay items spool or simply stay deferred in the relay folder until the destination returns.
- The user's personal target config after this milestone: destination = an Obsidian vault at `/Volumes/Dock SSD/Obsidian/Second Brain` (external SSD that is sometimes unmounted). That is the reference test case.
- Tests: injected-directory pattern throughout (`RelayProcessorTests` precedent). Volume-absence is simulatable with paths under a nonexistent `/Volumes/...` prefix — plan how to make the availability check injectable so tests don't need real drives.
- Skills that apply: `tdd`, `swift-concurrency`, `diagnose` (if filesystem behavior surprises).

## Your task

1. Plan the implementation for **only** milestone 2 as defined in the PRD (external-volume destinations, volume-absent vs folder-missing distinction, internal spool with ordered flush, offline status UI, relocation compatibility). Do not plan or build anything from later milestones.
2. After the user confirms the plan, build only what is in milestone 2's scope.
3. Verify against the PRD's "Done when" for milestone 2 — including a live unplug/replug (or simulated-unmount) end-to-end check showing queue → accurate count → ordered flush → correctly triaged notes, and nothing written to the boot volume while absent. Run the full test suite.
4. When complete, write a `milestone-log.md` in this folder (`_build_plan/triage-engine/milestones/2-destination-resilience/milestone-log.md`) summarizing what was built, decisions not pre-specified in the PRD (spool location/format, relay spool-vs-defer choice, sidecar behavior while offline), anything milestone 3 needs to know, and any deviations.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
