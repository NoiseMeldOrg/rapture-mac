# References for the Triage Engine

> Created: 2026-07-13

## The build-out snapshot (frozen historical record)

`_build_plan/triage-engine/` — the PRD and per-milestone prompts/logs, preserved per repo
convention, never referenced by code:

- `_build_plan/triage-engine/prd.md` — scope, data model, the five milestones, the
  documented commitment reversal.
- `_build_plan/triage-engine/milestones/1-triage-engine-core/milestone-log.md` — contract,
  classifier, watcher/processor, compose-direct, TriageLedger; the FSEvents→poll decision;
  the 10-angle review findings.
- `_build_plan/triage-engine/milestones/2-destination-resilience/milestone-log.md` —
  DestinationGuard, spool, FIFO flush, the M1-deferred relocation fixes (pair-aware
  merging, ledger remap).
- `_build_plan/triage-engine/milestones/3-reminders-calendar-handoff/milestone-log.md` —
  detector/manager/ledger, the four-seams table, the enable-flow/pre-prompt design, the
  dedup gap M4 later closed.
- `_build_plan/triage-engine/milestones/4-ai-triage/milestone-log.md` — engine resolution,
  validator posture, timeout/cooldown/401 latch, Keychain, dual fingerprints, live results
  on both engines.
- Milestone 5 (link enrichment + docs overhaul) was built 2026-07-13 in the same session
  this spec was written; it has no log — its durable facts are folded into `plan.md`
  (Enrichment module, `EnrichedLinkLedger`, `Links/Media/` artifacts, rename-on-enrichment,
  quiet-failure numbers, 727-test suite).

## External seed: the user's routing rulebook

`~/Documents/Rapture Notes/CLAUDE.md` (external to this repo — the destination folder's own
routing rules, written for the retired Claude-session pipeline). It seeded the taxonomy the
built-in engine encodes: the task/idea/journal/link classes, the smart-title rules
(concise imperatives, filler stripped, 3–10 words) distilled into `AITriagePrompt`, and the
calendar-log dedup rule that became `HandoffLedger`'s fingerprint window.

## Reference implementations mirrored (in-repo patterns)

- **`Watcher/RelayWatcher.swift`** — the poll + pure-planner idiom (folder re-read from
  settings each tick, `.icloud` placeholder nudging, snapshot settle logic). Mirrored by
  `TriageWatcher` and, for the 2s availability poll, `DestinationMonitor`.
- **`Filter/RelayFiledLedger.swift`** — the ledger shape (TTL + cap + pure statics,
  persisted in `state.json`, file→record→delete discipline). Cloned by `TriageLedger`,
  `SpoolFiledLedger`, `HandoffLedger`, `EnrichedLinkLedger`.
- **`Handoff/SystemEventKitClient.swift`** — the guard pattern for TCC/network entry
  points: sole file importing the framework, lazy store, every method front-guarded on
  `isRunningXCTests`, protocol seam + fake for tests. Reapplied verbatim by
  `TriageAI/AppleFoundationEngine.swift`, `TriageAI/AnthropicEngine.swift`, and
  `Enrichment/URLSessionLinkFetcher.swift`.
- **`Reply/AutomationPrompt` + `Handoff/HandoffEnableFlow.swift`** — the pre-prompt →
  request → deny-nudge enable flow; `AITriageEnableFlow` is the same pattern minus the TCC
  step (persist ON only on successful engine resolution).
- **The user's `extract-transcript` / `extract-webpage` Claude skills** (external,
  `~/.claude/skills/`) — the output conventions the enrichment artifacts mirror: raw
  transcript/readable-text extracts as Markdown with source/fetch frontmatter, no
  summarization.

## Approved implementation plans (external, `~/.claude/plans/`)

Per-milestone approved plans, referenced by the milestone logs: `mossy-napping-breeze.md`
(M1), `sharded-enchanting-brook.md` (M2), `typed-napping-treasure.md` (M3),
`async-herding-wreath.md` (M4).

## Anchor files for future work

- `Triage/CaptureContract.swift` — the contract's one owner (compose, parsers,
  `rewriteFooterFolder`). Anything that mutates a filed note must keep its footer parseable.
- `App/Pipeline.swift` — where every triage-era service is constructed, started, stopped,
  and shared.
- `Models/WriteResult.swift` — the composer→processor echo channel (`.ai`, `.unavailable`);
  extend the outcome, not the writer protocols.
- `.claude/skills/verify/SKILL.md` — the live-verification recipe accumulated across the
  milestones (debug-build swap, App Nap wake trick, DMG-as-external-volume, keychain and
  LaunchServices gotchas).
