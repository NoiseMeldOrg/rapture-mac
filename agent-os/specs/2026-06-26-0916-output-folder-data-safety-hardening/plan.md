# Output Folder Data-Safety Hardening — Plan

> Spec folder (created by Task 1): `agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/`

## Context

**The trigger.** The user's notes folder (`~/Documents/Rapture Notes`) lost its entire scaffold — the routing `CLAUDE.md`, `processed/` history, and `in-progress/` — and came back **bare** with only new `.txt` captures (recreated 2026-06-23 01:48). It did **not** move; it was wiped in place. A triage agent flagged this as the destructive failure mode the relocate feature was meant to prevent.

**What the investigation actually found** (done this session, evidence-backed):

- **No production bug.** Every folder-mutating call site is non-destructive. All 14 `createDirectory` calls are create-if-absent (`withIntermediateDirectories: true`); every `removeItem` runs only post-verification (cross-volume `place()`) or on a **verified-empty** directory (`removeIfEmpty`). `setOutputFolder` already quiesces the writer via `CaptureGate`, migrates (same-volume atomic / cross-volume copy→verify→delete), and only **on success** switches the active folder + writes the sidecar. On failure the source is left intact and the folder is unchanged.
- **The migrator is already tested** for whole-tree+dotfiles, cross-volume copy-verify-delete, same-volume rename, `.md`-preserved-on-collision, and failure-leaves-source-intact.
- **Real root cause:** the **2026-06-22 manual test session** — debug and release builds share one `~/Library/Application Support/Rapture for Mac/` container (same `settings.json`/`state.json`/sidecar), which forced hand-editing the real settings and creating/deleting `RaptureTest-A/B`. Somewhere in that manual choreography the real folder was deleted. Then a captured Siri note hit `FileWriter.swift:11`, which recreated the folder bare (create-if-absent) and started fresh.
- **Data is recoverable:** the routing rules have a preserved copy in the repo (`agentic-os-mirror/.../demo/rapture-notes-CLAUDE.md`), and `processed/`/`in-progress/` are intact in the **2026-06-21 13:37 Time Machine local snapshot** (predates the loss).

**Intended outcome.** Reframe from "fix the data-eating bug" (there isn't one) to **lock the safety invariants and eliminate the actual root cause** so manual/debug testing can never again touch real user data — plus an **opt-in** scaffold so a fresh/bare folder can come back seeded instead of empty. Decisions confirmed with the user: scope = "lock invariants + fix root cause"; scaffold = **opt-in, off by default**.

## Out of scope

- Rewriting the migrator (already correct) or the relocate flow.
- Restoring the user's specific lost data — that's a separate recovery step (snapshot mount), not a code change.
- Automatic scaffold seeding (explicitly rejected in favor of opt-in).

---

## Task 1: Save spec documentation

Create `agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/` with:

- **plan.md** — this plan.
- **shape.md** — scope, the reconciliation (production safe; root cause = manual test session), the two confirmed decisions, and why the brief's premise was reframed.
- **standards.md** — full content of the applied standards (below).
- **references.md** — the audit's file:line evidence map (the create/delete/move call sites; `OutputFolderMigratorTests` case list) so future readers don't re-derive it.
- **visuals/** — `.gitkeep` (none).

## Task 2: DEBUG-build isolation (the root-cause fix)

Make debug builds physically unable to share state with — or default into — the real notes folder. In `RaptureMac/RaptureMac/Persistence/AppSupportDirectory.swift`:

- `folderName` → `#if DEBUG "Rapture for Mac (Debug)" #else "Rapture for Mac" #endif`. Gives debug builds their own `settings.json`, `state.json`, and `output-folder.path` sidecar.
- `defaultOutputFolder` → `#if DEBUG` use `~/Documents/Rapture Notes (Debug)`. A debug build that has never been configured defaults into a sandbox, not the real folder.

Result: relocation/migration can be exercised with the real installed app untouched; no more hand-editing or backup/restore of the production `settings.json`. Add a small DEBUG-only marker so it's always obvious which build is being driven — append `" (Debug)"` to the menu-bar/Settings window title (`RaptureMacApp.swift` / `SettingsGeneralView` header). Keeps the safeguard visible, not silent.

## Task 3: Invariant guards — make destructive folder ops impossible by construction

Centralize the one dangerous primitive so "delete the output folder" cannot exist outside a guarded path.

- Add `FileSafety.removeIfEmpty(_:fileManager:)` (new small file, or a static on the migrator) that lists `contentsOfDirectory` (dotfiles included) and **only** removes when empty; otherwise it logs and returns without touching anything. Add an `assertionFailure` in DEBUG if a non-empty removal was attempted, so a future regression trips in tests.
- Route `OutputFolderMigrator.removeIfEmpty` (lines 113, 142, 222) and `FileWriter`'s attachment-folder cleanup (`FileWriter.swift:32`) through this single helper.
- Keep the existing nested-path refusal (`migrate` lines 67–69) and add a guard that the migrator's source/old folder is never passed to an unconditional `removeItem` — the only removal of a directory is via `removeIfEmpty`.

No behavior change for correct paths; this just makes the invariant the only reachable code.

## Task 4: Regression tests — close the gaps the audit found

In `RaptureMac/RaptureMacTests/`:

1. **Active-folder-unchanged-on-failure** (the one real gap; audit requirement (d) second half). New `AppStateRelocationTests`: drive `AppState.setOutputFolder` into a failing relocate (read-only destination), then assert `settings.outputFolder` is unchanged, the sidecar is unchanged, `relocationStatus == .failed`, and the source tree is intact. The existing `testFailureLeavesSourceIntact` only covers the migrator in isolation.
2. **Create-if-absent never wipes.** Pre-create a non-empty folder containing `CLAUDE.md` + `processed/` + a note; run `FileWriter.write(...)` and `SettingsStore.ensureDefaultOutputFolder()` against it; assert every pre-existing item survives byte-for-byte.
3. **`removeIfEmpty` guard.** Assert the new helper deletes an empty dir and refuses a non-empty one (incl. a dir holding only a dotfile).
4. **Bare-recreate is documented behavior.** A test that deletes the configured folder out from under the writer, captures a note, and asserts `FileWriter` recreates the folder and writes the note — so the "came back bare" path is a known, asserted behavior rather than a silent surprise.

## Task 5: Opt-in starter scaffold (GOAL 3 — off by default)

- Add `Settings.seedScaffold: Bool = false` (Codable; defaults off, so existing `settings.json` round-trips unchanged).
- New `OutputFolderScaffold.seedIfEligible(folder:)`: acts **only** when the folder is empty **and** has no `CLAUDE.md` (case-insensitive). Creates a generic template `CLAUDE.md` (no user-specific repo paths), plus empty `processed/` and `in-progress/`. Strictly idempotent; never overwrites; reuses `FileSafety`/create-if-absent primitives.
- Invocation points, all gated by `seedScaffold == true` and the emptiness check: first-launch default init (`ensureDefaultOutputFolder`) and after a successful relocate into an empty new folder (`setOutputFolder`). It never runs against a non-empty folder, so it cannot disturb existing content.
- Settings → General: a toggle "Seed a starter scaffold in empty folders" (`SettingsGeneralView`), bound via `SettingsStore.binding(for:)`.
- Tests: seeds only on empty+no-CLAUDE.md; no-op when `CLAUDE.md` present; no-op when non-empty; idempotent across repeated calls; template contains no user-specific paths; toggle-off seeds nothing.

## Task 6: Docs + CHANGELOG

- CHANGELOG entry (next patch version): "Output-folder data-safety hardening — DEBUG build isolation (separate app-support container + default folder), centralized empty-only deletion guard, opt-in starter scaffold, and regression tests for the relocate-failure and create-if-absent invariants." Note the real incident root cause (manual test session, not shipped relocate) so the history is accurate. Update the test count.
- Update `agent-os/product/tech-stack.md` persistence section: note the DEBUG container split and the opt-in scaffold setting.

---

## Standards applied

- **testing/test-writing** — Tasks 4 & 5 are test-heavy; mirror existing `OutputFolderMigratorTests` structure (temp-dir fixtures, injected `FileManager`).
- **global/error-handling** — failure paths must stay fail-safe and surface a one-line user-facing message (the existing `MigrationError` pattern); the guard logs rather than throws on the no-op case.
- **backend/migrations** — file-move safety (verify-before-delete, idempotent, recoverable) is the governing discipline for the migrator touch-ups.

## Verification

1. **Build + tests:** `xcodebuild test` on the test scheme — all existing + new tests pass; confirm the bumped count.
2. **DEBUG isolation:** run a Debug build; confirm it reads/writes `~/Library/Application Support/Rapture for Mac (Debug)/` and defaults to `~/Documents/Rapture Notes (Debug)/`, leaving the release app's `settings.json` and real notes untouched. Confirm the "(Debug)" title marker shows.
3. **Relocate safety (manual, on Debug build only):** create a non-empty folder with `CLAUDE.md` + `processed/`; relocate to a new location; confirm the whole tree (incl. `CLAUDE.md` + history) arrives and the old folder is removed only when empty. Point at a read-only destination; confirm the move fails, source stays intact, active folder unchanged, error surfaced.
4. **Scaffold:** with `seedScaffold` off, an empty folder stays empty. Toggle on; an empty, `CLAUDE.md`-less folder gets template `CLAUDE.md` + `processed/` + `in-progress/`. Re-run; nothing changes (idempotent). Point at a folder that already has a `CLAUDE.md`; confirm it's left untouched.
