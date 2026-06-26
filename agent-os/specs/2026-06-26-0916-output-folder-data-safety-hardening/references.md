# References for Output Folder Data-Safety Hardening

The audit evidence behind the reframe, so future readers don't re-derive it. All paths under `RaptureMac/RaptureMac/` unless noted.

## Folder create/delete/move call sites (audit — all non-destructive)

| Op | Location | Behavior |
|---|---|---|
| `createDirectory` (create-if-absent) | `Writer/FileWriter.swift:11` (output folder), `:21` (attachment subfolder); `App/AppState.swift:86` (first-time folder); `Persistence/SettingsStore.swift:27` (default folder); `Persistence/AppSupportDirectory.swift:14` (app-support); `Persistence/OutputFolderMigrator.swift:219` (`ensureDirectory`) | `withIntermediateDirectories: true` — idempotent, never overwrites |
| `removeItem` | `Persistence/OutputFolderMigrator.swift` `place()` cross-volume (post-`verify()`); `removeIfEmpty` (empty-only); `Writer/FileWriter.swift:32` (failed-attachment cleanup) | only after verification, or via the empty-only guard |
| `moveItem` | `OutputFolderMigrator.swift` `place()` same-volume | per-item; collisions handled by `mergeItem` (no overwrite) |
| `copyItem` | `OutputFolderMigrator.swift` `place()` cross-volume; `FileWriter.swift:106,111` (attachments, `ifSourceExists`) | merge/disambiguate; no overwrite |

No `trashItem` / `replaceItem` anywhere.

## Relocate flow (already fail-safe before this work)

`SettingsGeneralView.pickFolder()/handleDrop()` → `AppState.setOutputFolder` (`App/AppState.swift:66`) → `captureGate.withLock` (`App/CaptureGate.swift`) → `Task.detached { OutputFolderMigrator().migrate(from:to:) }` → on success only: `settings.update { outputFolder }` + `OutputFolderSidecar.write`. On throw: `relocationStatus = .failed`, settings/sidecar **not** touched, source intact.

## Existing migrator test coverage (pre-work)

`RaptureMacTests/OutputFolderMigratorTests.swift` (9 cases): `testSameVolumeMovePreservesTreeIncludingDotfiles`, `testCopyVerifyDeleteMovesContentAndRemovesSource`, `testMergeKeepsDestinationMarkdownAndDisambiguatesNotes`, `testNoOpWhenSourceEqualsDestination`, `testRefusesNewNestedInsideOld`, `testRefusesOldNestedInsideNew`, `testFailureLeavesSourceIntact`, `testOutputFolderURLSurvivesCodableRoundTrip`, `testSidecarWritesResolvedPath`.

**Gap found (and now closed):** no test asserted the *active folder* (and sidecar) stays unchanged after a failed relocate — only the migrator-level source-intact case existed. Closed by `AppStateRelocationTests`.

## Incident evidence (filesystem, this session)

- `~/Documents/Rapture Notes/` birth = `2026-06-23 01:48:39`; bare (only `.txt`); earliest note mtime matches folder birth → recreated by `FileWriter` create-if-absent.
- `settings.json` + sidecar last modified `2026-06-22 11:19`, both pointing at `Rapture Notes` → no in-app folder change since (migrator rewrites settings on change), so the relocate was not involved.
- `RaptureTest-A/B` (manual test folders) gone.
- Recovery sources: repo copy `~/Repos/NoiseMeldOrg/agentic-os-mirror/projects/briefs/rapture-ecosystem/demo/rapture-notes-CLAUDE.md`; Time Machine local snapshot `com.apple.TimeMachine.2026-06-21-133746.local` (Data volume).

## Files changed by this spec

- New: `Persistence/FileSafety.swift`, `Persistence/OutputFolderScaffold.swift`.
- Changed: `Persistence/AppSupportDirectory.swift` (DEBUG isolation), `Persistence/OutputFolderMigrator.swift` (route through `FileSafety`), `Writer/FileWriter.swift` (route cleanup through `FileSafety`), `Models/Settings.swift` (`seedScaffold` + lenient decode), `Persistence/SettingsStore.swift` + `App/AppState.swift` (scaffold wire-in), `UI/SettingsGeneralView.swift` (toggle + debug banner), `RaptureMacApp.swift` (debug title).
- New tests: `FileSafetyTests`, `OutputFolderScaffoldTests`, `OutputFolderSafetyTests`, `AppStateRelocationTests`.
