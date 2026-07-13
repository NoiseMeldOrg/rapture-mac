# Rapture for Mac — Triage Engine

> **About these build-plan files:** Everything in `_build_plan/triage-engine/` (this PRD and the per-milestone folders) is a **temporary guidance artifact** for the triage-engine build-out. These files are not functional — no code, configuration, runtime logic, tests, or deployment process should import, read, reference, or depend on anything inside them. Per this repo's convention (see root `CLAUDE.md`), the folder is **preserved afterward as a frozen historical snapshot**, not deleted — but durable decisions must be backported to `agent-os/product/*` and a dated `agent-os/specs/` folder before the build-out is considered done. The repo and its specs are the technical truth; this PRD is the milestone wrapper.

## What we're building

Rapture for Mac becomes the one triage path for every capture. The app already lands all captures — Siri-dictated iMessages plus notes from the Rapture iOS/Android apps — in its destination folder as raw `.txt`. Now the app itself makes sense of every capture **the moment it arrives**: it converts each one into structured Markdown with a YAML frontmatter capture contract, deterministically classifies and files it into subfolders, and (opt-in) hands reminders and appointments to Apple Reminders/Calendar via EventKit. No account, no scripts, no external automation — the interim launchd/Claude pipeline is gone, and this feature replaces it. Defaults work for a non-technical user with zero setup beyond picking a folder.

An advanced tier (free, off by default) adds AI triage — classification into task/idea/journal/link, smart titles, light body formatting — powered by Apple's on-device models when available (macOS 26+) or an optional bring-your-own Anthropic API key; and link enrichment that fetches YouTube transcripts and article text into sibling Markdown artifacts. A per-destination "raw .txt, no triage" escape hatch keeps power users unblocked.

Stack: Swift/SwiftUI menu-bar app, macOS 14+ deployment target, system frameworks only for all new work (no new third-party dependencies — GRDB + Sparkle remain the only ones). The build is structured as five milestones, each independently releasable via the existing Sparkle pipeline.

### Product-commitment reversal (deliberate, documented)

This feature knowingly reverses two commitments written into `agent-os/product/mission.md` and `CONTEXT.md`: *"no built-in AI/LLM integration"* and *"no in-app editing, tagging, or categorizing of captures."* The replacement stance: **output neutrality** — the folder remains the integration surface, and any AI or tool can read the triaged Markdown; what changes is that Rapture now does the first-pass processing itself. Link enrichment is also only the second outbound-network capability the app has ever shipped (after Sparkle). Milestone 5 updates `mission.md`, `CONTEXT.md`, `README.md` (including the "Network: zero outbound" badge), and `PRIVACY.md` (including its grep-verification instructions) coherently. Nothing about this reversal may land silently.

---

### What the app does

- You speak to Siri from across the room; seconds after the capture lands on the Mac, a clean Markdown note exists in the right subfolder of your destination.
- The destination root is an inbox: any new `.txt` that appears there — written by the app, arriving via iCloud/Dropbox sync from the mobile apps, or dropped in by hand — gets triaged within seconds. Files still being written or synced settle first; temp files are ignored.
- Every triaged note carries the capture contract: YAML frontmatter (`captured`, `source`, `type`, `raw_media`) and a body whose verbatim raw transcription is never discarded — if any formatting produced the body, the verbatim lives under `## Raw` in the same file.
- Bare or URL-dominant link captures are detected and typed (`youtube-link` vs `article-link`) and filed into `Links/`; everything else is a `voice-note` auto-titled from its first words and filed into `Notes/`.
- With Reminders/Calendar handoff enabled, a capture that clearly says "remind me…" creates a real Apple Reminder, and a stated appointment with date+time creates a real Calendar event — additively; the note still files. Re-dictating the same thing days later never double-books.
- On launch, any backlog of un-triaged captures drains oldest-first with progress shown in the menu bar — including the pile accumulated before this feature shipped.
- With AI triage on, notes route into `Tasks/`, `Ideas/`, `Journal/`, `Links/` with concise smart titles and lightly formatted bodies; when AI is unavailable, captures still file deterministically, immediately.
- With link enrichment on, YouTube links gain a transcript artifact and article links gain a readable-text artifact in `Links/Media/`, and the note is renamed to the real video/page title on arrival.
- The destination can live on an external volume (the reference case: an Obsidian vault on an external SSD). When the volume is unmounted, captures queue internally and flush in order on remount — never dropped, and never written to a shadow folder on the boot volume.
- Power users can flip the destination to "raw .txt" mode and get exactly today's v1.0.88 behavior back.

---

### Already provided by the existing codebase

The PRD does not re-spec any of this; the building agent reuses it:

- Two capture sources feeding one folder: `ChatDBWatcher` (iMessage, 1s SQL poll) and `RelayWatcher`/`RelayProcessor` (iOS relay, 5s snapshot poll with pure-planner idiom)
- Atomic write primitives (`AtomicFile`), filename collision walk (`FileWriter.uniqueDestination`), attachment sibling-folder conventions, guarded directory removal (`FileSafety.removeIfEmpty`)
- `CaptureGate` — the single serialization point around the output folder; pause/relocation deferral semantics both existing processors follow
- `Settings`/`PersistedState` lenient decoding (`decodeIfPresent ?? default`), `SettingsStore`/`StateStore` with injected-directory testability
- The ledger pattern (`EchoGuard`, `ContentDedupCache`, `RelayFiledLedger`): TTL + capacity + pure static helpers, persisted in `state.json`
- Settings window (General/Allowlist/Integrations/About) with the "iPhone App" section as the precedent for adding a feature section; menu-bar status, today count, last-error surfacing
- Permission onboarding flows (Full Disk Access sheet + polling; Automation pre-prompt)
- Output-folder machinery: default-folder initialization, `OutputFolderSidecar` (public path contract), `OutputFolderMigrator` (relocation with merge-never-clobber), `OutputFolderScaffold`
- Sparkle auto-update, notarized release pipeline (`/release-rapture-mac` ritual), commit-count versioning
- 279-test XCTest suite hosted in the app, with `isRunningXCTests` gating for launch-time side effects

---

### Out of scope

- **External-service actions** (email sending, Slack, GitHub, Google APIs, SaaS routing) — the app's entire action surface is writing files + EventKit handoff; "do this for me" notes still file legibly, acting on them stays human/agent territory.
- **Client tagging / per-client workspace routing** — a downstream-agent concept; notes mentioning clients file normally.
- **X/Facebook/Instagram enrichment** — no reliable extractor exists; these still classify and file as links, just without enrichment.
- **Attachment content extraction** (PDF/docx→Markdown, image descriptions) — attachments keep being copied alongside notes as today; converting their contents is a later release.
- **Audio transcription on the Mac** — the iOS app owns transcription; orphan `.m4a` handling stays as-is.
- **User-editable rules engine / custom taxonomies** — the deterministic tier's behavior is fixed; no rules UI this release.
- **Bulk re-triage** — no "re-run triage on old notes" button; triage happens once, at arrival (first-enable backlog catch-up is the sole, deliberate exception).
- **In-app note browsing/searching/editing** — the folder is still the UI.
- **Multiple destinations / per-type destinations** — one destination per install; the escape hatch is a mode on that destination, not a second one.
- **Cron/recurring-task automation** — "every Monday…" notes file as notes; no recurrence is created anywhere.
- **Triage analytics/telemetry** — none, matching the app's posture.
- Unchanged pre-existing exclusions: group chats, Mac App Store, cloud mode.

---

### External integrations

- **Apple on-device foundation models** (Apple Intelligence, macOS 26+) — powers AI triage privately and free; nothing leaves the Mac. No credentials. Deployment target stays macOS 14; the AI tier availability-gates at runtime.
- **Anthropic API (bring-your-own key, optional)** — the alternative/fallback AI engine for Macs without Apple Intelligence, or users who prefer it. The one credential in the entire product: an API key the user obtains from console.anthropic.com and pastes into Settings. Settings states plainly that note text is sent to Anthropic when this engine is active.
- **EventKit (system framework)** — Reminders/Calendar handoff. No credentials; proper TCC permission prompts with plain-language pre-prompts, requested only when the user enables a handoff toggle.
- **Plain web fetch (no service, no keys)** — link enrichment fetches article pages directly and YouTube transcripts via unofficial caption endpoints, explicitly best-effort. This is the app's second-ever outbound network capability (after Sparkle) and is off by default.

---

### Data model

What the app needs to remember. (This app has no database — "data" means file formats on disk plus the app's settings/state files.)

#### Triaged note (`.md` file in the destination)

- `captured` — when the capture originally happened, ISO 8601, from the capture's own timestamp
- `source` — which app captured it: `rapture-mac`, `rapture-ios`, or `rapture-android`; omitted when unknowable (e.g., a hand-dropped file)
- `type` — `voice-note`, `youtube-link`, or `article-link`; the AI tier may refine to `task`, `idea`, `journal`, or `link`
- `raw_media` — the URL, present only for link captures
- Body — the best available text; whenever the body differs from the verbatim capture (iOS AI formatting, Mac AI formatting/titling), the verbatim transcription is preserved under `## Raw` in the same file. Raw text is never discarded.
- Filename — `YYYY-MM-DD <Title>.md`; exact time lives in frontmatter; collisions get `-1`, `-2` suffixes
- Location — `Notes/` (voice-notes and fallback), `Links/` (link types); AI tier adds `Tasks/`, `Ideas/`, `Journal/`
- Attachments — the existing sibling folder follows its note (renamed to match), body references stay valid
- The original `.txt` is **deleted after the `.md` is durably written** — its full text lives inside the `.md`

#### Enrichment artifact (`.md` file in `Links/Media/`)

- Source URL, fetch date, and a pointer back to the capture note it belongs to
- Body — the fetched transcript or extracted article text (raw extract, no summarization)
- Relationship: each link note has zero or one enrichment artifact; a re-captured duplicate link points at the existing artifact instead of creating another

#### Settings (added to `settings.json`)

- Triage mode for the destination — full triage (default, including for existing installs after update) or raw `.txt` escape hatch
- Reminders handoff on/off (default off) + target Reminders list
- Calendar handoff on/off (default off) + target calendar
- AI triage on/off (default off); the Anthropic API key is remembered securely, not in plain text
- Link enrichment on/off (default off)

#### Triage ledger (state)

- Fingerprints of capture files already triaged, with timestamps — so restarts, iCloud re-syncs, and re-scans never double-process. Same TTL + capacity shape as the app's existing ledgers.

#### Destination spool (state + queued files)

- Captures held in the app's own support area while the destination is unavailable, with enough ordering information to flush oldest-first on remount. Hard guarantees: never drop a capture; never create a shadow folder on the boot volume when the destination's volume is merely unplugged.

#### Handoff ledger (state)

- Fingerprints (title + due/start time) of Reminders and Calendar events the app created — so a re-dictated duplicate days later doesn't double-book. Mirrors the external rulebook's calendar-log dedup rule.

---

## Milestone 1 — Triage Engine Core

The heart of the feature: captures become structured, filed Markdown the moment they land, with zero setup. Ships the out-of-box promise and drains the accumulated backlog on day one.

### What gets built

- On-arrival processing: any new `.txt` at the destination root (app-written, sync-delivered, or hand-dropped) is triaged within seconds; in-flight/temp files settle first; outputs and subfolders are never re-triaged (no loops)
- The Markdown capture contract exactly as specced in the data model, including the `## Raw` invariant and source detection (`rapture-mac` for iMessage captures, `rapture-ios`/`rapture-android` for relay arrivals)
- Deterministic triage: URL-dominant detection (YouTube forms vs other), first-words auto-titles, `YYYY-MM-DD <Title>.md` filenames with collision suffixes, filing into auto-created `Notes/` and `Links/`
- Original `.txt` deleted only after the `.md` is durably written; attachment sibling folders follow their note
- Backlog catch-up on launch and on first enable: oldest-first, menu-bar progress ("Triaging 55 notes…"), completion state
- Triage ledger preventing double-processing across restarts and sync re-deliveries
- Settings: triage on by default for everyone (fresh installs and updaters); the raw `.txt` escape-hatch mode restores exact pre-triage behavior for new arrivals; one-time "what's new" notice for updaters
- Menu bar: triage status line and last-error surfacing alongside existing capture status
- Triage respects pause and folder relocation exactly like the existing processors (defers, never drops)

### What milestone 1 explicitly does NOT include

- Reminders/Calendar handoff (M3), AI anything (M4), link fetching/enrichment (M5)
- Offline-destination spooling and external-volume handling (M2 — this milestone may assume the destination is available)
- The public docs story rewrite (M5) — changelog entry only
- Bulk conversion of existing filed notes when switching modes (mode changes affect new arrivals only)

### Done when

With triage on, sending a Siri self-iMessage and a Rapture iOS note each produces a correct `.md` (contract, title, folder) within seconds of arrival; launching the app with a pile of pending `.txt` files drains them oldest-first with visible progress; flipping to raw mode restores v1.0.88 behavior for new captures; the full test suite passes.

---

## Milestone 2 — Destination Resilience

Makes external-volume destinations first-class so the destination can be an Obsidian vault on an external SSD, and makes "never drop a capture" true even when the destination disappears.

### What gets built

- External-volume destinations work first-class (plain paths — the app is unsandboxed; no bookmarks needed)
- The app distinguishes "volume absent" from "folder missing" and never creates a shadow folder on the boot volume when a drive is merely unplugged
- Internal spool: while the destination is unavailable, captures from all sources (iMessage, relay, hand-drops already pending) queue in the app's support area
- Menu bar + Settings show destination state: online / "Destination offline — N captures queued"
- On remount, the spool flushes in original capture order and triage runs normally; today counts update correctly
- Folder relocation keeps working over the triaged tree (subfolders move with it)

### What milestone 2 explicitly does NOT include

- Multiple destinations or per-type destinations
- Sync-conflict resolution beyond atomic writes (Obsidian sync / remotely-save conflicts belong to the sync layer)
- A spool browser UI — status + count only

### Done when

With the destination set to a folder on an external drive: unplugging the drive and sending captures shows the offline status with an accurate queued count and writes nothing to the boot volume; replugging flushes everything in order into correctly triaged notes; the full test suite passes.

---

## Milestone 3 — Reminders & Calendar Handoff

The capability external automation never had: proper TCC-permissioned handoff of clear reminder/appointment captures to Apple Reminders and Calendar.

### What gets built

- Two independent Settings toggles (Reminders handoff, Calendar handoff), both off by default, each with a plain-language pre-prompt before the real macOS permission dialog
- Conservative deterministic detection: unambiguous "remind me to…" / "remember to…" / "don't forget…" phrasings create a Reminder (due date parsed when stated, relative to capture time); a stated appointment with date+time creates a Calendar event (1-hour default duration); past-dated appointments are skipped; ambiguity means no handoff — the note just files
- Handoff is additive: the note always files as `.md`; the created item carries the full original text in its notes field; an embedded clause inside a longer note creates the item and the note still files normally
- Target pickers: which Reminders list and which calendar receive handoffs (defaults: system defaults)
- Handoff ledger: re-dictating the same reminder/appointment within the ledger window doesn't double-create
- For iMessage-sourced captures, the existing `✓ Saved` reply gains a small suffix when a handoff fired; relay captures hand off silently

### What milestone 3 explicitly does NOT include

- Recurring items ("every Monday…" files as a note only), invitees, locations, custom alerts
- Editing/completing/undoing created items from the app
- A review-before-create step
- AI-improved detection (M4 sharpens this behind the same toggles)

### Done when

With Reminders handoff on, dictating "remind me to change the furnace filter Wednesday at 9am" yields a Reminder in the chosen list with the right due date plus a filed note; with Calendar handoff on, "appointment at Quest at 1:10 tomorrow" yields a 1-hour event; re-dictating either does not double-create; with both toggles off, captures file exactly as in M1; the full test suite passes.

---

## Milestone 4 — AI Triage

The advanced tier: on-device or BYO-key AI classification, smart titles, light formatting, and sharper handoff detection — never blocking, never required.

### What gets built

- One "AI triage" toggle (off by default); engine resolves automatically — Apple on-device models when available (macOS 26+ with Apple Intelligence), otherwise the Anthropic key if entered; Settings shows the active engine and why, with one honest privacy line per engine
- Anthropic API key entry in Settings, remembered securely
- Classification into task / idea / journal / link, routing to `Tasks/`, `Ideas/`, `Journal/`, `Links/`, with `Notes/` as the fallback for anything ambiguous; the `type` frontmatter carries the class
- Smart titles per the mined rulebook rules: concise imperatives for tasks, filler stripped, 3–10 words
- Light body formatting (punctuation, paragraphs) with the verbatim transcription preserved under `## Raw`
- Sharper handoff detection: AI catches reminder/appointment intent and dates the deterministic patterns miss — still strictly behind the M3 opt-in toggles and conservative bar
- AI unavailability (offline, no model, invalid key, errors) never blocks or delays filing — captures file deterministically, immediately; no retroactive re-triage

### What milestone 4 explicitly does NOT include

- Custom taxonomies, user-defined folders/classes, auto-tagging
- Summarization or body rewriting beyond the light-formatting scope
- Model-name pickers, temperature knobs, prompt editing
- Batch re-classification of already-filed notes
- Any licensing/entitlement gating — everything is free and opt-in

### Done when

With AI triage on, a rambling task dictation files into `Tasks/` with a concise imperative title, a lightly formatted body, and the verbatim under `## Raw`; the same capture with AI made unavailable files deterministically into `Notes/` with no delay; classification demonstrably works through both engines (on-device where available, Anthropic key otherwise); the full test suite passes.

---

## Milestone 5 — Link Enrichment & the New Story

Link captures become genuinely useful (transcripts and article text land next to the note), and the product's public story is rewritten honestly: capture → triage → your notes, no scripts required.

### What gets built

- "Link enrichment" toggle (off by default, independent of AI triage)
- YouTube transcript fetching (best-effort, no key) and article readable-text extraction from a plain fetch; artifacts saved to `Links/Media/` with frontmatter (source URL, fetch date, pointer to the capture note)
- Real titles: the note gets a one-time collision-safe rename to the fetched video/page title in the moments after arrival, and a link to the artifact is appended to the note body when the artifact lands
- Enrichment dedup by video ID / normalized URL: a re-captured link files a new note pointing at the existing artifact — no re-fetch
- Quiet failure posture: brief background retries, then silent give-up; the link note is always already filed and complete without enrichment
- The coordinated docs overhaul: README (story + "Network" badge + verification instructions), PRIVACY.md (what's fetched, when, and how to verify), `agent-os/product/mission.md` + `CONTEXT.md` commitment reversal (output neutrality replaces processing neutrality), reconciliation of `examples/` and the seeded scaffold template with the new built-in triage story

### What milestone 5 explicitly does NOT include

- X/Facebook/Instagram extraction, paywalled/login-gated content, JavaScript-rendered pages
- Downloading media files or thumbnails — text only
- AI summarization of fetched content — the artifact is the raw extract
- Backfill-enrichment of links filed before the toggle was turned on

### Done when

With enrichment on, a YouTube link capture yields a renamed note plus a transcript artifact in `Links/Media/`, and an article link yields a readable-text artifact; capturing the same video again files a note that points at the existing artifact without re-fetching; with enrichment off, no outbound requests occur beyond Sparkle; README/PRIVACY/mission/CONTEXT tell the new story coherently and their verification claims match the shipped binary; the full test suite passes.
