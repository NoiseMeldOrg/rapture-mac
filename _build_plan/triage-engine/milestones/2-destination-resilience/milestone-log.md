# Milestone 2 — Destination Resilience — build log

> Built 2026-07-13 in a single session (plan mode → design-agent pressure-test → AskUserQuestion decisions → approval → implementation → live DMG e2e). Suite: **452 tests, 0 failures** (75 new). Approved plan: `~/.claude/plans/sharded-enchanting-brook.md`.

## What was built

**New source:**

- `Writer/DestinationGuard.swift` — pure, probe-injectable classifier: `available` / `volumeAbsent` / `folderMissing`. A path under `/Volumes/<name>` whose mount root is missing — or present but not a real volume root per `URLResourceKey.isVolume` (a leftover **shadow folder**) — is `volumeAbsent`; everything else missing is `folderMissing` (create as always). `nonisolated` (the project defaults to MainActor isolation).
- `Persistence/SpoolStore.swift` + `Models/SpoolItem.swift` — the internal spool at `Application Support/<container>/Spool/` (boot volume, DEBUG-isolated for free). The directory is the state, relay-folder style: one self-describing item directory `<seq8>-<ISO>/` holding `capture.txt`, `meta.json` (version, capturedAt, source, seq, spooledAt, failedAttachments), and optional `attachments/` copied in at spool time (Messages' attachment store isn't guaranteed to survive a long offline stretch). Items commit atomically via dot-prefixed staging dir + rename; the scanner ignores dot-prefixed names and any dir without `meta.json`. Seq comes from `PersistedState.spoolNextSeq` — monotonic forever (floored to `maxExisting+1` if state.json is ever lost), so names never reuse and same-second captures keep order.
- `Writer/SpoolFlusher.swift` (`SpoolFiling` seam) — files a spooled item with `FileWriter`'s conventions; `captured`/`source`/filename date come **verbatim from `meta.json`**, nothing re-inferred. Full mode byte-equals a live `writeTriaged` (golden-tested); raw mode byte-equals `writeRaw`.
- `App/DestinationMonitor.swift` — 2s availability poll (the FDA retry-poll idiom). Maintains `appState.destinationOffline` / `queuedCaptureCount` (spool + pending relay); on remount drains the spool **FIFO-strict** under `captureGate` with the relay's crash discipline (file → record `SpoolFiledLedger` → remove item; ledger-hit resume is delete-only). A failing head item blocks the queue with a surfaced error + 60s backoff rather than reordering. Mid-flush `.unavailable` stops cleanly.
- `Filter/SpoolFiledLedger.swift` + `Models/SpoolFiledEntry.swift` — `RelayFiledLedger` clone (TTL 90d / cap 500) keyed by item name.

**Changed:**

- `Models/WriteResult.swift` — new `Outcome.unavailable` (guard fired, filesystem untouched).
- `Writer/FileWriter.swift`, `Writer/RelayFiler.swift` — DestinationGuard at the top of every write entry point (defense in depth; these were the original shadow-folder sites — their unconditional `createDirectory` would happily recreate `/Volumes/<name>` on the boot volume).
- `App/BatchProcessor.swift` — spools when the guard says `volumeAbsent` **or the spool is non-empty** (closes the remount race where a live batch beats the monitor's flush and breaks capture order). On write `.failure`, re-runs the guard — `volumeAbsent` means the unplug raced the write → spool, not error. Spooling advances the watermark (the spool is durable), records the today count, tracks content-dedup, and replies. Spool-write failure itself keeps the old error+replay semantics.
- `Reply/Replier.swift` — `composeSpooledReplyText`: `✅ Queued — destination offline` for `.all` only (success-tier; no second reply on flush). `.unavailable` → no direct reply.
- `App/RelayProcessor.swift` — `volumeAbsent` is a quiet defer: files stay in the relay folder (it already is a durable, ledger-protected queue), no error, no backoff; pending count exposed via `appState.relayPendingOffline`, folded into the queued number.
- `App/TriageProcessor.swift` — `volumeAbsent` early-return before any mkdir (TOCTOU shadow guard; its sources live on the offline volume anyway).
- `App/AppState.swift` — new transients (`destinationOffline`, `queuedCaptureCount`, `relayPendingOffline`); `setOutputFolder` guards the **target** up front (`volumeAbsent` → `.failed`, folder unchanged — this was a fourth shadow-folder site via `ensureDirectory`) and, when relocating **away from** an absent volume, switches but surfaces a stranded-notes notice; applies the migrator's rename report to the triage ledger.
- `App/Pipeline.swift` — constructs/starts/stops the monitor; injects the spool into BatchProcessor. Monitor starts pre-FDA (a spool from a previous run must drain regardless).
- `UI/MenuBarStatus.swift` — `Kind.destinationOffline`, priority **FDA > Automation > Paused > DestinationOffline > Error > Capturing**, wording `⚠ Destination offline — N queued` (count omitted at 0). `MenuBarView` adds a reassurance caption; `RaptureMacApp`'s icon shows the warning triangle; `SettingsGeneralView` gains `destinationOfflineStatusView` in the folder section.
- `Models/PersistedState.swift` — `spoolNextSeq`, `spoolFiledRecords`, lenient-decoded.

**M1-deferred relocation fixes (`Persistence/OutputFolderMigrator.swift`):**

1. **Pair-aware merging.** Each directory level computes a `pairPlan` before iterating (kills the dir-visited-before-file ordering problem): a note (`<base>.md|.txt`, never `CLAUDE.md`) plus sibling dir `<base>` move as a unit through a dual collision walk (base free only when both file and dir are free — `FileWriter.uniqueDestination`'s own predicate). On collision both rename to `<base>-N` **in lockstep** and the note's footer links are rewritten (`CaptureContract.rewriteFooterFolder(inMarkdown:/inPlainText:)`, structural + golden-tested; best-effort — a rewrite failure leaves an honest stale link, never data loss). A paired attachment dir never takes the dir-into-dir merge path, which was the cross-wiring bug.
2. **Ledger remap.** `migrate` now returns a `MigrationReport` with `renamedNotes` (destination-relative old→new, pairs and singles both); `AppState.setOutputFolder` applies it via new `TriageLedger.remap(_:)` so ghost-draining and orphan-audio placement survive collision renames.
3. **`uniqueURL` period mis-split.** Extension semantics now follow the source item: directories are extensionless (`Notes v1.2` → `Notes v1.2-1`, not `Notes v1-1.2`).
4. The migrator is now `nonisolated` (it always ran in a detached task; under the project's MainActor default isolation that was a Swift-6-mode error waiting to land).

## Decisions not pre-specified in the PRD

1. **Relay defers in place; only iMessage spools** (user decision, AskUserQuestion). The relay folder is already a durable queue with crash-safe file→ledger→delete ordering; copying into the spool would duplicate machinery for nothing. Pending relay files count into the displayed queue number.
2. **Offline reply is the honest queued variant** (user decision): `✅ Queued — destination offline`, `.all` mode only, no second reply on flush. Trust over polish: the user walking to the Mac must not expect the note in the vault.
3. **Today count increments at spool time** (user decision): the capture is durable and the confirmation just fired; flush never re-counts (verified: flush leaves `todayCount` unchanged). Relay notes captured offline count at filing time, i.e. after remount — a small cross-source asymmetry, accepted.
4. **Spool location/format:** `Application Support/<container>/Spool/`, scan-based directory-as-state (no path list in state.json — one source of truth), staging-dir+rename commit, per-item `meta.json`, persisted monotonic seq. Chosen over a PersistedState-backed queue (crash divergence) and over "flush raw .txt to the root and let TriageWatcher convert" (wrong today-count semantics, sync-visible churn compose-direct exists to avoid, ~10s extra latency).
5. **Sidecar unchanged while offline** — `output-folder.path` keeps the configured destination; consumers see the folder missing, which is the truth. The spool is app-private.
6. **FIFO-strict flush** — a persistently failing head item blocks the queue (surfaced error + 60s backoff) rather than skipping ahead; "flush in original capture order" wins over throughput.
7. **Spool engages only for `volumeAbsent`** (plus the unplug-raced write). Disk-full/permission failures keep the pre-M2 error+replay/backoff behavior — spooling those would hide real problems.
8. **Batch spools whenever the spool is non-empty**, even with the destination available — global capture order can't be violated by a live batch racing the flush.

## Live e2e (debug build, isolated containers, hdiutil DMG as the fake external volume)

The dev machine's real external SSD hosts this repo, so the test volume was a 50 MB APFS DMG (`RaptureTestVol`), attach/detach standing in for plug/unplug. All passed:

- **Mounted:** relay note filed onto the volume (destination folder auto-created — folderMissing path), root `.txt` hand-drop triaged into `Links/` with correct contract.
- **Detached:** relay drop stayed in the relay folder with **no error recorded**; two planted spool items sat untouched; **`/Volumes/RaptureTestVol` did not exist** (no shadow folder); `state.json` clean.
- **Re-attached:** within one monitor/relay tick, spool items flushed **in seq order** with `captured`/`source` verbatim from metadata, relay note filed, spool emptied, `spoolFiledRecords` recorded both names in order, no errors, today count not double-incremented.
- Shadow-dir live probe (hand-created `/Volumes/<name>` plain folder) skipped — `/Volumes` isn't writable without sudo; the case is covered by `DestinationGuardTests.testShadowFolderAtMountRootIsVolumeAbsent` (injected `isVolumeRoot`) and can be hit live any time a stale shadow exists.
- iMessage **live** spooling wasn't drivable (debug builds have no FDA); the BatchProcessor spool path is covered by `DestinationOfflineTests` (spool + watermark + count + queued reply + dedup + the unplug-raced-write flip) with real `DestinationGuard` probes against a phantom `/Volumes` path.

## Accepted residuals (recorded, not changed)

- Orphaned partial attachment folders can persist on a volume that vanished mid-write and reappear on remount; the replay's dual-check collision walk takes a `-1` suffix. Cosmetic, never loss.
- `.atomic` writes don't `F_FULLFSYNC`; a success that never hit platters before a *physical* yank can vanish with the volume. Pre-existing for every write in the app.
- A capture spooled and flushed later files with its true `captured` time but a filename dated by the capture's **local calendar day** — same behavior as live writes; no drift introduced.
- Volumes mounted outside `/Volumes` (rare network mounts) classify as `folderMissing`, i.e. pre-M2 behavior. The `/Volumes` convention is the documented scope.
- Relay `relayPendingOffline` counts candidates in the last scan batch; orphan audio counts as a queued item. Close enough for a status line.

## Things M3 needs to know

- **The spool exists between capture and filing.** M3's Reminders/Calendar handoff detection should hang off the *filing* seams (`FileWriter.writeTriaged` / `RelayFiler.fileTriaged` / `SpoolFlusher.fileTriaged` / `TriageProcessor`) or a shared pre-filing hook — if it hangs off BatchProcessor only, a spooled "remind me…" would either hand off hours late (fine) or twice (not fine). The handoff ledger (PRD) must be consulted on the flush path too.
- `SpoolMetadata.version` is 1; if M3/M4 need to carry detection results through the spool, bump it and lenient-decode.
- `DestinationMonitor` owns the only periodic guard evaluation; anything else needing availability (e.g. EventKit gating does NOT — Reminders live off-volume) should read `appState.destinationOffline`, not re-poll.
- The `verify` skill flow now includes the DMG trick: `hdiutil create/attach/detach` simulates unplug/replug without touching real hardware.

## Deviations from the PRD

- None in scope or behavior. "Menu bar + Settings show destination state" ships as specified; the queued count folds spool + pending relay into one number.
