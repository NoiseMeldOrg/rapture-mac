# Changelog

All notable changes to Rapture for Mac are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the auto-generated git-commit-count scheme defined in `Scripts/set_git_version.sh` (`MAJOR.MINOR.COMMITS`); see [CONTRIBUTING.md](./CONTRIBUTING.md) for the full versioning logic.

## [Unreleased]

### Fixed

- **Calendar handoff could never be enabled in a released build.** The hardened runtime (required for notarization) denies EventKit calendar access unless the app is signed with the `com.apple.security.personal-information.calendars` entitlement — the request failed instantly with no macOS permission dialog, and Rapture never appeared in System Settings › Privacy & Security › Calendars. Both EventKit entitlements (calendars + reminders) are now declared. Reminders handoff was unaffected. Surfaced by the v1.0.98 release dogfood: unit tests fake the EventKit client and the M3 debug-build checks never exercised a Developer ID-signed calendar request, so the gap was invisible until now.

### Changed

- The Anthropic key caption in Settings → Triage now says to create a *new* key at console.anthropic.com (existing keys are shown only once, at creation — there's no way to re-copy one).

### Internal

- **CI green again: `LinkEnrichmentServiceTests` was timezone-dependent.** The fixture's capture instant (2026-07-14T03:33Z) crossed midnight UTC, so artifact filenames — which use the capture's *local* calendar day — came out `2026-07-14 …` on the UTC CI runner against hardcoded `2026-07-13 …` expectations (six failures on every push since M5; invisible locally in Eastern time). The fixture now pins midday UTC, day-stable from UTC-11 to UTC+11. Reproduced and verified with `TEST_RUNNER_TZ=UTC`.

### Fixed

- **Stale pre-triage copy in the UI.** Four strings still described the old `.txt` world (surfaced by the v1.0.98 release dogfood): the About tab's tagline ("landing as `.txt` files") and the Full Disk Access onboarding now say notes, not `.txt` files; the starter-scaffold caption no longer promises `processed/`/`in-progress/` folders (the scaffold seeds only `CLAUDE.md` since the M5 template rewrite); and the Triage tab's filing caption now mentions `Tasks/`/`Ideas/`/`Journal/` alongside `Notes/`/`Links/` when AI triage is on.

## [1.0.98] - 2026-07-14: Built-in triage engine

Built from commit `940c393`. SHA-256: `ad7cf2bba47fcedd2d08ecc0d2040e8ff75d9625f2c50cf2b046ff0bb103ae60`.

The app now makes sense of every capture the moment it arrives: Markdown notes classified into folders, deterministic by default, with opt-in AI refinement (on-device or your own Anthropic key), opt-in Reminders/Calendar handoff, opt-in link enrichment (YouTube transcripts and article extracts), and first-class external-drive destinations that queue captures while the drive is unplugged. Everything here is the triage-engine build-out (five milestones, 2026-07-13), riding on 727 tests.

### Added

- **External-drive destinations are now first-class — captures queue while the drive is unplugged.** Point your notes folder at an external volume (say, an Obsidian vault on an SSD) and unplug it: nothing is lost and nothing lands in the wrong place. The app now tells a **disconnected volume** apart from a merely **missing folder** — a missing folder on a mounted volume is created as always, but when the volume itself is absent no write goes anywhere near it (previously, writing toward an unplugged drive could silently create a same-named shadow folder on the boot volume under `/Volumes` and strand captures inside it, hidden the moment the real drive remounted). While the destination is offline: Siri iMessage captures queue durably in an internal spool inside the app's own data container, iPhone-app relay notes simply wait in the iCloud relay folder, and the menu bar + Settings show **"Destination offline — N queued."** The iMessage confirmation says so honestly: `✅ Queued — destination offline` (the note is safe, just not in the vault yet). On reconnect everything files automatically within seconds, in original capture order, with the capture's true timestamp and source in the note header — a note flushed hours late is indistinguishable from one written live. The flush is duplicate-safe across restarts and crashes (a persisted spool ledger in `state.json`), and relocating the notes folder *to* a disconnected drive is refused up front instead of creating that same shadow folder.
- **Built-in triage: captures now file as Markdown notes.** Every capture (iMessage and Rapture iPhone app) becomes a Markdown note with a small YAML header — `captured` (the UTC instant), `source` (`rapture-mac` / `rapture-ios`), `type` (`voice-note` / `youtube-link` / `article-link`), and `raw_media` (the URL, for link captures) — written once, directly into a classified subfolder: bare links into `Links/`, everything else into `Notes/`. Filenames are human: the local capture date plus a title from the first words (`2026-07-13 Rent is due on the 5th.md`); relay notes keep the title the iPhone derived. Classification is deterministic string-matching — **no AI, no network, nothing leaves your Mac** — and the verbatim transcription is never discarded. Attachments keep the sibling-folder convention with the footer upgraded to Markdown links.
- **The folder root is now an inbox.** Any `.txt` that appears at the root of your notes folder — hand-dropped, delivered by a sync engine from another device, or left over from before this release — is converted the same way within seconds. The accumulated backlog drains automatically on launch, oldest first, with progress in the menu bar. Conversion is duplicate-safe across restarts and iCloud re-syncs (a persisted triage ledger in `state.json`), and the original `.txt` is deleted only after its full content is durably inside the new note — if the note is later deleted and the `.txt` re-dropped, it re-triages instead of being drained.
- **Raw mode escape hatch.** Prefer the old behavior? **Settings → Triage → "Raw text files, no triage"** restores exact pre-triage filing (timestamped `.txt` at the root, no subfolders, nothing converted) for new arrivals. Triage is on by default for everyone, including updaters — a one-time menu-bar notice explains the change and points anyone running their own scripts against raw `.txt` files at the escape hatch.
- **Reminders & Calendar handoff (opt-in).** Two new toggles in **Settings → General → Reminders & Calendar**, both off by default. With Reminders handoff on, a capture that clearly says "remind me to…" / "remember to…" / "don't forget…" / "make sure to…" *also* creates an Apple Reminder — due date parsed when stated ("Wednesday at 9am", "tomorrow", "July 20"), dateless otherwise — in the Reminders list you pick (or the system default). With Calendar handoff on, a stated appointment with a date **and** time ("appointment at Quest at 1:10 tomorrow", "meeting with Sam Monday at 2") becomes a 1-hour calendar event; appointments already in the past are skipped. Handoff is strictly **additive**: the note always files exactly as before, the created item carries the full original dictation in its notes field, and anything ambiguous just files — no handoff, no guessing. Dates read relative to **when the note was dictated**, not when it files, so a backlog note captured Friday saying "tomorrow" means Saturday even if it triages Monday, and a capture queued while your external drive was unplugged hands off exactly once, at flush. Re-dictating the same reminder or appointment doesn't double-create (a persisted handoff ledger in `state.json` fingerprints title + due/start time). iMessage captures get a small reply suffix when a handoff fired (`✅ Saved · Reminder created`); iPhone-app relay notes hand off silently. Each toggle explains itself before the real macOS permission dialog appears, and the permissions are requested **only** from those toggles — never at launch. Detection is deterministic string-matching, on-device, no AI, no network.
- **Late relay audio now lands next to its note.** When a relay note files text-only (audio still syncing) and the `.m4a` arrives minutes later, the orphan-audio recovery now places it in that note's own attachment folder instead of a disconnected folder at the root, using the triage ledger's record of where the note landed.
- **AI triage (opt-in, off by default).** One toggle in the new **Settings → Triage** tab. With it on, voice-note captures are classified into **`Tasks/`, `Ideas/`, `Journal/`** (with `Notes/` still the fallback for anything ambiguous), given a concise 3–10-word title (imperative for tasks, dictation filler stripped), and lightly cleaned up (punctuation, paragraphs) — with the **verbatim transcription always preserved in the same note under `## Raw`**. The engine resolves automatically: **Apple Intelligence on-device** when this Mac supports it (macOS 26+, nothing leaves the machine), otherwise **your own Anthropic API key** (`claude-haiku-4-5`; the key is stored in the macOS Keychain, never in a settings file, and Settings shows exactly which engine is active with an honest privacy line for each). AI also sharpens Reminders/Calendar handoff detection — phrasings the deterministic patterns miss now hand off, still strictly behind the same two opt-in toggles, the same conservative bar, and a beefed-up dedup (title *and* verbatim-clause fingerprints) that prevents double-creates even across AI/non-AI re-dictations of the same utterance. **AI never blocks or delays filing**: if it's off, unavailable, offline, erroring, or slow (10-second hard cap, with a cooldown after repeated network failures so a dead connection never stalls a backlog drain), every capture files deterministically and instantly, exactly as before — link captures always stay deterministic (`Links/`), raw mode never consults AI, and nothing is ever re-triaged retroactively.
- **New "Triage" Settings tab.** Filing mode, AI triage, link enrichment, and Reminders & Calendar handoff now live together in their own tab (they were outgrowing General; General keeps folder, launch-at-login, replies, SMS, and iPhone-app settings).
- **Link enrichment (opt-in, off by default).** One toggle in **Settings → Triage → Link Enrichment**, independent of AI triage. With it on, a captured YouTube link gets its **transcript** fetched and an article link its **readable text**, saved as a Markdown artifact in **`Links/Media/`** (source URL, fetch date, and a pointer back to the note in its header) — and the note itself is **renamed to the real video or page title** with a `Media:` link to the artifact appended. Capturing the same video or article again files a new note that points at the existing artifact without re-fetching (dedup by YouTube video ID / normalized URL, tracking params ignored). Fetching is plain HTTP with no keys and no AI — only the URL is ever sent, never note text — and it is **best-effort by design**: no captions, a paywall, or a dead network means a few quiet retries and then the note simply stays as filed, complete without the artifact. Renames are collision-safe, keep attachment folders and their links paired, and never race a capture being filed.

### Changed

- **Folder relocation no longer preserves colliding `.md` files silently.** Only `CLAUDE.md` keeps its kept-on-collision special case; ordinary `.md` files are notes now, so a collision during relocation disambiguates with a `-1` suffix like any note — nothing gets stranded in the old folder.
- README and PRIVACY updated to describe the Markdown output, the deterministic-by-default triage posture, and the raw-mode escape hatch.
- **PRIVACY/README truth patch for the BYO-key engine.** The BYO-key Anthropic engine is the app's first user-facing outbound network capability beyond the Sparkle updater, so the docs say so plainly before it ships: PRIVACY gains an "AI triage" section (per-engine data flow, the Keychain-only key, the 6,000-character input cap, the never-blocks-filing guarantee), its grep-verification instructions now name `TriageAI/AnthropicEngine.swift` + `TriageAI/AnthropicWire.swift` as the only `URLSession` matches in the app, and the README's "network: zero outbound" badge became "network: opt-in only". The full narrative overhaul lands with milestone 5.
- **The docs now tell the whole story honestly.** PRIVACY enumerates all **three** outbound network capabilities (Sparkle updates opt-out; BYO-key AI and link enrichment opt-in) with a "Link enrichment" section and an updated grep claim naming every networking file (`TriageAI/AnthropicEngine.swift`, `TriageAI/AnthropicWire.swift`, `Enrichment/URLSessionLinkFetcher.swift`). SECURITY.md's stale "zero outbound network calls" supply-chain section was rewritten to match the shipped binary. The README's story is now capture → built-in triage → your notes. The product mission formally records the 2026-07 commitment reversal — **output neutrality** (any AI can read the triaged Markdown) replaces the old "no built-in AI / no in-app categorizing" stance — with the rationale in a new dated spec folder, `agent-os/specs/2026-07-13-2230-triage-engine/`. The `examples/` integrations and the opt-in starter `CLAUDE.md` scaffold were rewritten for consuming the triaged Markdown tree instead of raw root `.txt` files (raw mode keeps the old contract, and the examples say so).

### Fixed

- **Folder relocation keeps a renamed note and its attachments together.** When relocation hits a name collision, a note and its sibling attachment folder now rename in lockstep (`X.md` + `X/` → `X-1.md` + `X-1/`) and the note's attachment links are rewritten to match — previously the note renamed but its attachment folder merged into the *other* same-named note's folder, cross-wiring the two notes' attachments. The triage ledger's record of where each note lives now follows collision renames too, so duplicate protection and late relay audio keep working after a move. Also fixed: a colliding *folder* whose name contains periods disambiguates correctly (`Notes v1.2` → `Notes v1.2-1`, not `Notes v1-1.2`).

### Internal

- **Tests isolated from the dev machine's live data container.** `SettingsStore`, `StateStore`, and `AppState` accept an injected support directory; `RelayProcessorTests` now runs against per-test temp directories instead of the real (debug-container) `state.json`. Surfaced by the rapture-mac-destination end-to-end dogfood (2026-07-06): the first real relay filings landed in `relayFiledRecords` and broke a ledger-emptiness assertion — the old snapshot/restore protected dev state from the tests, but not the tests from dev state. Test infrastructure only; no behavior change.
- The triage engine follows the house patterns end to end: a `RelayWatcher`-style 5s poll + pure scan planner on the destination root (root-only, files-only, `.txt`-only — triage outputs can never be re-selected), per-file capture-gate acquisition so a big backlog drain interleaves with live captures, `RelayProcessor`-style failure backoff and oversize caps, and a `TriagedEntry` ledger (TTL 90d, cap 500) with lenient decode. 98 new tests; suite at 377, 0 host restarts.
- Reminders/Calendar handoff follows the house patterns: a pure table-tested detector and a hand-rolled date parser (`NSDataDetector` can't anchor "tomorrow" to a past reference date, which backlog and spool-flush correctness require); a `HandoffLedger` (TTL 90d / cap 500, with a 48-hour window for dateless reminders so a genuinely repeated chore re-dictated next week still creates); EventKit behind an injected protocol — `SystemEventKitClient` is the only file importing EventKit, lazily constructed and XCTest-gated, so the suite runs with zero TCC grants; and the handoff fires at all four filing seams (live iMessage write, relay filing, spool flush, backlog triage) — never on spool-enqueue, write failures, or ledger-hit crash-resume paths. 99 new tests; suite at 551.
- Destination resilience follows the same patterns: a pure, probe-injectable `DestinationGuard` (volume-absent vs folder-missing, with `URLResourceKey.isVolume` unmasking leftover shadow folders) consulted synchronously inside the capture gate at every write seam; a scan-based spool (`Application Support/<container>/Spool/`, one self-describing directory per item, staging-dir + rename commit, monotonic persisted seq) flushed FIFO-strict by a 2s `DestinationMonitor` poll under the capture gate; and a `SpoolFiledLedger` closing the file-vs-remove crash window exactly like the relay's. Live-verified against an `hdiutil`-attached APFS volume (attach → capture → detach → queue → reattach → ordered flush). 75 new tests; suite at 452.
- AI triage follows the house patterns too: one `AITriageService` shared across all four composers (`FileWriter`, `RelayFiler`, `SpoolFlusher`, `TriageProcessor`), consulted just before compose so classification/title/body land in the note's single atomic write; a pure mechanical `AITriageValidator` between engine drafts and trusted output (fabricated handoff clauses rejected by containment check, impossible dates rejected instead of rolled, bodies outside ±50% of the raw length discarded); engines behind an injected protocol — `AppleFoundationEngine` is the only file importing FoundationModels (weak-linked; deployment target stays macOS 14) and `AnthropicEngine`/`AnthropicWire` the only networking in the app, both XCTest-gated so the suite touches neither model nor network; the app's first credential in a `KeychainStore` generic-password item (DEBUG builds use an isolated keychain service, mirroring the container isolation); and dual handoff-ledger fingerprints (mechanical title + verbatim clause) closing the AI-title-drift dedup gap flagged in the M3 log. 91 new tests; suite at 642.

## [1.0.88] - 2026-07-06: Rapture iPhone app capture source

Built from commit `7b3fc02`. SHA-256: `6814354498b32a665e03a2a029c432002661e40c1a70a3dda7ab00167df95ad7`.

The Mac half of the Rapture Mac destination: notes captured in the Rapture iOS app now deliver themselves to your Mac through your own iCloud, with no pairing, no server, and no new networking in this app.

### Added

- **Second capture source: notes sent from the Rapture iPhone app.** Rapture now watches the iCloud relay folder the Rapture iOS app delivers into (`~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay/`) and files each arrival into your notes folder with the same naming, collision, and attachment conventions as iMessage captures. Voice-note audio (`.m4a`) lands in the standard attachments sibling folder with the usual `Attachments:` footer; the note text itself is filed verbatim. Relay copies are removed after successful filing, filing is duplicate-safe across app restarts and iCloud re-syncs (a persisted filed-ledger in `state.json`), catch-up after sleep is automatic, and arrivals count into the menu-bar today count. Pause defers relay filing exactly like iMessage capture. A new **Settings → General → "iPhone App"** section has the on/off toggle (on by default), a plain-language status line (folder found, waiting for iCloud downloads), and the last filing error. This source needs **no Full Disk Access** and adds **zero networking** — the watcher reads a local folder that macOS syncs, and the [PRIVACY.md](./PRIVACY.md) grep claim (`URLSession|URLRequest|NWConnection|NWListener` → zero results outside Sparkle) was re-verified. Enable the "Rapture Mac" destination in the iOS app to start delivering; until then the watcher is a silent no-op.

### Internal

- Debug builds watch a separate `Relay (Debug)/` folder (and keep their isolated data containers), so a development build can never race the installed app over real relay files.
- 34 new tests covering the scan planner (pairing grace, iCloud placeholder handling, orphan-audio recovery), the filed-ledger dedup, verbatim filing + collisions, processor crash-window ordering (file → record → delete), failure backoff, and settings/state decode round-trips. Suite at 279 tests.

## [1.0.80] - 2026-06-27: In-app auto-update (Sparkle)

Built from commit `b1c03a7`. SHA-256: `138cd6daaa2c17dedc36ecca172cb012497c7e545eff25e3bac9835b5a5af449`.

Rapture's first self-updating release. From here on it checks GitHub for new versions and installs them in place — but **this one must be installed manually** (your current version has no updater yet). The release also folds in the test-suite/CI stabilization and the release-pipeline signing fixes that bringing Sparkle live surfaced.

### Added

- **In-app automatic updates (Sparkle).** Rapture can now check for, download, and install new releases itself instead of you re-downloading the DMG by hand. Background checks are on by default and prompt you when a new version exists; there's also a "Check for Updates…" item in the menu and an "Automatically check for updates" toggle in Settings → About. Updates are fetched from GitHub, verified against an EdDSA signature **and** Apple's notarization before installing, and the updater sends no usage data (anonymous system-profiling is disabled). This is the app's first and only networking — see the rewritten [PRIVACY.md](./PRIVACY.md). **Note:** this update itself must be installed manually (your current version has no updater yet); every release after it updates in place.

### Changed

- **Release DMGs now staple the `.app`, not just the DMG.** `Scripts/release.sh` notarizes and staples the app *before* packaging it (then notarizes + staples the DMG as before), so the installed app carries its own notarization ticket and **first launch succeeds even with no network**. Previously only the DMG was stapled, leaving the app to rely on an online Gatekeeper check at first launch.

### Internal

- **Release pipeline now re-signs Sparkle's nested helpers.** The first Sparkle-enabled build was rejected by Apple's notary: Sparkle ships `Updater.app`, `Autoupdate`, and the Downloader/Installer XPC services ad-hoc-signed, and Xcode embeds the framework without re-signing that nested code (so they reach the notary with no Developer ID and no secure timestamp — `codesign --verify --deep` passes locally because it checks neither). `Scripts/release.sh` Stage 3b now re-signs them inside-out with the Developer ID identity + hardened runtime + a secure timestamp before notarization. The `release-rapture-mac` skill + CONTRIBUTING also now require `sign_update` on a stable `PATH` (not `/tmp`) before cutting, so the appcast step can't silently skip.
- **Fixed flaky `IntegrationRunnerTests` that reddened CI.** Three subprocess/test-host problems, surfaced once Sparkle's EdDSA key made the updater live and the suite was stress-run: (1) `IntegrationRunner.runScript` no longer calls `process.waitUntilExit()` on a GCD worker thread — that spins a runloop the termination event is never delivered to, so ~1 spawn in ~120 hung for the full test-timeout; the exit code now comes from the `terminationHandler`, which Foundation fires reliably. (2) Output capture drains both pipes to EOF via a `DispatchGroup` (independent full reads) instead of racing a `readabilityHandler` against the `terminationHandler`, which could drop captured output on a loaded machine. (3) The app's launch-time machinery no longer runs inside the XCTest host: the test bundle is hosted in `Rapture.app`, so `@main` startup runs during `xcodebuild test` — and opening `chat.db` there raised a Full Disk Access prompt that intermittently killed the host (`Restarting after unexpected exit`). `Pipeline.start()`, `LoginShellPath.capture()`, and `UpdaterController` are now gated behind `ProcessInfo.isRunningXCTests` (`RuntimeEnvironment.swift`). No production behavior changes — only the subprocess plumbing and test host are affected.
- **Continuous integration**: every PR and push to `main` now builds and runs the full XCTest suite on a macOS GitHub Actions runner (`.github/workflows/ci.yml`).
- **Fixed `Scripts/*.sh` to be executable in git** (they were stored `100644`), so the Xcode build phases that run them work on a clean checkout — not just where the working copy happened to carry the bit. Caught by the new CI.

## [1.0.71] - 2026-06-26: Output-folder data-safety hardening

Built from commit `d6bfb8b`. SHA-256: `9d2645c7740e9a67845f711aff313983b357351aea2b55553d2071cfa41dd3ce`.

Originated from an incident report — a notes folder lost its `CLAUDE.md` + `processed/` + `in-progress/` scaffold and came back bare. Investigation cleared the shipped relocate feature: every folder create/delete/move path is non-destructive and the relocate is fail-safe. The real cause was a manual relocate-test session in which debug and release builds **shared one Application Support container**, forcing a hand-edit of the production `settings.json` that deleted the real folder as collateral. This release isolates debug builds, makes destructive deletion unreachable by construction, adds an opt-in scaffold, and proves the invariants. See [`agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/`](./agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/).

### Added

- **Opt-in starter scaffold for empty folders.** A new Settings → General toggle ("Seed a starter scaffold in empty folders", off by default) seeds a generic template `CLAUDE.md` plus empty `processed/` and `in-progress/` folders into an output folder **only when it's empty and has no `CLAUDE.md`**. So a brand-new folder — or one that came back empty — returns usable instead of bare, without ever touching a folder you already curate. Implemented in `OutputFolderScaffold` (strictly idempotent and non-destructive: the eligibility check is empty-AND-no-`CLAUDE.md`, the template carries no user-specific repo paths), wired into first-launch default init, post-relocate into an empty folder, and the toggle itself.

### Changed

- **DEBUG builds now use isolated data containers (developer-facing).** Debug builds read and write `~/Library/Application Support/Rapture for Mac (Debug)/` (their own `settings.json`/`state.json`/sidecar) and default to `~/Documents/Rapture Notes (Debug)/`, so development and manual relocate-testing can never read, write, or move the installed app's real settings or notes. A "(Debug)" marker in the Settings window title and a banner in General make the active build obvious. This is the **root-cause fix** for a 2026-06-22 incident in which a real notes folder lost its `CLAUDE.md`/`processed/`/`in-progress/` scaffold: the shipped relocate feature was *not* at fault — investigation confirmed every folder create/delete/move path is non-destructive and the relocate is fail-safe — but a manual test session, forced to hand-edit the *shared* production `settings.json`, deleted the real folder as collateral, after which a captured note recreated it bare via create-if-absent. Release builds are unchanged.

### Fixed

- **Hardened the folder-safety invariants so destructive deletion is unreachable by construction.** Directory removal is now funneled through a single guarded primitive, `FileSafety.removeIfEmpty`, which removes a directory **only** when it lists empty (dotfiles counted) and is otherwise a logged no-op. Both the migrator's source-cleanup and the writer's failed-attachment-folder cleanup route through it, so no code path can delete a directory that still holds data. Also fixed a latent upgrade risk: `Settings` now decodes leniently (`decodeIfPresent`), so adding the `seedScaffold` field can't fail to load a pre-existing `settings.json` and silently reset your output folder.

### Tests

- 214 → 234 (+20). New: `FileSafetyTests` (7 — empty-only removal, refuses non-empty incl. dotfile-only, no-op on missing/file), `OutputFolderScaffoldTests` (6 — seeds only empty+no-`CLAUDE.md`, idempotent, generic template), `OutputFolderSafetyTests` (5 — writer create-if-absent preserves existing contents, missing source never clobbers destination, `seedScaffold` Codable forward/backward compat), and `AppStateRelocationTests` (2 — failed relocate leaves the active folder *and* sidecar unchanged; same-folder no-op). All 234 pass in ~2.6s.

## [1.0.69] - 2026-06-22: Auto-relocating output folder

Built from commit `590b0c2`. SHA-256: `3aff7f97e88f76c64230389c393959052f01fd6705c62376bfffd19eda40100d`.

### Added

- **Changing the Output Folder now moves your existing notes (Dropbox-style).** Previously, picking a new folder in Settings → General only re-pointed where *new* captures landed — your existing notes were stranded in the old folder. Now the whole notes tree (including subfolders, dotfiles, `processed/`, attachment folders, and `CLAUDE.md`/routing files) moves to the new folder automatically, then the app switches to it. It's silent on success; only failures surface. All folder changes route through a single `AppState.setOutputFolder` path (`pickFolder`, drag-and-drop, and any future programmatic change), backed by a new `OutputFolderMigrator` service. Data-safety is the governing constraint: same-volume changes use an atomic per-item rename; cross-volume changes (e.g. internal disk → external `/Volumes/...`) **copy → verify → then delete** the source, never deleting before the destination is verified; collisions merge rather than clobber (`.md` config/routing files keep the destination copy, notes and everything else are disambiguated with a `<base>-<n>` suffix); and any failure leaves the source intact and the active folder unchanged. The capture pipeline is quiesced during the move via a new `CaptureGate` async mutex (the whole batch and the whole move are mutually exclusive), plus a transient `isRelocating` flag that defers new batches so they replay into the *new* folder. Degenerate cases are guarded: no-op when unchanged, refusal when the new folder is nested inside the old (or vice versa), unwritable destination, missing source, and insufficient cross-volume space.
- **`output-folder.path` sidecar is now actually written.** The documented downstream-consumer contract at `~/Library/Application Support/Rapture for Mac/output-folder.path` was previously described but never implemented. `OutputFolderSidecar` now writes the resolved absolute path atomically on every output-folder change and on first-launch default initialization, so the Claude Code SessionStart hook, OpenClaw / Hermes skills, and custom scripts can track folder changes without reading `settings.json`.

### Fixed

- **iCloud cross-device replays no longer become duplicate captures.** The v1.0.29 GUID dedup only collapses identical-`message.guid` deliveries, but iCloud sync delivers the same Siri-dictated note to chat.db with a **fresh GUID and a 1–2 s timestamp offset** each time, so each delivery produced a new file plus a "Saved" reply. The reporting user was seeing 3–4 duplicate confirmations per dictation and a daily 15:16 EDT cluster of replays (root cause: a scheduled Calendar travel-time wake event reconnecting iMessage iCloud and dumping queued duplicates). A new `ContentDedupCache` keyed on `(normalized self-handle, normalized text, attachment count)` with a 7-day TTL and 500-entry FIFO cap now sits between the echo guard and the file writer in `BatchProcessor`, dropping replays silently and persisting across app restarts via `state.json`.

### Changed

- **Per-message reply is now `✅ Saved`** (was `✓ Saved: <filename>.txt`). The filename wasn't actionable on a phone and the short form is easier to glance at. The new `MessageFilter.looksLikeAppConfirmation` matches both the new and the legacy forms so pre-upgrade replays still get suppressed.
- **Catch-up summary is now `📥 Caught up: N notes`** (was `📥 Caught up: N notes captured`). "Caught up" already implies "captured."

### Removed

- **Autonomous launchd watcher (`com.user.rapture-notes-watch`) and its supporting infrastructure.** The Integrations panel v1.0.64 shipped two ways for Claude Code to consume the notes folder — a SessionStart hook (opportunistic) and an autonomous fswatch-driven `claude -p` worker registered with launchd (always-on). The autonomous worker turned out to be the wrong shape for the work: `claude -p` is non-interactive by design, so it required `--permission-mode bypassPermissions`, `< /dev/null` stdin tricks, and (on the next iteration) a `timeout` wrapper to prevent hangs. The worker also couldn't `lstat` files on external volumes because the launchd context inherits a TCC profile distinct from the user's terminal — which would have required granting Full Disk Access to `/bin/bash` and `/opt/homebrew/bin/claude`. On 2026-06-04 we discovered the worker had been silently broken for two days (one `claude -p` invocation hung, the script's for-loop blocked, three orphan bash processes were racing on the same fswatch stream, zero processing happened), and elected to remove the layer entirely rather than fix it. The SessionStart hook covers the same need with the right shape of tool: Claude Code running interactively, inheriting your terminal's TCC, prompting for permissions when needed. See [`agent-os/specs/2026-06-04-1530-remove-autonomous-watcher/`](./agent-os/specs/2026-06-04-1530-remove-autonomous-watcher/) for the full rationale. Removed: `Scripts/install-claude-watch.sh`, `Scripts/uninstall-claude-watch.sh`, `Scripts/{start,stop,restart}-watch.sh`, `examples/claude-code/autonomous.md`, `examples/watch.env.example`, `RaptureMac/Integrations/WatcherConfigStore.swift`, and the watcher-specific branches of `StatusParser` / `IntegrationDiscovery.StatusKey` / `SettingsIntegrationsView`. The Integrations panel UI stays; the Claude Code card now shows one install option (SessionStart hook) instead of two.

### Tests

227 → 214 (net since last release: +16 new `ContentDedupCacheTests`, −54 watcher-only tests across `WatcherConfigStoreTests` whole plus trimmed watcher cases in `StatusPillResolutionTests`, `StatusParserTests`, `PrerequisitesTests`, `IntegrationDiscoveryTests`, then +9 new `OutputFolderMigratorTests` covering same-volume move, cross-volume copy-verify-delete, merge-with-collisions, no-op, nested-path guards, failure-leaves-source-intact, and URL/sidecar persistence). All 214 pass in ~0.5s.

## [1.0.64] - 2026-06-02: Integrations panel + rename

Built from commit `ae224e9`. SHA-256: `d35db2bf8edc8165335d0a14de5a06a119d116e81e8f97e4c1a38819f727b3e5`.

### Added

- **Integrations panel** in Settings: install, configure, and monitor downstream Rapture consumers from inside the app — no Terminal required. The new tab discovers consumers dynamically from `examples/` at runtime, so dropping a new `examples/<name>/` folder (with an optional `manifest.json`) adds a card without a code change. Ships with cards for Claude Code (SessionStart hook + autonomous watcher, with workdir picker, model overrides, start/stop/restart controls, and a `Grant Reminders…` deep-link) and informational cards for OpenClaw, Hermes, and the Generic CLI. `Scripts/` and `examples/` are bundled as Resources so install scripts run from inside the signed app — no runtime fetch from GitHub, in line with PRIVACY.md's zero-outbound commitment. See [`agent-os/specs/2026-05-31-2030-integrations-panel/`](./agent-os/specs/2026-05-31-2030-integrations-panel/) for the design notes.
- `examples/manifest-schema.md` documenting the optional `manifest.json` schema for `examples/<name>/`. Four matching manifests authored for the existing example folders.
- `examples/` directory with starter configs for consuming the notes folder from Claude Code, OpenClaw, Hermes Agent, and a vendor-neutral shell pipeline. README points at it from a new "Using your captures" section. Configs are written from current agent documentation, not tested against a running install; issues and PRs welcome.
- **Watcher control scripts:** `Scripts/start-watch.sh`, `Scripts/stop-watch.sh`, `Scripts/restart-watch.sh` — load / unload / restart the launchd agent without hand-running `launchctl`. They prefer the modern `bootstrap`/`bootout`/`kickstart` API with a fallback to legacy `load`/`unload`. `status.sh` now lists them. Use `restart-watch.sh` after editing the worker or plist.
- **Optional config file** (`examples/watch.env.example` → `~/.config/rapture-mac/watch.env`): `KEY=VALUE` overrides for the two models, notes folder, workdir, and claude binary. The installer writes them into the launchd plist as `EnvironmentVariables`, so they persist across reboots and reinstalls instead of being hardcoded in the generated worker.

### Changed

- **App renamed to just "Rapture".** `Rapture.app` (was `RaptureMac.app`); window titles, Dock, Spotlight, Raycast, About box, and FDA/Automation instructions all updated. **Bundle ID stays `noisemeld.RaptureMac`** so TCC grants (FDA + Automation) survive the upgrade. **Application Support folder stays `~/Library/Application Support/Rapture for Mac/`** so existing settings + state persist. After upgrading, `/Applications/RaptureMac.app` and `/Applications/Rapture.app` will coexist until you delete the old bundle by hand.
- **Per-note model split in the event-driven watcher.** The generated worker now picks the model per note: notes containing a URL or an attachment run on a stronger model (`RAPTURE_MEDIA_MODEL`, default `sonnet`) so they can drive an extraction skill end-to-end; plain text/reminder notes stay on the cheap default (`RAPTURE_TEXT_MODEL`, default `haiku`). Detection is a deterministic `grep`, so model choice never itself depends on a model. Previously every note ran on Haiku, which was too weak to reliably run a media-extraction skill — links were filed but never extracted.
- **Worker prompt + example routing rules now insist on explicit skill invocation and shell `>>` appends.** With many skills installed, a small model won't reliably auto-trigger the right extraction skill from its description, and rewriting a shared list file (instead of appending) clobbered earlier entries. Both failure modes are now called out in the generated prompt and the `examples/claude-code/CLAUDE.md` starter.

### Tests

111 → 227 (+116 new): 30 IntegrationDiscovery, 24 StatusParser, 25 WatcherConfigStore, 14 IntegrationRunner, 12 Prerequisites, 11 StatusPillResolution. All run in ~0.3 s.

## [1.0.29] - 2026-05-20: dedup + link-preview filter (quality-of-life)

Built from commit `0e3a5fb`. SHA-256: `60de506934f00948f92f7d8d195447f2ca189a122bc5107e25b16c846e98ef67`.


### Changed

- **`ChatDBWatcher` skips `.pluginPayloadAttachment` "attachments".** iMessage attaches binary plist files to messages containing URLs to render link-preview cards in Messages.app. Those files are proprietary metadata, not user content; the URL itself is already in the message text. Skipping them removes the empty `<timestamp>/` sidecar folders that were cluttering the output folder for every link.
- **`BatchProcessor` deduplicates by `message.guid`.** iCloud sync delivers each logical iMessage to chat.db once per paired device — each row has a different ROWID but the same GUID. Without dedup, a single Siri-dictated note became 3–4 captured files. A ring buffer of the last 100 GUIDs is now checked before processing.

### Tests

99 → 111 (12 new): 6 for the `.pluginPayloadAttachment` recognizer, 6 for the GUID-dedup ring-buffer helper.

## [1.0.27] - 2026-05-20: echo-cascade defense in depth

Built from commit `c0247dc`. SHA-256: `486fd83d7180c2531ca673ec10b283717734d2cf10313352c03652eddee4fb5f`.

### Security / Reliability

- **Defense in depth against echo cascades.** Three changes prevent the v1.0.18 incident (a 14-second self-feedback loop that wrote ~660 garbage files):
  - `MessageFilter` now drops messages matching the structure of the app's own `✓ Saved: <timestamp>.txt` and `📥 Caught up: ...` confirmations when received from a self-handle. Defense against echo guard misses (stale watermark, expired TTL).
  - `EchoGuard.consumeMatch` is now greedy: a single `track()` suppresses ALL matching inbound entries, not just the first. iCloud's multi-device sync re-delivers each outbound message once per paired device; one-shot consume was leaving extras to cascade.
  - `BatchProcessor` enters catchup mode (replies suppressed, one summary) on any batch >= 10 events, not just the first non-empty batch. Backlogs from Mac sleep/wake or iCloud re-sync no longer trigger per-message replies.
- v1.0.18 has been moved to draft state on GitHub Releases to prevent further installs of the affected build.

## [1.0.18] - 2026-05-19: first public release

Built from commit `9a5972d`. SHA-256: `704a968d5054cfbb9707a710baa44e35ee3fcdffc991e213223440ccf5b1cfa3`.

### Added

- **Capture pipeline**: 1Hz poll of `~/Library/Messages/chat.db` with a ROWID watermark, `attributedBody` binary-blob decoding (so Siri-dictated messages on iOS 16+ are captured), self-handle resolution, allowlist filter, atomic file writes with attachment copying.
- **In-thread confirmation**: `osascript` subprocess send via `Messages.app`. `✓ Saved: <filename>` on success, `✗ <reason>` on failure. 15-second echo guard prevents the app's own replies from re-capturing.
- **Catch-up recovery**: every missed message after sleep/quit is replayed; 4+ catch-ups collapse into one `📥 Caught up: N notes captured` summary; `UNUserNotification` fallback when reply mode is off.
- **Menu-bar UX**: status line (capturing / paused / FDA needed / Automation needed / error), today-count, last-capture relative time, pause/resume, open folder, settings, quit.
- **Settings window**: General (folder picker, launch-at-login, reply mode, allow-SMS), Allowlist (add/remove handles), About (version, repo link, diagnostics).
- **Permission UX**: Full Disk Access onboarding sheet with deep-link to System Settings and 2s polling; Automation pre-prompt before the OS dialog; recovery flow if Automation is denied.

### Security

- Developer ID Application signed (team `P8PLTH44DF`).
- Notarized via `notarytool` against Apple's notary service.
- Hardened runtime enabled.
- Single subprocess invocation (`/usr/bin/osascript`); text passed as argv, not interpolated into shell.
- Zero outbound network calls.
- One third-party dependency: GRDB.swift `6.29.3` (pinned in `Package.resolved`).

### Known issues

- **Full Disk Access must be granted manually** after first launch. The onboarding sheet deep-links to the right System Settings pane and polls every 2 seconds; no workaround exists. macOS does not allow apps to request FDA programmatically.
- **First in-thread reply triggers an Automation prompt**. The app shows a pre-prompt explainer immediately before; if the user denies, replies fail until they re-enable Automation → Messages in System Settings. The denied-state UI directs the user there.
- **Group chats are intentionally not captured** in v1 (`chat_style == 43` is dropped at the filter). Planned for v1.1.
- **No auto-update**. Re-download from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases) to upgrade. Settings and state persist across upgrades.

For the build-by-build context behind these features, see `_build_plan/milestones/{1,2,3,4}/milestone-log.md`. For the architectural rationale (why local-mode-only, why not the Mac App Store), see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`.

[Unreleased]: https://github.com/NoiseMeldOrg/rapture-mac/compare/v1.0.64...HEAD
[1.0.64]: https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/v1.0.64
[1.0.29]: https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/v1.0.29
[1.0.27]: https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/v1.0.27
[1.0.18]: https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/v1.0.18
