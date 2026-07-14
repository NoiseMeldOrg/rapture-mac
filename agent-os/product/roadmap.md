# Product Roadmap

> Last Updated: 2026-07-14
> Version: 1.2.1
> Status: v1 shipped — latest public release v1.0.98 (2026-07-14), which ships the built-in triage engine (5 milestones, 2026-07-13) in one cut.

Faithful 14-phase plan from `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md`. Effort is shaped as `XS` (1 day), `S` (2–3 days), `M` (1 week), `L` (2 weeks).

**Execution view:** Initial build-out grouped the 14 phases into **4 user-testable milestones** scaffolded for fresh agent sessions in [`_build_plan/`](../../_build_plan/) — M1 First Capture (2026-05-19) · M2 Confirmation & Recovery (2026-05-19) · M3 User Control (2026-05-19) · M4 Public Release (2026-05-19, v1.0.18 → patched to v1.0.29 by 2026-05-20). `_build_plan/` is **preserved as a historical record**, not deleted; the 14 phases below remain the canonical technical breakdown.

**Post-M4 patches (2026-05-20):**
- **v1.0.27** — echo-cascade defense-in-depth (pattern-match drop for own `✓ Saved`/`📥 Caught up` confirmations, greedy echo-guard consume, backlog-size catchup trigger). Closes the v1.0.18 incident where iCloud-relayed outbounds re-entered as `is_from_me=0` and bypassed the filter.
- **v1.0.29** — dedup by `message.guid` (multi-device iCloud delivery was capturing each Siri note 3–4×) + skip `.pluginPayloadAttachment` link-preview sidecars.

111 tests covering every failure mode from the v1.0.18 incident.

**Post-v1.0.29 patches:**
- **v1.0.48 (shipped 2026-05-22)** — menu bar icon = Rapture brand mark. Custom template image in `Assets.xcassets/MenuBarIcon.imageset/` (@1x/@2x/@3x black-on-transparent with `template-rendering-intent`). `MenuBarLabel` in `RaptureMacApp.swift` shows the brand mark when capturing normally; keeps SF Symbols (`exclamationmark.triangle.fill`, `pause.fill`) for the warning/paused states because those communicate clearly across all apps. Replaces the placeholder `text.bubble`. Auto-versioner jumped to 1.0.48 because of intervening doc/scripts commits (no v1.0.30–v1.0.47 were released).

**Post-v1.0.48 patches:**
- **v1.0.69 (shipped 2026-06-22)** — Dropbox-style auto-relocation of the output folder + the output-folder path sidecar (now implemented). Changing the folder in Settings → General moves the existing notes tree to the new location (same-volume atomic rename; cross-volume copy-verify-delete; merge-never-clobber on collisions; source intact on failure; emptied old folder removed on success) via `AppState.setOutputFolder` → `OutputFolderMigrator`, with the capture pipeline quiesced by `CaptureGate`. `OutputFolderSidecar` writes the resolved absolute path to `~/Library/Application Support/Rapture for Mac/output-folder.path` on every change and on first-launch init — the public contract for downstream consumers (Claude Code SessionStart hook, OpenClaw / Hermes skills, custom scripts). This release also folds in the accumulated unreleased work since 1.0.64: the `ContentDedupCache` fix for iCloud cross-device replay duplicates, the `✅ Saved` / `📥 Caught up: N notes` reply-text changes, and removal of the autonomous launchd watcher. 214 tests. See [`agent-os/specs/2026-06-22-1048-output-folder-auto-relocation/`](../specs/2026-06-22-1048-output-folder-auto-relocation/). `S`

**Post-v1.0.69 releases:**
- **v1.0.80 (shipped 2026-06-27)** — Sparkle in-app auto-update (first self-updating release), app + DMG both notarized and stapled, release pipeline re-signs Sparkle's nested helpers, CI on GitHub Actions. See CHANGELOG 1.0.80.
- **v1.0.88 (shipped 2026-07-06)** — **second capture source: notes sent from the Rapture iOS app.** `RelayWatcher` polls the synced iCloud relay folder (`~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay/`, 5s snapshot scans, placeholder-download nudging, txt/m4a pairing with orphan-audio recovery); `RelayProcessor` files arrivals under `CaptureGate` in file → ledger → delete-relay-copy order, duplicate-safe across restarts and iCloud re-syncs (`RelayFiledLedger` in state.json, 90d TTL). Same filing conventions as iMessage captures (relay basename kept verbatim, attachments sibling folder + footer); arrivals feed the shared today count; pause/relocation defer identically. Settings → General → "iPhone App" toggle (on by default) + status. Needs no FDA; adds zero networking (PRIVACY grep re-verified). Debug builds watch `Relay (Debug)/`. 279 tests. Milestones 1–4 (iOS destination → Mac watcher → website/docs → e2e dogfood) documented in `rapture-ios/_build_plan/rapture-mac-destination/`. `M`
**Post-v1.0.88 (released as v1.0.98, 2026-07-14):**
- **Built-in triage engine (2026-07-13, five milestones in one day, commits `c715e67` → M5)** — the app now makes sense of every capture the moment it arrives. M1 core: captures file as Markdown notes with the capture contract (`captured`/`source`/`type`/`raw_media` frontmatter, `## Raw` verbatim invariant), deterministically classified into `Notes/`/`Links/`, backlog drained on launch, raw-mode escape hatch. M2 destination resilience: external-volume destinations first-class, offline spool with FIFO flush, no shadow folders, pair-aware relocation fixes. M3 Reminders & Calendar handoff via EventKit (opt-in, conservative deterministic detection, handoff ledger against double-booking). M4 AI triage (opt-in): Apple Intelligence on-device or BYO Anthropic key, task/idea/journal classification into `Tasks/`/`Ideas/`/`Journal/`, smart titles, light formatting, sharper handoff detection behind the same toggles; the app's first credential (Keychain) and second outbound network path. M5 link enrichment (opt-in): YouTube transcripts / article extracts fetched into `Links/Media/`, link notes renamed to real titles, dedup by video ID / normalized URL, quiet failure — plus the coordinated docs overhaul (output-neutrality reversal in mission/CONTEXT, PRIVACY/SECURITY/README rewrites, examples/ + scaffold reconciliation) and this backport. 727 tests. Durable spec: [`agent-os/specs/2026-07-13-2230-triage-engine/`](../specs/2026-07-13-2230-triage-engine/); frozen build log: `_build_plan/triage-engine/`. `L`

- **Dogfood validation (2026-07-06, post-v1.0.88)** — end-to-end on real hardware (iPhone 12 + Mac mini, real Siri captures, real iCloud): Sparkle 1.0.83→1.0.88 update preserved FDA and cold catch-up filed a 4-hour-old pending relay file within one poll; happy path, audio pairing, Mac-asleep wake catch-up, iCloud-signed-out failure/retry, and coexistence with the visible iCloud Drive destination all passed; iCloud transit 5–30s (v1.1 LAN accelerator judged not warranted). One Mac-side finding, fixed: `RelayProcessorTests` read the dev machine's live debug container; `SettingsStore`/`StateStore`/`AppState` now accept an injected directory and the suite runs on per-test temp dirs (commit `98d3f6a`, test-infrastructure only, no release needed). Full log: `rapture-ios/_build_plan/rapture-mac-destination/milestones/4-e2e-dogfood/milestone-log.md`.

## Phase 1: Repo bootstrap (Complete)

1. [x] gh repo created — `NoiseMeldOrg/rapture-mac` (private). `XS`
2. [x] Seed files — `.gitignore`, `README.md`, `CLAUDE.md`. `XS`
3. [x] agent-os scaffold — `product/{mission,tech-stack,roadmap}.md`. `XS`
4. [x] Spec copied to canonical location. `XS`

## Phase 2: Xcode project scaffold (Complete)

5. [x] Create `RaptureMac.xcodeproj` — macOS 14 target, SwiftUI menu-bar, `LSUIElement=YES`, hardened runtime ON, no sandbox. GRDB via SPM. `S`
6. [x] `RaptureMacApp.swift` shell — `MenuBarExtra(.window)`, `AppState` as `@Observable` root. `XS`

## Phase 3: Models + persistence (Complete)

7. [x] Models — `MessageEvent`, `CapturedMessage`, `AttachmentRef`, `Settings`, `PersistedState`, `ReplyMode`. `XS`
8. [x] `SettingsStore` + `StateStore` — atomic JSON writes to `~/Library/Application Support/Rapture for Mac/`. `S`

## Phase 4: AttributedBody decoder (Complete)

9. [x] `AttributedBodyDecoder.decode(_:)` — pure Swift port of the `server.ts:82–102` byte-scan algorithm. Unit tests against fixture blobs. `S`

## Phase 5: chat.db watcher (Complete)

10. [x] `ChatDBWatcher` — GRDB read-only `DatabasePool`, 1s polling, ROWID watermark, `AsyncStream<MessageEvent>` output, attachment join per row. `M`
11. [x] Permission failure surfaces cleanly — publishes `permissionRequired(.fullDiskAccess)`, doesn't crash. `XS`

## Phase 6: Self-handle resolution (Complete)

12. [x] `SelfHandleResolver` — 60s refresh task; normalization matches `server.ts:177–185`. `XS`

## Phase 7: Filter (Complete)

13. [x] `MessageFilter` — 9 drop rules in order (mirrors `server.ts:777–798`). Returns `.capture` or `.drop(reason)` for menu-bar diagnostics. `S`

## Phase 8: File writer (Complete)

14. [x] `FileWriter` — atomic `.tmp` → `rename(2)`. Attachment sibling folder. One-retry on missing attachment. `WriteResult` with failure detail. Path-traversal sanitization on attachment filenames added during M4. `S`

## Phase 9: AppleScript replier + echo guard (Complete)

15. [x] `AppleScriptSender` — `Process` invocation of `osascript -` with stdin script, argv `[text, chatGuid]`. Handle Automation permission denial. `S`
16. [x] `Replier` — compose `✓ Saved` / `✗ <reason>` based on `replyMode`. Trigger on every `WriteResult`. `XS`
17. [x] `EchoGuard` — 15s LRU. Normalize matches `server.ts:431–457` (lowercase, strip ZWJ, smart quotes → ASCII, collapse whitespace, cap 120). Hardened in v1.0.27 with greedy consume + pattern-match drop fallback after iCloud multi-device relay surfaced the echo cascade. `S`

## Phase 10: Catch-up (Complete)

18. [x] Catch-up detection — batch of 10+ events triggers catchup (broadened from "first batch with >3" in v1.0.27 to survive sleep/wake backlogs). `XS`
19. [x] Catch-up replier mode — ≤3 per-message; 4+ summary; `UNUserNotification` fallback when `replyMode=.off`. `S`

## Phase 11: Settings window (Complete)

20. [x] Settings shell — `Window` (not `Settings` scene), tabs: General, Allowlist, About. `S`
21. [x] General tab — folder picker (`NSOpenPanel` + bookmark), launch-at-login (`SMAppService`), reply mode picker. `S`
22. [x] Allowlist tab — `List` editor for handles. Self-chat is always captured. `XS`
23. [x] About tab — version, repo link, last-error diag. `XS`

## Phase 12: Menu bar UI (Complete)

24. [x] `MenuBarView` — status line, today count, last time, last error, pause/resume, open folder, settings, quit. `S`

## Phase 13: Permissions UX (Complete)

25. [x] Full Disk Access onboarding — modal sheet, deep-link to `x-apple.systempreferences:...`, poll every 2s. `S`
26. [x] Automation pre-prompt — explain before OS prompt fires. `XS`

## Phase 14: Distribution (Complete)

27. [x] Code signing build phase — Developer ID (team `P8PLTH44DF`), hardened runtime, entitlements, timestamp, no `get-task-allow`. `S`
28. [x] Notarization script — `notarytool` + `stapler` via `Scripts/release.sh`. `S`
29. [x] DMG packaging — `hdiutil` via `Scripts/release.sh`. `XS`
30. [x] Flip repo to public on GitHub + add `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `PRIVACY.md`. `XS`
31. [x] First signed + notarized release — GitHub Releases, DMG attached. Released as v1.0.18 (2026-05-19), patched through v1.0.29 (2026-05-20). `XS`

## v1.1 (deferred)

32. [ ] Cloud mode via VPS relay — Sendblue → user's hetzner VPS → push to Mac. Transport TBD (APNs silent push vs Mac long-poll vs WebSocket). Replaces the on-Mac webhook design from the original plan. `L`
33. [ ] Group chat support — `chat_style == 43` with optional `requireMention` regex. `S`
34. [ ] Contacts framework integration — resolve names in allowlist UI. `XS`
35. [x] Auto-update — Sparkle. Shipped early in v1.0.80 (2026-06-27). `S`

---

> **macOS 14 deployment target.** Explicit choice to use modern APIs (`@Observable`, `SMAppService`, `MenuBarExtra(.window)`) over wide compatibility.
> **No sandbox.** Required for FDA, arbitrary folder writes, AppleScript control. Distribution is signed + notarized DMG.
> **Reference implementation:** `external_plugins/imessage/server.ts` — see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md`.
