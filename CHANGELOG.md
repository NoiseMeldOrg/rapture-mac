# Changelog

All notable changes to Rapture for Mac are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the auto-generated git-commit-count scheme defined in `Scripts/set_git_version.sh` (`MAJOR.MINOR.COMMITS`); see [CONTRIBUTING.md](./CONTRIBUTING.md) for the full versioning logic.

## [Unreleased]

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
