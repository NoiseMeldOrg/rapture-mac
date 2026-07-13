# Milestone 1 — Triage Engine Core — build log

> Built 2026-07-13 in a single session (plan mode → approval → implementation → live e2e → review). Suite: **377 tests, 0 failures, 0 host restarts** (98 new). Approved plan: `~/.claude/plans/mossy-napping-breeze.md` (stress-tested by a review agent before approval; its confirmed issues C1–C7 were folded in).

## What was built

**New source** (folder-sync project — no pbxproj edits):

- `Models/TriageMode.swift` (`.full`|`.raw`), `Models/CaptureType.swift` (+ `subfolder` mapping), `Models/CaptureSource.swift`, `Models/TriagedEntry.swift`, `Models/TriageStatus.swift`, `Models/TriageCandidate.swift` (+ `TriageScanBatch`)
- `Triage/TriageClassifier.swift` — pure URL-dominant classification; explicit-scheme rule (`http(s)://` or `www.` required in the matched text — NSDataDetector's inferred schemes on bare domains stay voice notes); YouTube host set → `youtube-link`
- `Triage/TitleDeriver.swift` — pure titles: first ≤8 words/≤60 chars sanitized; relay basenames keep the iOS-derived title; links get `YouTube <videoID>` / host
- `Triage/CaptureContract.swift` — pure compose (frontmatter + body + `## Raw` invariant + markdown-link attachments footer), `filenameBase` (local calendar date), backlog parsers (`parseSourceFilename` shape inference, `parseFooter`), `relativePath`
- `Watcher/TriageWatcher.swift` — 5s poll + pure `plan(entries:firstSeen:previousSizes:now:)` on the destination root; settle = one-tick age AND size stable across consecutive snapshots; `.icloud` placeholder nudging reused from `RelayWatcher`; oldest-first ordering by contract timestamp → mtime
- `App/TriageProcessor.swift` — per-file capture-gate acquisition; in-lock re-reads of folder/mode + `fileExists` stale-snapshot guard; detached-task file reads (dataless File-Provider files must not block the main actor); ledger-hit drains only while the recorded note exists; conservative footer rule (referenced folder must exist); attachment folder move+rename+rewrite with compensating rollback; 60s failure backoff + 10 MB oversize cap; file → ledger → delete ordering
- `Filter/TriageLedger.swift` — TTL 90d / cap 500 / pure helpers; fingerprint = source filename + SHA-256 content hash; `mdRelativePath` per entry (solves safe ghost-draining, orphan-audio placement, and M5's rename forwarding)

**Changed:**

- `Writer/FileWriter.swift` — mode switch: `.raw` byte-identical legacy path; `.full` composes the final `.md` directly into `Notes/`|`Links/` (attachment folder named after the note from the start). `uniqueDestination` parameterized by extension.
- `Writer/RelayFiler.swift` — same compose-direct split; `fileOrphanAudio(at:to:preferredDirectory:)` places late audio in its note's own attachment folder (fallback: legacy root placement).
- `App/RelayProcessor.swift` — records a `TriagedEntry` (with content hash + `mdRelativePath`) for full-mode filings; orphan-audio path looks up the paired txt in the triage ledger.
- `App/BatchProcessor.swift` — `FileWriting` protocol + call site carry `mode: settings.triageMode`.
- `App/Pipeline.swift` — `startTriage()` (inside the existing `isRunningXCTests` guard), `stop()` extended.
- `App/AppState.swift` — transient `triageStatus` + `triageLastError` (relay-parity error surfacing).
- `Models/Settings.swift` — `triageMode`, lenient decode `?? .full` (updaters default ON — verified live: the pre-triage debug container decoded straight into full mode).
- `Models/PersistedState.swift` — `triagedRecords`, `triageIntroShown`.
- `Persistence/OutputFolderMigrator.swift` — `isPreserveOnCollision` narrowed from all-`.md` to `CLAUDE.md` only (all-`.md` would silently strand colliding triaged notes in the old folder on relocation).
- `Persistence/FileSafety.swift` — doc comment records the new deletion invariant.
- UI: `SettingsGeneralView` triage section (mode picker + status + error; stale `.txt` caption fixed), `MenuBarView` backlog-progress line + one-time intro notice (persisted via `triageIntroShown`).
- Docs: README (Markdown-note story, raw-mode pointer), PRIVACY (deterministic no-AI/no-network posture, `✅ Saved` example fixed), CHANGELOG `[Unreleased]`.
- `.claude/skills/verify/SKILL.md` — repo verify recipe (debug-build swap, App Nap wake trick, state.json as oracle).

## Decisions made during implementation (not pre-specified in the PRD)

1. **Watcher idiom: 5s poll + pure planner, not FSEvents.** The brain dump said FSEvents; the milestone prompt delegated the choice. With compose-direct locked, app-written captures (≈all volume) never touch the watcher — it serves only hand-drops, other-device sync deliveries, and the one-time backlog. For that residual traffic the house `RelayWatcher` idiom is self-healing across folder relocation (folder re-read from settings every tick; no fd lifecycle, no re-arm hooks) and reuses the proven `.icloud` placeholder handling. Latency is ≤ 2 poll ticks (~10s worst case), within the "lands within seconds" promise.
2. **Settle rule:** `firstSeen` age ≥ one tick AND size stable across two consecutive snapshots. mtime deliberately excluded (sync engines preserve old mtimes → would look instantly settled). Zero-byte files settle like any other and file as untitled notes (never stuck).
3. **Compose-direct writers duplicate the raw path rather than share it.** `writeRaw`/`writeTriaged` (and `fileRaw`/`fileTriaged`) are separate functions: the plan required the raw path byte-identical, and entangling them to share a few lines risks exactly the regression the escape hatch exists to prevent.
4. **Relay entry hashing:** `RelayProcessor` re-reads the relay txt after successful filing (before deletion) to hash it for the triage ledger — a second small read, accepted for interface simplicity (`WriteResult` stays unchanged).
5. **Today count:** watcher-converted external files do NOT increment (they were either counted at capture time or aren't captures); relay/iMessage counting unchanged.
6. **Source inference is a backlog-only heuristic** (pure-ISO name → `rapture-mac`, `<ISO> <title>` → `rapture-ios`, anything else → omitted). Live captures carry their source authoritatively via compose-direct. A future Android app must NOT reuse the `<ISO> <title>` filename shape at the destination root, or backlog inference would mislabel it as iOS.
7. **`swift-concurrency` skill** (repo CLAUDE.md's pick for this phase) installed but its global install is unsupported (PromptScript format); it landed project-local and its guidance was applied: `Task.detached` used only where the synchronous body must escape the MainActor (file reads, poll loops), with reasons documented at each site.

## Live e2e results (debug build, isolated containers)

- **Backlog drain:** 7 pending root `.txt` (pure-ISO, relay-shaped, freeform, YouTube URL, one with a real attachment folder + footer, plus two genuine July-6 dogfood leftovers) all converted correctly — right subfolders, contract frontmatter, iOS titles preserved, attachment folder moved with footer rewritten to markdown links, sources drained, ledger recorded. A real June YouTube capture landed as `Links/2026-06-26 YouTube TJ359NeY__A.md`.
- **Probes:** ghost re-delivery (same name+bytes) drained with no duplicate; deleting a note then re-dropping its source re-triaged instead of destroying the file; `.md` and `.txt.tmp` at root untouched; relay pair compose-directed (`source: rapture-ios`, iOS title, audio in the note's own folder, relay drained).
- **Updater path verified live:** the pre-existing debug `settings.json` (no `triageMode` key) decoded into full triage.

## Things the next milestone needs to know

- **App Nap finding (watch in production):** the debug build launched headlessly via `open` had its 5s poll loops napped by macOS — the backlog sat ~18 minutes until a `sample` attach woke the process, then drained instantly and correctly. The installed, user-launched app has not shown this (July-6 dogfood filed relay arrivals promptly), but if triage/relay latency ever looks wrong in production, consider a `ProcessInfo.beginActivity(.background)` assertion around the poll loops. The repo verify skill documents the wake trick.
- **Two Macs on one synced destination** would both triage the same external drop (per-machine ledgers). Out of scope; unchanged from the relay's one-Mac limitation.
- **Scaffold-story mismatch deferred to M5:** `OutputFolderScaffold`'s template CLAUDE.md and `examples/` still tell external agents to process root `.txt` — with full triage those never persist. M1's intro notice nudges users to retire external root-`.txt` automation; the template/examples rewrite is M5's docs overhaul.
- **M3 handoff seam:** detection will hang off the triage path (`TriageClassifier`/processor); M4's AI plugs in behind the same seam. The `TriagedEntry.mdRelativePath` field is the forwarding record M5's rename-on-enrichment needs.
- The stale `log show`/`log stream` emptiness from sandboxed shells and the `ls -la` stall are environment quirks noted in the verify skill.

## Post-implementation review (10-angle max-recall pass + gap sweep)

Fixed before commit (each with a regression test where testable):

1. Status-clobber guard was too narrow — any watcher tick could overwrite the "Triaging n of m" drain display; now only a mode flip (`.off`) interrupts it, and the processor's end-of-batch reset never clobbers `.off`.
2. `TriageCandidate.url` removed (dead field and a stale-path-after-relocation trap; the processor deliberately re-derives paths from the current folder).
3. `parseSourceFilename` now delegates title extraction to `TitleDeriver.relayTitle` (one rule, one owner).
4. Orphan audio no longer resurrects a deleted note's attachment folder — the ledger-derived placement is honored only while the note still exists (falls back to legacy root placement).
5. Watcher settle state resets when the watched folder path changes (a same-named file in a relocated-to folder must earn its own two sightings).
6. Unknown `triageMode` raw value decodes leniently to `.full` via raw String — previously it would throw and silently reset every setting. (`ReplyMode` has the same latent shape, pre-existing; left as-is.)
7. Whitespace-only remainder after a valid stamp keeps the parsed date/source.
8. `TimeZone` read at each use, not captured at init (system zone changes mid-run).
9. Multi-folder footer pick is deterministic (`sorted()` before `first(where:)`).
10. (Sweep) The processor's per-item progress write no longer clobbers a mid-drain `.off` — the watcher's status dedup posts `.off` exactly once, so overwriting it left the UI claiming the engine was active after the user disabled it.
11. (Sweep) `loggedNudgeFailures` resets on folder change alongside the settle maps, so a migrated `.icloud` placeholder gets its download-nudge fallback retried in the new location.

Accepted trade-offs, recorded rather than changed: a body containing its own `---` divider lines can be misread by pandoc-style parsers as a second YAML metadata block — inherent to every YAML-frontmatter format (Obsidian/Jekyll/Hugo share it; Obsidian only honors the block at file start), and the raw text is fully recoverable; relay txt double-read for the ledger hash (empty-hash fallback is harmless — relay re-arrivals are name-guarded by `RelayFiledLedger`); one `state.json` write per drained file; the deliberate sibling-duplication of writer paths / ledgers / backoff helpers (house pattern — byte-identical raw path was a hard requirement); `-N` collision suffixes kept in backlog titles (stripping risks mangling legitimate titles); footer links to since-deleted files preserved (honest dangling reference beats silently dropping it); triage ledger cap 500 means a >500-file backlog's earliest ghost-protection entries can evict (consequence: rare duplicate note, never loss).

**Deferred to M2 (relocation hardening owns these):** `OutputFolderMigrator` doesn't rename a colliding note's attachment folder alongside the `-N`-renamed note (footer links can cross-wire in the both-folders-populated edge); `TriagedEntry.mdRelativePath` isn't remapped after relocation collision-renames; `uniqueURL` mis-splits extensionless names containing periods (pre-existing).

## Deviations from the PRD

- **FSEvents → poll** (decision 1 above) — same observable behavior, flagged in the approved plan.
- None otherwise: scope matched the PRD's M1 section; EventKit/AI/enrichment/spool untouched.
