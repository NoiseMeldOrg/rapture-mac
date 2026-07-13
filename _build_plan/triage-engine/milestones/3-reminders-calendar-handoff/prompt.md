# Milestone 3 — Reminders & Calendar Handoff

You are entering plan mode to plan and then build milestone 3 of the triage-engine feature.

## Context

- Read `@_build_plan/triage-engine/prd.md` for the locked scope and this milestone's boundaries.
- Read the milestone logs for milestones 1–2 (`@_build_plan/triage-engine/milestones/1-triage-engine-core/milestone-log.md`, `@_build_plan/triage-engine/milestones/2-destination-resilience/milestone-log.md`).
- Read the repo `@CLAUDE.md` and `@CONTRIBUTING.md`. Key files and references before planning:
  - `RaptureMac/RaptureMac/Reply/AutomationPrompt.swift` and `UI/PermissionsView.swift` — the house pattern for pre-prompting before a TCC dialog; EventKit access (Reminders and Calendar are separate TCC grants on macOS 14+) follows the same explain-then-request shape. Remember the test host runs the app's `@main` — EventKit access must never be requested at launch or during tests (`isRunningXCTests` gating), only from the Settings toggle action.
  - `RaptureMac/RaptureMac/Reply/Replier.swift` — where the `✓ Saved` reply is composed; this milestone adds the small handoff suffix for iMessage-sourced captures
  - `RaptureMac/RaptureMac/Filter/RelayFiledLedger.swift` — the ledger shape to clone for the handoff dedup ledger (fingerprint: normalized title + due/start time)
  - `RaptureMac/RaptureMac/UI/SettingsGeneralView.swift` — Settings section precedent; this milestone adds the two toggles + list/calendar pickers (milestone 1 may have already created a triage section to extend)
  - Info.plist changes (usage-description strings) live in the Xcode project — see how existing permissions are declared
- **Behavioral reference (read if reachable):** the user's proven external rulebook at `~/Documents/Rapture Notes/CLAUDE.md` — its "Reminder extraction" section (trigger phrasings: "remind me to", "remember to", "don't forget", "make sure to"), its `other`-class title-cleanup examples (concise imperative, 3–10 words, filler stripped), its `calendar-event` class (why an appointment must become an event, not a reminder; 1-hour default; past-date skip), and its dedup rule (fingerprint = title + start ISO; "a duplicate event is a real-world side effect"). The PRD encodes the decisions; the rulebook shows worked examples. Note: deterministic-tier title cleanup should stay mechanical — full smart-titling is milestone 4.
- Dates parse relative to the capture's own timestamp (not processing time — a note captured Friday saying "tomorrow" means Saturday even if triaged Monday during backlog catch-up). Use the system time zone.
- Update `PRIVACY.md`'s permissions table for the two new TCC permissions in this milestone (minimal truth patch; the narrative overhaul is milestone 5).
- Tests: EventKit must be behind a protocol/seam so the suite runs without Reminders/Calendar TCC grants (injected fake store; the `RelayProcessorTests` injected-directory pattern is the model). Detection and date parsing should be pure functions with table-driven tests. Skills: `tdd`, `swift-concurrency`.

## Your task

1. Plan the implementation for **only** milestone 3 as defined in the PRD (toggles + pre-prompts + TCC, conservative deterministic detection, additive filing, target pickers, handoff ledger, reply suffix). No AI-assisted detection (milestone 4), no recurring items.
2. After the user confirms the plan, build only what is in milestone 3's scope.
3. Verify against the PRD's "Done when" for milestone 3 — including live checks: a "remind me…" dictation lands in the chosen Reminders list with the right due date and the note still files; a dated appointment becomes a 1-hour event; a re-dictation does not double-create; both toggles off = filing untouched. Run the full test suite.
4. When complete, write a `milestone-log.md` in this folder summarizing what was built, unspecified decisions made (detection patterns, date-parsing approach, picker behavior), anything milestone 4 needs to know (especially the detection seam AI will plug into), and any deviations.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
