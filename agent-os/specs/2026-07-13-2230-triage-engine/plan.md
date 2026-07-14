# Plan: Built-in Triage Engine

> Created: 2026-07-13

This is the backport spec for the triage-engine build-out (PRD 2026-07-13, five milestones
built and shipped the same day). The build was scaffolded in `_build_plan/triage-engine/`
(frozen historical snapshot); this document is the durable, canonical technical breakdown
future work should consult. Suite at completion: **727 tests, 0 failures**.

## What shipped

Rapture for Mac is now the one triage path for every capture. Every capture — Siri-dictated
iMessage, Rapture iOS relay note, or a `.txt` hand-dropped at the destination root — becomes
a structured Markdown note the moment it arrives: YAML frontmatter capture contract,
deterministic classification and filing into subfolders, and opt-in tiers on top
(Reminders/Calendar handoff via EventKit, AI triage via Apple on-device models or a
BYO Anthropic key, link enrichment fetching YouTube transcripts and article text). The
interim external pipeline (launchd watcher + Claude session routing) is retired. A
per-destination raw-`.txt` mode restores exact pre-triage (v1.0.88) behavior.

## The capture contract

Composed by pure `Triage/CaptureContract.swift`; every triaged note honors it:

- **Frontmatter:** `captured` (ISO 8601, the capture's own timestamp — never the filing
  time), `source` (`rapture-mac` | `rapture-ios` | `rapture-android`; omitted when
  unknowable, e.g. a hand-dropped file), `type` (`voice-note` | `youtube-link` |
  `article-link`; the AI tier refines to `task` | `idea` | `journal`), `raw_media` (the
  URL, link captures only).
- **Body:** the best available text. Whenever the body differs from the verbatim capture
  (iOS AI formatting, Mac AI formatting), the verbatim lives under `## Raw` in the same
  file. Raw text is never discarded.
- **Filename:** `YYYY-MM-DD <Title>.md` — date is the capture's local calendar day; exact
  time lives in frontmatter; collisions walk `-1`, `-2` via `FileWriter.uniqueDestination`
  (parameterized by extension).
- **Filing:** `Notes/` (voice-notes and every fallback), `Links/` (link types); the AI tier
  adds `Tasks/`, `Ideas/`, `Journal/` (`CaptureType.subfolder`).
- **Attachments:** the sibling folder is named after the note from the start (compose-direct)
  or moved/renamed with footer rewrite (backlog conversion); footer entries are markdown
  links. `CaptureContract.rewriteFooterFolder` is the structural rewriter other code
  (relocation, enrichment) relies on.
- **Source deletion:** the original `.txt` is deleted only after the `.md` is durably
  written (file → ledger → delete ordering everywhere).
- Backlog parsers (`parseSourceFilename` shape inference, `parseFooter`) recover contract
  fields from pre-triage files. Source inference from filename shape is a backlog-only
  heuristic; live captures carry their source authoritatively via compose-direct. A future
  Android app must not reuse the `<ISO> <title>` filename shape at the destination root.

## Deterministic triage (M1)

- `Triage/TriageClassifier.swift` — pure URL-dominant classification. Explicit-scheme rule:
  `http(s)://` or `www.` required in the matched text (NSDataDetector's inferred schemes on
  bare domains stay voice notes). YouTube host set → `youtube-link`.
- `Triage/TitleDeriver.swift` — pure titles: first ≤8 words / ≤60 chars sanitized; relay
  basenames keep the iOS-derived title (provenance wins, including over AI titles); links
  get `YouTube <videoID>` / host until enrichment fetches the real title.
- `Watcher/TriageWatcher.swift` — 5s poll + pure `plan(entries:firstSeen:previousSizes:now:)`
  over the destination root. Settle rule: `firstSeen` age ≥ one tick AND size stable across
  two consecutive snapshots (mtime deliberately excluded — sync engines preserve old
  mtimes). `.icloud` placeholder nudging reused from `RelayWatcher`. Oldest-first by
  contract timestamp → mtime. Settle state resets on folder change.
- `App/TriageProcessor.swift` — per-file capture-gate acquisition; in-lock re-reads of
  folder/mode + `fileExists` stale-snapshot guard; detached-task file reads (dataless
  File-Provider files must not block the main actor); ledger-hit drains only while the
  recorded note exists; conservative footer rule (referenced folder must exist); attachment
  move+rename+rewrite with compensating rollback; 60s failure backoff; 10 MB oversize cap.
- `Filter/TriageLedger.swift` — TTL 90d / cap 500 / pure statics; fingerprint = source
  filename + SHA-256 content hash; `mdRelativePath` per entry powers ghost draining,
  orphan-audio placement, and enrichment's rename forwarding. `remap(_:)` applies the
  migrator's rename report after relocation.

**Compose-direct is the main path.** `FileWriter` and `RelayFiler` each split into a
byte-identical legacy raw path (`writeRaw` / `fileRaw`) and a triaged path (`writeTriaged` /
`fileTriaged`) that composes the final `.md` directly into `Notes/`|`Links/` — app-written
captures never round-trip through a root `.txt` and never touch the watcher. The watcher
serves only hand-drops, other-device sync deliveries, and the one-time backlog (latency
≤ 2 poll ticks). `Settings.triageMode` (`.full` default, including for updaters via lenient
decode | `.raw` escape hatch) selects the path; `BatchProcessor` carries the mode through
the `FileWriting` protocol.

## The four filing seams

Every capture is filed by exactly one of these; handoff detection and (for the three
composers) the AI call hang off them, never off the watchers:

| Seam | Fire point for handoff | Never fires on |
|---|---|---|
| `BatchProcessor` (live iMessage) → `FileWriter` | write `.success`, before the reply (outcome feeds the `✅ Saved · Reminder created` suffix) | spooled captures (not filed yet), write failures |
| `RelayProcessor` → `RelayFiler` | `.success`; one hoisted byte-read shared with the triage-ledger hash; `capturedAt` from the relay filename stamp | ledger-hit ghost drains |
| `DestinationMonitor` (spool flush) → `SpoolFlusher` | flush `.success` after `SpoolFiledLedger.record`; `capturedAt` verbatim from `meta.json` | crash-resume delete-only path |
| `TriageProcessor` (hand-drop/backlog) | after `TriageLedger.record`, footer-stripped body, filename-parsed `capturedAt` | ledger-hit ghost drains; raw mode |

## Spool + destination resilience (M2)

- `Writer/DestinationGuard.swift` — pure, probe-injectable, `nonisolated` classifier:
  `available` / `volumeAbsent` / `folderMissing`. A path under `/Volumes/<name>` whose mount
  root is missing — or present but not a real volume root per `URLResourceKey.isVolume`
  (a leftover shadow folder) — is `volumeAbsent`; anything else missing is `folderMissing`
  (create as always). Guard sits at the top of every write entry point (`FileWriter`,
  `RelayFiler`, `TriageProcessor` early-return, `AppState.setOutputFolder` target check) —
  defense in depth against recreating `/Volumes/<name>` on the boot volume.
- `Persistence/SpoolStore.swift` + `Models/SpoolItem.swift` — the internal spool at
  `Application Support/<container>/Spool/` (DEBUG-isolated for free). Directory-as-state,
  relay-folder style: one item directory `<seq8>-<ISO>/` holding `capture.txt`, `meta.json`
  (version 1: capturedAt, source, seq, spooledAt, failedAttachments), optional
  `attachments/` copied at spool time. Atomic commit via dot-prefixed staging dir + rename.
  `PersistedState.spoolNextSeq` is monotonic forever (floored to `maxExisting+1` if
  state.json is lost).
- `Writer/SpoolFlusher.swift` (`SpoolFiling` seam) — files a spooled item with `FileWriter`'s
  conventions; `captured`/`source`/filename date come verbatim from `meta.json`, nothing
  re-inferred; golden-tested byte-equal to a live write in both modes.
- `App/DestinationMonitor.swift` — 2s availability poll; maintains
  `appState.destinationOffline` / `queuedCaptureCount` (spool + pending relay); on remount
  drains the spool FIFO-strict under `captureGate` with file → `SpoolFiledLedger.record` →
  remove-item ordering. A failing head item blocks the queue (surfaced error + 60s backoff)
  rather than reordering. Owns the only periodic guard evaluation — anything else needing
  availability reads `appState.destinationOffline`.
- `Filter/SpoolFiledLedger.swift` — `RelayFiledLedger` clone (TTL 90d / cap 500) keyed by
  item name.
- Policy: only iMessage spools (`volumeAbsent`, the unplug-raced write via guard re-run on
  `.failure`, or whenever the spool is non-empty — closes the remount race); relay defers
  in place (the relay folder is already a durable queue); disk-full/permission failures keep
  error+replay semantics. Spooling advances the watermark, counts toward today, tracks
  dedup, and replies `✅ Queued — destination offline` (`.all` tier only, no second reply on
  flush). `WriteResult.Outcome.unavailable` = guard fired, filesystem untouched. Menu-bar
  priority: FDA > Automation > Paused > DestinationOffline > Error > Capturing.
- Relocation hardening landed here: pair-aware merging in `OutputFolderMigrator` (note +
  sibling attachment dir move as a unit through a dual collision walk, lockstep `-N` rename,
  footer rewrite), `MigrationReport.renamedNotes` → `TriageLedger.remap`, `uniqueURL`
  extension semantics follow the source item, migrator `nonisolated`.

## EventKit handoff (M3) — detector → manager → ledger

All in `RaptureMac/RaptureMac/Handoff/`:

- `HandoffDateParser.swift` — pure hand-rolled natural-date grammar anchored to the
  capture's own timestamp (NSDataDetector can't anchor "tomorrow" to a past reference,
  which backlog/spool-flush correctness requires). Meridiem-less hours: 1–6 → PM,
  7–11 → AM, 12 → noon; `next <weekday>` = bare weekday; bare hours require "at".
- `HandoffDetector.swift` — pure, conservative, English-only. Reminder triggers: `remind me
  to` / `remember to` / `don't forget (to)` / `make sure to`. Event: trigger-less clause
  with keyword {appointment, appt, meeting, call} AND explicit day AND time. Reminder
  trigger wins over appointment semantics in one clause. Max one reminder + one event per
  note. Mechanical title cleanup only. `detectDetailed` returns the verbatim clause (M4's
  dedup needs it).
- `HandoffManager.swift` (`HandoffProcessing` protocol, `HandoffOutcome{reminderCreated,
  eventCreated}`) — the orchestrator every seam calls: toggles → auth **status check, never
  a request** on the filing path → past-event skip (past-due reminders still create) →
  ledger dedup → create with the full original dictation in the item's notes field
  (+ `Captured via Rapture <ISO>`) → record. 1-hour default event duration. Failures go to
  `AppState.handoffLastError` + OSLog only — never the menu bar, never the filing. One
  shared lazy instance across all four seams (`Pipeline`).
- `EventKitClient.swift` — the seam (kind-parameterized protocol: status/request/targets/
  createReminder/createEvent). `SystemEventKitClient.swift` is the only file importing
  EventKit: lazy `EKEventStore`, every method front-guarded on `isRunningXCTests`, only
  `.fullAccess` maps to authorized, stale/nil target ID falls back to the system default
  inside create (one home for the policy).
- `HandoffLedger.swift` — `RelayFiledLedger` clone (TTL 90d / cap 500) with **dual
  fingerprints since M4**: the mechanical title fingerprint (`kind|normalizedTitle|dateKey`)
  and the clause fingerprint (`kind|clause|normalizedClause|dateKey`) are both recorded and
  checked on every creation, so the same re-dictated utterance blocks deterministic↔AI
  double-creates in either direction despite AI title drift. Dateless fingerprints dedup on
  a 48-hour window; dated on the full TTL.
- `HandoffPrompt.swift` / `HandoffEnableFlow.swift` — pre-prompt NSAlert before the TCC
  dialog; the enable flow is **the only place the app ever requests EventKit access**
  (authorized → enable; notDetermined → pre-prompt → request; denied → System Settings
  deep-link nudge). Fired from the Settings toggle, deliberately eager: the grant must
  exist before the first capture needs it.
- Handoff is orthogonal to triage mode (fires in raw mode too — detection reads dictated
  text, not note format). Settings: `remindersHandoffEnabled` / `calendarHandoffEnabled`
  (default false) + `remindersListID` / `calendarID` (nil = system default). Usage strings
  in the pbxproj (`NSRemindersFullAccessUsageDescription` / `NSCalendarsFullAccessUsageDescription`).

## AI tier (M4)

All in `RaptureMac/RaptureMac/TriageAI/`:

- **Engine resolution** (`AIEngineResolver.swift`, pure truth table, fresh per capture):
  Apple on-device model available (macOS 26+ with Apple Intelligence) → apple; else key
  present && !keyRejected → anthropic; else `.none(reason:)` composing the honest Settings
  line. `AppleFoundationEngine.swift` is the only file importing FoundationModels
  (`#if canImport` + `@available(macOS 26.0, *)`, weak-linked; deployment target stays
  macOS 14); fresh `LanguageModelSession` per capture, `@Generable` guided generation.
  `AnthropicEngine.swift` + pure golden-tested `AnthropicWire.swift`: POST
  `api.anthropic.com/v1/messages`, model `claude-haiku-4-5`, structured outputs
  (json_schema, `additionalProperties: false`), key read at call time.
- **Service** (`AITriageService.swift`, one `@Observable @MainActor` instance across all
  four composers): toggle gate (off = zero engine contact) → empty-text gate → cooldown
  gate → resolution → 6,000-char clip → **10s timeout race** → validation → bookkeeping.
  Transport failures (timeout/network/non-401 HTTP) cooldown after 2 consecutive strikes
  for 60s (bounds a dead network's cost across a backlog drain); refusal/garbage are
  per-capture misses, not strikes; **one 401 latches `keyRejected`** until the key is
  re-saved. Errors surface via `appState.aiEngineStatus` / `aiLastError` — Settings only,
  never the menu bar. `nil` output = deterministic path, always; AI unavailability never
  blocks or delays filing, and there is no retroactive re-triage.
- **Validator** (`AITriageValidator.swift`, the pure mechanical gate between model output
  and trust): classification ∈ {task, idea, journal}; titles sanitized + capped (10 words /
  60 chars); formattedBody discarded when input was clipped, empty, equal to raw, or outside
  [½×, 1½×] of raw length; handoff clauses must appear verbatim in the raw text under
  normalized containment (a fabricated clause is the hallucination tell); events need full
  date+time; partial reminder dates degrade to dateless; impossible dates rejected; 1+1
  cap. All-handoffs-discarded ⇒ `handoffsInvalidated` → `HandoffManager` falls back to the
  deterministic detector (a hallucinating model can't silently disable trusted M3
  behavior); a *validated* empty AI list is trusted.
- **Placement:** the AI call happens **inside the four composers, just before compose**
  (`FileWriter.writeTriaged` / `RelayFiler.fileTriaged` / `SpoolFlusher.fileTriaged` /
  `TriageProcessor` inline) — the only places that hold the capture text and decide
  type/title/body, so classification, smart title, formatted body, and `## Raw` land in one
  atomic write. Voice-notes only (deterministic link detection runs first and wins);
  `.full` mode only; never at spool-enqueue (AI runs at flush against the item's own
  `capturedAt`). The result echoes back via `WriteResult.ai` so the processors feed
  `HandoffManager` AI candidates without a second read. The prompt
  (`AITriagePrompt.swift`) is the single source of truth for both engines and the one
  manual iteration knob; `userMessage` carries the capture instant + weekday in the
  author's zone.
- **Credential:** `Persistence/KeychainStore.swift` — the app's one credential
  (`CredentialStore` protocol; generic-password item, service `noisemeld.RaptureMac`, DEBUG
  `noisemeld.RaptureMac.debug`, account `anthropic-api-key`, AfterFirstUnlockThisDeviceOnly,
  delete-then-add upsert). Never in settings.json.
- `AITriageEnableFlow.swift` persists ON only when an engine resolves; later unavailability
  never silently flips the setting. `Settings.aiTriageEnabled` default false. UI lives in
  the dedicated **Triage tab** (`SettingsTriageView` + `AITriageSettingsSection` +
  `HandoffSettingsSection` + `LinkEnrichmentSettingsSection`). DEBUG-only
  `RAPTURE_AI_FORCE_ENGINE=anthropic` env override for live verification.

## Link enrichment (M5)

All in `RaptureMac/RaptureMac/Enrichment/`:

- `LinkEnrichmentService.swift` — an in-memory FIFO worker (no persisted queue, no
  backfill): jobs enqueue when a `youtube-link` / `article-link` note files; the **fetch
  happens outside the capture gate**; then one gated mutation pass applies everything —
  write the artifact, rename the note, insert the media link.
- `URLSessionLinkFetcher.swift` (`LinkFetcher` seam) — with `TriageAI/AnthropicEngine.swift`
  the only outbound networking in the app beside Sparkle; XCTest-front-guarded.
- Pure parsers, golden-tested: `YouTubeTranscript.swift` (caption-track fetch/parse),
  `ArticleExtractor.swift` (readable-text extraction), `LinkFingerprint.swift`
  (video-ID / normalized-URL keying), `EnrichmentArtifact.swift` (artifact compose).
- **Artifacts** land in `Links/Media/` with frontmatter: source URL, fetch date, pointer to
  the capture note, and type. The raw extract, no summarization.
- **Rename:** the link note gets a one-time, pair-aware, collision-safe rename to the
  fetched real video/page title (attachment sibling folder renames in lockstep;
  `TriageLedger.remap` keeps ledger paths valid).
- **Media link block** is inserted into the note body **before** the Attachments footer, so
  `CaptureContract.rewriteFooterFolder` keeps parsing the footer it expects.
- `Filter/EnrichedLinkLedger.swift` — dedup keyed `yt:<videoID>` / `url:<normalized URL>`
  (TTL 90d / cap 500, remapped on relocation): a re-captured link files a new note pointing
  at the existing artifact, no re-fetch.
- **Quiet failure posture:** 3 transport attempts (30s / 120s backoff); content-class
  failures (no captions, unextractable page) give up at once; 60s cooldown after 2
  consecutive failed jobs; the only surface is a Settings-tab error line
  (`AppState.enrichmentLastError`). The link note is always already filed and complete
  without enrichment.
- `Settings.linkEnrichmentEnabled` — off by default, independent of AI triage.

## Settings and state additions

All lenient-decoded (`decodeIfPresent ?? default`) so older files load unchanged:

- `Settings`: `triageMode` (?? `.full` — updaters default ON), `remindersHandoffEnabled` /
  `calendarHandoffEnabled` (?? false), `remindersListID` / `calendarID` (?? nil),
  `aiTriageEnabled` (?? false), `linkEnrichmentEnabled` (?? false).
- `PersistedState`: `triagedRecords`, `triageIntroShown`, `spoolNextSeq`,
  `spoolFiledRecords`, `handoffRecords`, enriched-link records — all in `state.json`.
- Keychain: the Anthropic API key (see above), the only secret.

## Where everything lives

Paths relative to `RaptureMac/RaptureMac/` unless noted (folder-sync project — new files
need no pbxproj edits):

| Area | Files |
|---|---|
| Contract + deterministic triage | `Triage/CaptureContract.swift`, `Triage/TriageClassifier.swift`, `Triage/TitleDeriver.swift` |
| Watcher + processor | `Watcher/TriageWatcher.swift`, `App/TriageProcessor.swift` |
| Ledgers | `Filter/TriageLedger.swift`, `Filter/SpoolFiledLedger.swift`, `Filter/EnrichedLinkLedger.swift`, `Handoff/HandoffLedger.swift` |
| Writers (compose-direct + seams) | `Writer/FileWriter.swift`, `Writer/RelayFiler.swift`, `Writer/SpoolFlusher.swift`, `Writer/DestinationGuard.swift` |
| Spool | `Persistence/SpoolStore.swift`, `Models/SpoolItem.swift`, `App/DestinationMonitor.swift` |
| Handoff | `Handoff/HandoffDateParser.swift`, `HandoffDetector.swift`, `HandoffManager.swift`, `HandoffLedger.swift`, `EventKitClient.swift`, `SystemEventKitClient.swift`, `HandoffPrompt.swift`, `HandoffEnableFlow.swift` |
| AI | `TriageAI/AITriage.swift`, `AITriagePrompt.swift`, `AITriageValidator.swift`, `AIEngineResolver.swift`, `AITriageService.swift`, `AppleFoundationEngine.swift`, `AnthropicEngine.swift`, `AnthropicWire.swift`, `AITriageEnableFlow.swift`; `Persistence/KeychainStore.swift` |
| Enrichment | `Enrichment/LinkEnrichmentService.swift`, `LinkEnrichment.swift`, `LinkFetcher.swift`, `URLSessionLinkFetcher.swift`, `YouTubeTranscript.swift`, `ArticleExtractor.swift`, `LinkFingerprint.swift`, `EnrichmentArtifact.swift` |
| Models | `Models/TriageMode.swift`, `CaptureType.swift`, `CaptureSource.swift`, `TriagedEntry.swift`, `TriageStatus.swift`, `TriageCandidate.swift`, `SpoolFiledEntry.swift`, `HandoffEntry.swift`, `EnrichedLinkEntry.swift`, `WriteResult.swift` (`.unavailable`, `.ai`) |
| UI | `UI/SettingsTriageView.swift`, `AITriageSettingsSection.swift`, `HandoffSettingsSection.swift`, `LinkEnrichmentSettingsSection.swift`, `MenuBarStatus.swift` |
| Wiring | `App/Pipeline.swift` (constructs/starts everything, shared `HandoffManager` + `AITriageService` + enrichment service), `App/AppState.swift` (transients: `triageStatus`, `triageLastError`, `destinationOffline`, `queuedCaptureCount`, `relayPendingOffline`, `handoffLastError`, `aiEngineStatus`, `aiLastError`, `enrichmentLastError`) |

## Known residuals (accepted, recorded)

- The in-composer AI call extends a per-file capture-gate hold by up to 10s worst case
  (typical 1–3s); the cooldown bounds pathology. Enrichment avoids this entirely by
  fetching outside the gate.
- Two Macs sharing one synced destination would both triage the same external drop
  (per-machine ledgers) — unchanged from the relay's one-Mac posture.
- Triage-ledger cap 500 means a >500-file backlog can evict its earliest ghost-protection
  entries: rare duplicate note, never loss. Dual handoff fingerprints halve effective
  HandoffLedger capacity to ~250 items.
- Volumes mounted outside `/Volumes` classify as `folderMissing` (pre-M2 behavior); the
  `/Volumes` convention is the documented scope.
- A body containing its own `---` lines can be misread by pandoc-style parsers as a second
  YAML block — inherent to YAML frontmatter; Obsidian only honors the block at file start.
- App Nap can slow the 5s poll loops for a headless-launched debug build; the installed app
  hasn't shown it. If production latency ever looks wrong, consider
  `ProcessInfo.beginActivity(.background)` around the poll loops.
