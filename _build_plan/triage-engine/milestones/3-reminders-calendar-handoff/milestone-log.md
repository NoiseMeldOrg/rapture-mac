# Milestone 3 — Reminders & Calendar Handoff — build log

> Built 2026-07-13 in a single session (plan mode → two Explore agents + one Plan agent → AskUserQuestion decisions → approval → TDD implementation → live debug-build checks). Suite: **551 tests, 0 failures** (99 new). Approved plan: `~/.claude/plans/typed-napping-treasure.md`. Uncommitted at log time.

## What was built

**New source — `RaptureMac/RaptureMac/Handoff/`** (folder-sync project, no pbxproj file-list edits):

- `HandoffDateParser.swift` — pure, hand-rolled natural-date grammar anchored to the capture's own timestamp (`NSDataDetector` cannot anchor "tomorrow" to a past reference, which backlog/spool-flush correctness requires). Grammar: `today`/`tomorrow`/full weekday names/`next <weekday>`/`<Month> <day>` (3-letter abbrevs + ordinals, year = next occurrence); times `9am`/`9:30 pm`/`9 a.m(.)`/`1:10`/`at 2`/`13:30`. Returns `Resolved{date, hasTime, hasExplicitDay, consumedRanges}` — consumed ranges drive title stripping; `hasExplicitDay` is what lets events demand a stated day.
- `HandoffDetector.swift` — pure conservative detection. Clause split on sentence punctuation (only when followed by whitespace/end — "9:30 p.m." survives) + newlines. Reminder triggers: `remind me to` / `remember to` / `don't forget (to)` / `make sure to` (case-insensitive, curly + straight apostrophe). Event: trigger-less clause with keyword {`appointment`, `appt`, `meeting`, `call`} AND explicit day AND time. First reminder + first event per note, max one of each. Mechanical title cleanup only: trigger + date phrase stripped, whitespace collapsed, trailing punctuation/"please" stripped, leading article stripped (events only), first letter capitalized, ≤60 chars word-boundary (`TitleDeriver.truncateAtWordBoundary`, made internal).
- `HandoffManager.swift` — `HandoffProcessing` protocol + `HandoffOutcome{reminderCreated, eventCreated}` + orchestrator: toggles → auth status (never a request) → past-event skip → `HandoffLedger` dedup → create with the **full original dictation in the item's notes field** (+ `Captured via Rapture <ISO>`) → record. Both toggles off = immediate `.none`, zero EventKit contact. 1-hour default event duration. One-shot revoked-grant error per kind, cleared on next success. Failures surface via `AppState.handoffLastError` + OSLog only — never the menu-bar error surface, never the filing.
- `EventKitClient.swift` — the seam: `HandoffKind`/`HandoffAuthStatus`/`HandoffTarget` + one kind-parameterized protocol (status/request/targets/createReminder/createEvent).
- `SystemEventKitClient.swift` — the only file importing EventKit. Lazy `EKEventStore` (construction is inert — `AppState` holds it unconditionally), every method front-guarded on `isRunningXCTests`, only `.fullAccess` maps to authorized (pickers must enumerate lists), stale/nil target ID falls back to the system default inside create.
- `HandoffLedger.swift` — `RelayFiledLedger` clone (TTL 90d / cap 500 / pure statics / StateStore persist). Fingerprint = `kind|normalizedTitle|dateKey` (lowercased, whitespace-collapsed, trailing punctuation stripped; dateKey = full UTC ISO for timed, `yyyy-MM-dd` for date-only, `none` for dateless). **Dateless fingerprints dedup on a 48-hour window**, dated on the full TTL.
- `HandoffPrompt.swift` — `AutomationPrompt` clone, kind-parameterized: pre-prompt NSAlert before the TCC dialog (Cancel aborts the toggle — unlike Automation's Quit), denied-alert with `Privacy_Reminders`/`Privacy_Calendars` deep links.
- `HandoffEnableFlow.swift` — the toggle-enable decision extracted from the view (testable with the fake client + injected prompt closures). **The only place the app ever requests EventKit access.** authorized → enable; notDetermined → pre-prompt → request → enable/deny; denied → System Settings nudge. 

**New elsewhere:** `Models/HandoffEntry.swift`; `UI/HandoffSettingsSection.swift` (General tab, after the iPhone App section: two toggles + target pickers shown while enabled + caption + red `handoffLastError` line; pickers load on appear only when toggled on AND authorized; a stored-but-missing target renders as "Missing target (uses default)").

**Changed:** `Settings` (+4 lenient-decoded fields: `remindersHandoffEnabled`/`calendarHandoffEnabled` default false, `remindersListID`/`calendarID` default nil), `PersistedState.handoffRecords`, `AppState` (`eventKit` injectable client + transient `handoffLastError`), `Replier` (`composeReplyText(…handoff:)` suffix: `✅ Saved · Reminder created` / `· Event created` / `· Reminder + event created`; suffix never resurrects a suppressed reply tier), `BatchProcessor` / `RelayProcessor` / `DestinationMonitor` / `TriageProcessor` (optional `handoff` init param, default nil — all pre-M3 tests compile unchanged), `Pipeline` (one shared lazy `HandoffManager` across all four seams), `project.pbxproj` (`INFOPLIST_KEY_NSRemindersFullAccessUsageDescription` + `NSCalendarsFullAccessUsageDescription` in both configs), `PRIVACY.md` (two permissions-table rows — truth patch only, narrative overhaul stays M5), `CHANGELOG.md`.

**The four filing seams** (the M2-log hard constraint, honored):

| Seam | Fire point | Never fires on |
|---|---|---|
| BatchProcessor (live iMessage) | write `.success`, before `replyForWrite` (outcome feeds the suffix) | `spoolCapture` (note not filed yet), write failures |
| RelayProcessor | `.success`, one hoisted byte-read shared with the triage-ledger hash; `capturedAt` from the relay filename stamp | ledger-hit ghost drains |
| DestinationMonitor (spool flush) | flush `.success` after `SpoolFiledLedger.record`, text read before `spool.remove`; `capturedAt` verbatim from `meta.json` | crash-resume delete-only path |
| TriageProcessor (hand-drop/backlog) | after `TriageLedger.record`, with footer-stripped body + filename-parsed (possibly old) `capturedAt` | ledger-hit ghost drains, raw mode (no conversion happens at all) |

Each capture hits exactly one seam; the HandoffLedger fingerprint is the second guard for every file-vs-record crash window.

## Decisions not pre-specified in the PRD

1. **Reminder trigger wins over appointment semantics** in one clause (user decision): "remind me to call John tomorrow at 2" → Reminder due 14:00, never an event. Trigger-less appointment statements still become events.
2. **Meridiem-less hours: 1–6 → PM, 7–11 → AM, 12 → noon** (user decision); 13–23 spoken-24-hour taken verbatim. Required by the PRD's own "1:10 tomorrow" example.
3. **Handoff is orthogonal to triage mode** (user decision): fires in raw `.txt` mode too — the toggles are independent opt-ins and detection reads dictated text, not note format. Asymmetry: raw mode has no backlog conversion, so root hand-drops don't hand off there (consistent — they aren't processed at all).
4. **Dateless-reminder dedup window = 48h** (user decision); dated items keep the 90d TTL. Blocks the systemic double-fire risks without eating a genuinely repeated chore next week.
5. **`next <weekday>` = bare weekday** — near-term dictation dominates; off-by-a-week is the worse error.
6. **Same-weekday resolution:** "Wednesday at 9am" dictated Wednesday 8am = today; 10am = next week; no time = next week (strictly-after).
7. **Time-only phrases** ("remind me at 5") = reference day, rolled +1 when already past. **Date-only reminders** get date-only `dueDateComponents` (no fabricated hour). **Dateless reminders** are created without a due date (rulebook behavior).
8. **Past-dated events skip; past-due reminders still create** — overdue is actionable, a past event is noise. Matters for spool flushes and backlog drains.
9. **Bare hours require "at"** (`buy 2 dozen eggs` is not 2:00); invalid minutes (`1:75`) drop the time entirely rather than falling through to a misparse.
10. **Reply suffix wording:** `✅ Saved · Reminder created` (et al.), success-tier only; catch-up batches still hand off but reply nothing per-message (existing isCatchup gating).
11. **Picker behavior:** target IDs stored as `calendarIdentifier` strings; nil = system default; a stale ID renders as "Missing target (uses default)" and creation falls back to the default inside `SystemEventKitClient` — one home for the policy.
12. **Detection language is English-only** (trigger phrases + date words), matching the trigger vocabulary itself; non-English dictations simply never hand off.

## Verification

- **Full suite: 551 tests, 0 failures** (99 new: parser 27, detector 21, ledger 9, manager 13, enable-flow 5, seams+suffix 10, decode 4, plus the M2 suites re-passing over the changed processors). No TCC prompts, no host restarts.
- **Live (debug build, isolated containers, verify-skill flow):**
  - *Updater decode:* the pre-M3 debug `settings.json`/`state.json` (no handoff keys) loaded with both toggles off and `handoffRecords: []`.
  - *Toggles off = filing untouched:* "remind me to water the plants tomorrow" hand-dropped at the root triaged into `Notes/` with the exact M1 contract; no handoff records, no errors, EventKit untouched.
  - *Fail-open without a grant:* toggles forced on in settings.json with TCC not determined → "remind me to change the furnace filter Wednesday at 9am" still triaged normally, nothing created, no crash, no persisted error (status-check-only on the filing path confirmed live).
  - *Usage strings* present in the built bundle's Info.plist (both keys).
- **Deferred to the release dogfood (needs real TCC clicks / Siri / FDA, same posture as M2's "debug builds have no FDA" deferral; unit-covered meanwhile):** the granted-path live checks — reminder lands in the chosen list, 1-hour event in the chosen calendar, re-dictation no-double-create, deny-path caption + deep link, spool-flush single handoff on remount, `✅ Saved · Reminder created` suffix on the phone. Five-minute checklist: swap in a signed build (or cut the release), flip each toggle (pre-prompt → TCC dialog), dictate the two PRD examples, re-dictate both, check Reminders/Calendar and the thread.

## Things milestone 4 needs to know

- **The AI seam is `HandoffProcessing` + `HandoffDetector`.** All four filing seams call `handoff.process(text:capturedAt:)` and know nothing about detection. M4's sharper detection replaces/augments `HandoffDetector.detect` *inside* `HandoffManager` (or a decorating `HandoffProcessing`) — the toggles, auth gating, past-skip, ledger dedup, notes-field contract, and reply suffix all live in the manager and apply to AI-detected candidates unchanged. Keep AI strictly behind the same two toggles and the same conservative bar (PRD).
- **`HandoffOutcome` is deliberately minimal** (two Bools for the reply suffix). If M4 wants richer surfacing (e.g. "what was created" in the menu bar), extend the outcome, not the seams.
- **The ledger fingerprint normalizes mechanically** (lowercase/whitespace/punctuation). AI smart titles will produce *different* titles for re-dictations of the same intent — dedup then rests on the AI titling being stable for near-identical input, or M4 fingerprinting on something sturdier (e.g. normalized clause text) for AI-detected items. Think before shipping.
- **Detection is intentionally narrow deterministically:** "remind me at 5 to call mom" (time before "to"), "dentist tomorrow" (no keyword), "schedule lunch with Sam Friday" (no keyword) do NOT hand off in M3 — they're exactly M4's headroom.
- `SpoolMetadata.version` is still 1 — nothing needed to ride through the spool because detection runs at the filing seam, after flush. If M4 ever detects *before* spooling, bump it.
- The `swift-concurrency` skill's guidance was applied (no new detached tasks; everything MainActor; pure helpers `nonisolated`).

## Deviations from the PRD

- **None in scope.** No recurrence, no invitees/locations/alerts, no review-step, no AI. PRIVACY got the table truth-patch only.
- The pre-prompt fires from the Settings toggle (as the milestone prompt directed) rather than lazily on first action like the Automation precedent — deliberate: the grant must exist before the first capture needs it, and the toggle is the natural consent moment.
