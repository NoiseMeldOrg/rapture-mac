# Triage Engine — Shaping Notes

> Created: 2026-07-13

Why the feature is shaped the way it is. The what/where lives in `plan.md`.

## The mission reversal: output neutrality replaces processing neutrality

This feature knowingly reversed two commitments written into `agent-os/product/mission.md`
and `CONTEXT.md`: *"no built-in AI/LLM integration"* and *"no in-app editing, tagging, or
categorizing of captures."* The replacement stance is **output neutrality**: the folder
remains the integration surface, and any AI or tool can read the triaged Markdown — what
changed is that Rapture now does the first-pass processing itself, so a non-technical user
gets structured notes with zero setup and no external scripts. The interim external
pipeline (launchd watcher feeding a Claude session) is retired; the app is the one triage
path.

The reversal was deliberate and loud, never silent: the PRD names it up front, and M5's
docs overhaul rewrote `mission.md`, `CONTEXT.md`, `README.md` (including the network
badge), and `PRIVACY.md` (including its grep-verification instructions) coherently. Link
enrichment and the BYO-key Anthropic engine are only the second and third outbound-network
capabilities the app has ever shipped (after Sparkle), both off by default, both named by
file in PRIVACY.

## Compose-direct main path, watcher for the residual

App-written captures (nearly all volume) compose the final `.md` directly at their filing
seam — no root-`.txt` round-trip, no watcher involvement, no sync-visible churn, and the
attachment folder carries the note's name from the start. The `TriageWatcher` exists only
for the residual: hand-drops, sync deliveries from other devices, and the one-time backlog
of pre-triage files. That residual traffic tolerates poll latency (≤ 2 ticks), which is why
the watcher is the house `RelayWatcher` idiom (5s poll + pure planner) rather than FSEvents:
self-healing across folder relocation, no fd lifecycle, and proven `.icloud` placeholder
handling. The settle rule ignores mtime on purpose — sync engines preserve old mtimes.

The raw escape hatch drove a structural choice: `writeRaw`/`writeTriaged` (and
`fileRaw`/`fileTriaged`) are deliberately separate, partly duplicated functions. The raw
path had to stay byte-identical to v1.0.88, and entangling the paths to share a few lines
risks exactly the regression the escape hatch exists to prevent.

## Ledger pattern reuse

Every dedup/crash-safety problem in the feature got the same proven shape —
`RelayFiledLedger`'s TTL + capacity + pure static helpers, persisted in `state.json`:
`TriageLedger` (never double-triage), `SpoolFiledLedger` (crash-safe flush),
`HandoffLedger` (never double-book; dual fingerprints after M4; 48h window for dateless
items), `EnrichedLinkLedger` (never re-fetch). Filing order is always
file → ledger-record → delete-source, so every crash window is covered twice.

## Quiet failure; filing is never blocked

The governing posture across the opt-in tiers: **the note always files, deterministically
and immediately; everything on top fails open and quietly.**

- AI unavailability (offline, no model, bad key, refusal, timeout) → deterministic filing,
  no delay, no retroactive re-triage. Transport strikes cool the engine down (2 → 60s) so a
  dead network can't stall a backlog drain; one 401 latches the key as rejected instead of
  retrying per capture.
- Handoff failures surface only in Settings (`handoffLastError`), never the menu bar, never
  the filing. The filing path only ever *checks* EventKit authorization — the single place
  that *requests* it is the Settings toggle's enable flow.
- Enrichment is best-effort by contract: the link note is complete before enrichment
  starts; transport failures retry briefly (3 attempts), content failures (no captions,
  unextractable page) give up at once, and the only surface is a Settings error line.
- The model's output is never trusted raw: `AITriageValidator` is a mechanical gate
  (clause-containment against the raw text, length bounds on formatted bodies, impossible
  dates rejected), and a fully-invalidated AI handoff block falls back to the deterministic
  detector so a hallucinating model can't disable behavior the user already trusts.

The sibling posture for captures themselves is **never drop, never lie about location**:
when the destination's volume is unplugged, captures spool internally (FIFO-strict flush on
remount) and the app never creates a shadow folder on the boot volume; the offline reply is
the honest `✅ Queued — destination offline` rather than a false `✅ Saved`.

## Other load-bearing decisions

- **Relay defers in place; only iMessage spools.** The relay folder is already a durable,
  ledger-protected queue — copying it into the spool would duplicate machinery for nothing.
- **Today count increments at spool time** (the capture is durable and the confirmation
  fired); flush never re-counts.
- **AI sits inside the composers**, not the processors — they're the only places that hold
  the text and decide type/title/body, so everything lands in one atomic write;
  `WriteResult.ai` echoes the result out with zero writer-protocol churn.
- **Deterministic link detection runs before AI and wins** — link notes keep stable
  deterministic types/titles, which is what enrichment's rename and dedup key off.
- **Provenance beats AI:** relay-derived iPhone titles are kept over AI titles.
- **Conservative handoff bar, deterministically and for AI alike:** ambiguity means no
  handoff — the note just files. Misfiling is worse than not classifying ("null when
  unsure" is in the prompt).
- **Anthropic model is `claude-haiku-4-5`:** 4-way classification of short dictations is a
  small-cheap-model task, and it's the user's own key paying per capture.
- **A dedicated Settings "Triage" tab** consolidates everything post-arrival (mode, AI,
  handoff, enrichment); General keeps capture concerns.

## Deliberate scope cuts

Cut and documented in the PRD, still true after the build:

- **No user-editable rules engine / custom taxonomies** — the deterministic tier's behavior
  is fixed; the prompt file is the only tuning knob for AI.
- **No bulk re-triage** — triage happens once, at arrival; the first-enable backlog drain
  is the sole exception.
- **No X/Facebook/Instagram enrichment** — no reliable extractor exists; those links still
  classify and file, unenriched. No paywalled/JS-rendered pages, no media downloads, no AI
  summarization of fetched content.
- **No persisted enrichment queue and no backfill** — enrichment is in-memory and
  arrival-time only; a missed enrichment is a cosmetic loss on a note that is already
  complete.
- **No external-service actions** (email/Slack/SaaS) — the entire action surface is files +
  EventKit. No recurrence ("every Monday…" files as a note), no invitees/locations/alerts,
  no review-before-create step.
- **No multiple destinations** — the raw mode is a mode on the one destination, not a
  second destination. No attachment content extraction, no Mac-side audio transcription, no
  telemetry.

## Context

- **Visuals:** none.
- **References:** the frozen build-out snapshot in `_build_plan/triage-engine/` and the
  mirrored in-repo patterns — see `references.md`.
- **Product alignment:** `mission.md` and `CONTEXT.md` were updated by M5 as part of this
  build; this spec folder is the durable backport the PRD's own disclaimer demands.
