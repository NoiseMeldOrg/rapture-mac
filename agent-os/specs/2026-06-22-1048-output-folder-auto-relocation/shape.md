# Output Folder Auto-Relocation — Shaping Notes

## Scope

Make changing the Output Folder behave like Dropbox: when the user picks a new folder, the app
moves the existing notes tree to the new location automatically, then switches the active folder.
The happy path is silent and needs no extra clicks; only failures surface.

This is a change to existing functionality. Today, `pickFolder()` and `handleDrop(_:)` in
`SettingsGeneralView.swift` only reassign `settings.outputFolder` — new captures go to the new
folder, old notes are left behind.

## Decisions

- **Picked folder IS the notes folder.** Old contents move directly into the chosen folder; no
  `Rapture Notes/` subfolder is appended. Keeps today's semantics where the NSOpenPanel-picked
  folder is the output folder. *(Confirmed with user.)*
- **No security-scoped bookmarks.** The app isn't sandboxed and stores a plain `URL` in
  `settings.json`. The brief's "persist the bookmark" deliverable is moot; persisting the URL
  (already works) is enough.
- **Implement the `output-folder.path` sidecar and fix the docs.** It's documented in
  `CONTEXT.md`/`tech-stack.md` but was never built. The new centralized setter is its natural
  home, so we add it here and correct the false "security-scoped bookmark" claims. *(Confirmed
  with user.)*
- **Centralize all folder changes** through `AppState.setOutputFolder(_:) async`. Both UI entry
  points and any future programmatic change go through one relocation path.
- **Data-safety governs the move.** Same-volume → atomic per-item `moveItem`. Cross-volume →
  copy, verify, then delete source (never delete before verify). Merge on collision, never
  clobber. On any failure: leave the source intact and do **not** switch the active folder.
- **Quiesce capture with a real lock, not just `paused`.** The pipeline is `@MainActor` and an
  in-flight `FileWriter.write` can suspend ~2s on attachment retry; a batch also captures the
  output-folder URL at its start. A shared `CaptureGate` async mutex wraps the whole batch and
  the move, plus a transient `isRelocating` flag defers new batches (reusing the pause path
  without touching the user's persisted pause state).

## Context

- **Visuals:** None.
- **References:** The approved plan (`~/.claude/plans/dreamy-dazzling-newell.md`) and the existing
  pipeline code — see `references.md`.
- **Product alignment:** Fits the mission's "folder is the integration surface" commitment — the
  output folder stays a plain directory any downstream agent can watch. The sidecar is already on
  the roadmap as a planned patch ("Output-folder path sidecar"), so this closes that item too.
  No networking, no new permissions, no vendor coupling — all in scope for v1's boundaries.

## Standards Applied

- **global/error-handling** — data-safety rules map directly: fail fast on degenerate cases,
  user-friendly error message on failure ("Couldn't move notes: …"), clean up / never destroy
  the source, retry already exists in the writer.
- **global/coding-style** — small focused service (`OutputFolderMigrator`), DRY (reuse
  `FileWriter.uniqueDestination`'s `<base>-<n>` disambiguation pattern and `AtomicFile`), no
  backward-compat scaffolding needed.
- **testing/test-writing** — test behavior not implementation; cover the core relocation flows
  and the load-bearing data-safety cases (move/copy/merge/guards/failure-intact); fast temp-dir
  unit tests; clear names.
