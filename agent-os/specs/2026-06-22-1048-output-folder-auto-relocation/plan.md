# Plan: Dropbox-style auto-relocation of the Output (Rapture Notes) folder

## Context

Today, changing the Output Folder only re-points where **new** captures are written. Existing
notes are stranded in the old folder and the user must move them by hand. Both entry points —
`pickFolder()` and `handleDrop(_:)` in `SettingsGeneralView.swift` — just do
`appState.settings.update { $0.outputFolder = url }` and nothing else.

Goal: make it behave like Dropbox. Picking a new folder silently moves the entire existing
notes tree to the new location, then switches the active folder. Success is silent; only
failures surface. This moves the user's only copy of their notes, so data-safety is the
governing constraint.

### Findings from tracing the code (these shape the plan)

1. **The app is NOT sandboxed** (`RaptureMac/RaptureMac/RaptureMac.entitlements`:
   `com.apple.security.app-sandbox = false`). The `Settings` model stores a **plain `URL?`**
   (`Models/Settings.swift`), serialized to `settings.json`. There are **no security-scoped
   bookmarks anywhere** in the codebase. So "persist the bookmark" (brief deliverable #3) is
   moot — persisting the plain URL (already works via `SettingsStore`) is sufficient. The
   "bookmark persists across relaunch" test becomes a "URL persists" test.
2. **The `output-folder.path` sidecar is documented as existing but is NOT implemented**
   (no code writes it). `CONTEXT.md` and `tech-stack.md` also falsely claim a "security-scoped
   bookmark." **Decision (confirmed with user): implement the sidecar from the new centralized
   setter and correct the docs.**
3. **Folder layout (confirmed with user): the picked folder IS the notes folder.** Move the
   *contents* of old directly into the picked folder (no `Rapture Notes/` subfolder appended) —
   matches today's semantics where the NSOpenPanel-picked folder is used directly.
4. **The whole capture pipeline is `@MainActor`.** The consumer loop in `Pipeline.beginCapture`
   processes batches strictly serially (`for await batch in stream { await batchProcessor.process(batch:) }`),
   so at most one `process()` is ever in flight. The only thing that can interleave with it (at
   an `await` suspension) is the new async `setOutputFolder`. A `FileWriter.write` can suspend up
   to ~2s on attachment retry (`FileWriter.attachmentRetryDelay`). So the `paused` flag alone
   can't guarantee quiescence — we need real mutual exclusion plus a stale-URL guard (a batch
   captures `folder = settings.outputFolder` at its top; if we switch mid-batch, that batch
   writes into the old path). Wrapping the **whole batch** in a shared lock solves both.

## Tasks

### Task 1: Save spec documentation

Create `agent-os/specs/2026-06-22-1048-output-folder-auto-relocation/` with `plan.md`,
`shape.md`, `standards.md`, `references.md`, and an empty `visuals/`.

### Task 2: `OutputFolderMigrator` (`RaptureMac/RaptureMac/Persistence/OutputFolderMigrator.swift`)

Pure, FileManager-injectable, fully unit-testable with temp dirs. No AppState dependency.

```swift
struct OutputFolderMigrator {
    enum Strategy { case auto, move, copyVerifyDelete }   // .auto picks by volume; others for tests
    let fileManager: FileManager
    func migrate(from old: URL, to new: URL, strategy: Strategy = .auto) throws
}
```

Behavior:
- **Normalize** both URLs (`.standardizedFileURL`, resolve symlinks) before any comparison.
- **Degenerate guards (checked first, before touching anything):**
  - `new == old` → no-op return.
  - `new` nested inside `old`, or `old` nested inside `new` (path-prefix check on standardized
    paths, component-aware) → throw (refuse; avoids recursive self-move).
  - source missing / not a directory → caller handles (just create `new` and switch; no move).
  - destination volume unmounted, or destination not writable → throw.
  - cross-volume only: compute source tree size, compare to destination volume free space
    (`.volumeAvailableCapacityForImportantUsageKey`); throw if insufficient.
- **Volume detection:** compare `URLResourceValues.volumeIdentifier` of old vs new (`.auto`).
- **Enumerate top-level contents of `old` including dotfiles** (`contentsOfDirectory(at:…, options: [])`
  — do NOT pass `.skipsHiddenFiles`). Move item-by-item so a partial failure is recoverable:
  - **No collision at dest:**
    - same volume (`.move`/`.auto`-same): `moveItem` (atomic per item).
    - cross volume (`.copyVerifyDelete`/`.auto`-cross): `copyItem` → **verify** (dest exists;
      file sizes match / directory recursively present) → only then `removeItem(source)`.
      Source is never deleted before its destination is verified.
  - **Collision at dest (merge, never clobber):**
    - `CLAUDE.md` and top-level routing `.md` files → keep the existing destination file, skip
      the source, log.
    - directories (`processed/`, `in-progress/`, `code-tasks/`, attachment folders) → recurse and
      merge with the same rules; never overwrite an existing file.
    - notes (`.txt`) and any other file → never overwrite; disambiguate with a numeric suffix
      (reuse the `<base>-<n>` pattern already in `FileWriter.uniqueDestination`) and log.
- **Recoverability:** on any throw, stop and propagate. Cross-volume: the failing item's source
  is still present (delete-after-verify), already-migrated items are copies in dest → no data
  lost. Same-volume: moved items now live in dest, remainder still in source → no data lost.
  Caller does **not** switch the active folder on failure, so capture keeps using `old`.

### Task 3: `CaptureGate` (`RaptureMac/RaptureMac/App/CaptureGate.swift`)

A minimal `@MainActor` async mutex (single permit, `CheckedContinuation` waiter queue) exposing
`withLock { … }`. Shared via `AppState` (`let captureGate = CaptureGate()`).

- `BatchProcessor.process(batch:)` wraps its **entire** per-batch loop in
  `await appState.captureGate.withLock { … }` (granularity = whole batch, so the captured
  `folder` URL can't go stale mid-move).
- Add a transient (non-persisted) `var isRelocating = false` to `AppState`. In
  `BatchProcessor.policy`, treat `paused || appState.isRelocating` as paused so new batches
  **defer** (watermark not advanced → they replay into the *new* folder after relocation).
  This reuses the existing, well-tested pause/defer path; it does **not** touch the user's
  persisted `paused` setting or the menu-bar "⏸ Paused" state.

### Task 4: `AppState.setOutputFolder(_ new: URL) async` (centralized setter)

Single path all callers use:
```
normalize new; old = settings.outputFolder
if new == old { return }                         // no-op
isRelocating = true; relocationStatus = .inProgress
await captureGate.withLock {                      // waits for any in-flight batch; blocks new writes
    do {
        if let old, dir exists at old { try migrator.migrate(from: old, to: new) }
        else { try create new }
        settings.update { $0.outputFolder = new } // persists settings.json
        OutputFolderSidecar.write(new)            // writes output-folder.path
        relocationStatus = .idle
    } catch {
        relocationStatus = .failed(message)
        recordError("Couldn't move notes: \(message)")   // do NOT switch folder
    }
}
isRelocating = false
```
Add transient `var relocationStatus: RelocationStatus` (`idle` / `inProgress` / `failed(String)`)
to `AppState` for non-blocking UI.

### Task 5: `OutputFolderSidecar` (`RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift`)

`static func write(_ url: URL)` → atomically write the resolved absolute path to
`AppSupportDirectory.url()/output-folder.path` via `AtomicFile.write`. Call it from
`AppState.setOutputFolder` (every change) **and** from `SettingsStore.ensureDefaultOutputFolder`
(first-launch default), per the roadmap's planned item.

### Task 6: Wire up `SettingsGeneralView.swift`

- `pickFolder()` and `handleDrop(_:)`: replace `appState.settings.update { $0.outputFolder = url }`
  with `Task { await appState.setOutputFolder(url) }`.
- In `outputFolderSection`, show non-blocking status from `appState.relocationStatus`: a small
  `ProgressView` + "Moving notes…" while `.inProgress`; red caption on `.failed`. No confirmation
  dialog, no manual step on the happy path.

### Task 7: Tests + docs

`OutputFolderMigratorTests` (module imports as `@testable import Rapture`), all using temp dirs
and the `Strategy` hook to force the cross-volume path on one volume:
- **same-volume rename** — files + subdirs + a dotfile move to dest, source emptied, tree preserved.
- **cross-volume copy+verify+delete** (`strategy: .copyVerifyDelete`) — dest has all files with
  matching content, source removed.
- **merge with collisions** — dest pre-seeded with a different `CLAUDE.md` (kept), a colliding
  `note.txt` (disambiguated, both survive), and an overlapping `processed/` dir (merged).
- **no-op when unchanged** — `new == old` returns, touches nothing.
- **nested-path guards** — old-inside-new and new-inside-old both throw; nothing moved.
- **failure leaves source intact** — read-only dest (chmod) throws; every source file still present.
- **URL + sidecar persist across simulated relaunch** — set folder, reload `SettingsStore` from
  disk → `outputFolder` matches; `output-folder.path` contains the resolved path.

Docs:
- **CHANGELOG.md** `[Unreleased]`: new **Added** entry for auto-relocation; note the sidecar is
  now implemented; bump the test count line.
- **CONTEXT.md** line ~26: drop "Stored as a security-scoped bookmark"; state it's a plain
  absolute-path URL in `settings.json` (app is not sandboxed). The sidecar sentence becomes true.
- **tech-stack.md**: correct the "security-scoped bookmark data" claims (Persistence + Permissions
  table) to plain-URL; mark the `output-folder.path` sidecar as implemented.

### Task 8: Build + run tests

`xcodebuild test -scheme RaptureMac` — all existing tests (~205) + new tests pass.

## Files

| File | Change |
|---|---|
| `RaptureMac/RaptureMac/Persistence/OutputFolderMigrator.swift` | **new** — move/copy/merge engine |
| `RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift` | **new** — `output-folder.path` writer |
| `RaptureMac/RaptureMac/App/CaptureGate.swift` | **new** — MainActor async mutex |
| `RaptureMac/RaptureMac/App/AppState.swift` | add `captureGate`, `isRelocating`, `relocationStatus`, `setOutputFolder(_:)` |
| `RaptureMac/RaptureMac/App/BatchProcessor.swift` | wrap batch in `captureGate.withLock`; honor `isRelocating` in `policy` |
| `RaptureMac/RaptureMac/Persistence/SettingsStore.swift` | call `OutputFolderSidecar.write` in `ensureDefaultOutputFolder` |
| `RaptureMac/RaptureMac/UI/SettingsGeneralView.swift` | route both callers through `setOutputFolder`; add status UI |
| `RaptureMac/RaptureMacTests/OutputFolderMigratorTests.swift` | **new** — see Task 7 |
| `CHANGELOG.md`, `CONTEXT.md`, `agent-os/product/tech-stack.md` | doc fixes |

Note: new `.swift` files land in the Xcode folder-synced groups (folder-sync project), so they're
picked up automatically.

## Verification (end-to-end)

1. `xcodebuild test -scheme RaptureMac` — all existing + new tests pass.
2. Manual: with notes in `~/Documents/Rapture Notes/`, Settings → General → Change… to an empty
   folder on the same volume → notes appear there instantly, old folder emptied, capture continues.
3. Manual cross-volume: Change… to a folder on an external `/Volumes/...` disk → notes copied,
   then source removed; eject mid-pick to confirm a clean error and that the active folder stays put.
4. Confirm `~/Library/Application Support/Rapture for Mac/output-folder.path` updates on each change.
5. Dictate a note via Siri immediately after a change → it lands in the new folder.
