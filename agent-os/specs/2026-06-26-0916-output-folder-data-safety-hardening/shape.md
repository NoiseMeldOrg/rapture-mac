# Output Folder Data-Safety Hardening — Shaping Notes

## Scope

Make the Output Folder safe against data loss — *as a verified property*, not a bug fix. The work originated from an incident report ("the Output Folder just ate user data") and a hardening brief with three goals: (1) relocate moves the whole tree safely, (2) folder creation never destroys an existing folder, (3) optional starter scaffold.

The shaping turned up that the brief's **premise was wrong**, so the spec was reframed before any code was written.

## The reconciliation (why the premise changed)

A triage agent flagged that `~/Documents/Rapture Notes/` had lost its `CLAUDE.md` + `processed/` + `in-progress/` and come back bare (recreated 2026-06-23 01:48), and attributed it to the v1.0.69 auto-relocate feature.

Investigation this session (evidence-backed, see `references.md`) found:

- **No production bug.** All 14 folder create/delete/move call sites are non-destructive: every `createDirectory` is create-if-absent (`withIntermediateDirectories: true`); every `removeItem` runs only after verification (cross-volume `place()`) or on a verified-empty directory (`removeIfEmpty`). `setOutputFolder` quiesces the writer via `CaptureGate`, migrates (same-volume atomic / cross-volume copy→verify→delete), and only on success switches the active folder + writes the sidecar. On failure: source intact, folder unchanged.
- **The migrator was already tested** for whole-tree+dotfiles, cross-volume copy-verify-delete, same-volume rename, `.md`-preserved-on-collision, and failure-leaves-source-intact. So GOAL 1 was already met.
- **Real root cause:** the 2026-06-22 *manual test session*. Debug and release builds shared one `~/Library/Application Support/Rapture for Mac/` container, which forced hand-editing the real `settings.json` and creating/deleting `RaptureTest-A/B`; the real folder was deleted as collateral. A later captured note then recreated it bare via `FileWriter`'s create-if-absent.
- **Data was recoverable:** routing rules preserved in `agentic-os-mirror/.../demo/rapture-notes-CLAUDE.md`; `processed/`/`in-progress/` intact in the 2026-06-21 13:37 Time Machine local snapshot.

So "find and fix the data-eating bug" had no production bug to fix. The spec was reframed to **lock the invariants with tests + eliminate the actual root cause**, plus the opt-in scaffold.

## Decisions

- **Scope = "lock invariants + fix root cause"** (user-confirmed). Not a migrator rewrite.
- **Root-cause fix = DEBUG-build isolation.** Separate Application Support container (`Rapture for Mac (Debug)`) + separate default folder (`~/Documents/Rapture Notes (Debug)/`) for debug builds, so manual/dev testing physically cannot touch the installed app's data. A "(Debug)" UI marker keeps it visible.
- **Invariant guard = one chokepoint.** `FileSafety.removeIfEmpty` is the only directory-removal primitive; migrator + writer cleanup both route through it. Dotfiles count as content. Makes "delete a non-empty output folder" unreachable.
- **Scaffold = opt-in, off by default** (user-confirmed, over "automatic"). Seeds only an empty, `CLAUDE.md`-less folder; generic template (no user-specific paths); idempotent.
- **Forward-compat:** `Settings` decodes leniently so adding `seedScaffold` can't break loading an existing `settings.json` (which would otherwise reset `outputFolder`).
- **Out of scope:** rewriting the migrator/relocate flow; restoring the user's specific lost data (a separate snapshot-recovery step); automatic scaffold seeding.

## Context

- **Visuals:** None.
- **References:** the existing pipeline code — `OutputFolderMigrator`, `AppState.setOutputFolder`, `CaptureGate`, `FileWriter`, `AppSupportDirectory`, `SettingsStore`, and `OutputFolderMigratorTests`. Full file:line audit in `references.md`.
- **Product alignment:** the folder is the integration surface (mission); data-safety of that folder is load-bearing. The relocate + sidecar shipped in v1.0.69; this hardens the same subsystem.

## Standards Applied

- **testing/test-writing** — Tasks 4 & 5 are test-heavy; mirror `OutputFolderMigratorTests` (temp-dir fixtures, injected `FileManager`, behavior-focused names).
- **global/error-handling** — failure paths stay fail-safe and user-legible (`MigrationError`); the guard logs rather than throws on its no-op.
- **backend/migrations** — file-move discipline (verify-before-delete, idempotent, recoverable) governs the migrator touch-ups; the DB-specific bullets don't apply.

## Outcome

Implemented on branch `feat/output-folder-data-safety-hardening`. 214 → 234 tests, all passing. Release-build behavior unchanged except the opt-in scaffold (off by default).
