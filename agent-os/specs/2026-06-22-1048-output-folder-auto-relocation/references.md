# References for Output Folder Auto-Relocation

## Anchor files (current behavior to change)

### Output-folder change sites
- **Location:** `RaptureMac/RaptureMac/UI/SettingsGeneralView.swift` — `pickFolder()` (line ~60)
  and `handleDrop(_:)` (line ~76).
- **Relevance:** The two places that set the folder today, both via
  `appState.settings.update { $0.outputFolder = url }`. These get routed through the new
  `setOutputFolder`.

### Default output folder
- **Location:** `RaptureMac/RaptureMac/Persistence/AppSupportDirectory.swift` —
  `defaultOutputFolder` (`~/Documents/Rapture Notes`) and `url()` (app-support dir).
- **Relevance:** `url()` is where the `output-folder.path` sidecar lives;
  `defaultOutputFolder` is the first-launch default that also needs to write the sidecar.

### File writer
- **Location:** `RaptureMac/RaptureMac/Writer/FileWriter.swift`.
- **Relevance:** Writes the `.txt` notes and per-note attachment subfolders into the output
  folder. **Key patterns to borrow:** `uniqueDestination(in:baseName:)`'s `<base>-<n>`
  disambiguation (reuse for collision handling in the migrator);
  `attachmentRetryDelay = 2` (the ~2s suspension that forces real quiescing, not just a flag).

## Pipeline / concurrency model

### Pipeline + consumer loop
- **Location:** `RaptureMac/RaptureMac/App/Pipeline.swift` — `beginCapture(with:)`, the
  `for await batch in stream { await self.batchProcessor?.process(batch:) }` consumer task.
- **Relevance:** Confirms batches are processed strictly serially on `@MainActor`; the only
  interleaving risk is the new async `setOutputFolder`. Informs the `CaptureGate` granularity
  (wrap the whole batch).

### BatchProcessor
- **Location:** `RaptureMac/RaptureMac/App/BatchProcessor.swift` — `process(batch:)`, the pure
  `policy(paused:wasPausedLastBatch:isFirstNonemptyBatchSeen:batchSize:)` helper, and the
  `guard let folder = settings.outputFolder` write site (line ~220).
- **Relevance:** Reuse the existing pause/defer path for `isRelocating`; wrap the per-batch loop
  in `captureGate.withLock`. `policy` is already unit-tested — extend it to honor relocation.

### State / settings persistence
- **Location:** `RaptureMac/RaptureMac/Persistence/SettingsStore.swift`,
  `RaptureMac/RaptureMac/Persistence/AtomicFile.swift`, `RaptureMac/RaptureMac/App/AppState.swift`.
- **Relevance:** `SettingsStore.update {}` persists `settings.json`;
  `ensureDefaultOutputFolder()` is where the first-launch sidecar write hooks in; `AtomicFile.write`
  (`.tmp` → atomic) is reused by the sidecar; `AppState` (`@Observable @MainActor`) holds the new
  `captureGate`, `isRelocating`, `relocationStatus`, and `setOutputFolder`.

## Test patterns to mirror

- **Location:** `RaptureMac/RaptureMacTests/FileWriterSanitizationTests.swift`,
  `RaptureMac/RaptureMacTests/BatchProcessorTests.swift`.
- **Relevance:** XCTest style; `@testable import Rapture` (module name is `Rapture`, not
  `RaptureMac`). `BatchProcessorTests` shows how the pure `policy` helper is tested in isolation —
  extend it for the relocation defer case.

## External design source

- **Location:** `~/.claude/plans/dreamy-dazzling-newell.md` (approved plan).
- **Relevance:** Full implementation design this spec is derived from.
