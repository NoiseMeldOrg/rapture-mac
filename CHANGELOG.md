# Changelog

All notable changes to Rapture for Mac are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow the auto-generated git-commit-count scheme defined in `Scripts/set_git_version.sh` (`MAJOR.MINOR.COMMITS`); see [CONTRIBUTING.md](./CONTRIBUTING.md) for the full versioning logic.

## [Unreleased]

## [1.0.18] - 2026-05-19 — first public release

Built from commit `9a5972d`. SHA-256: `704a968d5054cfbb9707a710baa44e35ee3fcdffc991e213223440ccf5b1cfa3`.

### Added

- **Capture pipeline**: 1Hz poll of `~/Library/Messages/chat.db` with a ROWID watermark, `attributedBody` binary-blob decoding (so Siri-dictated messages on iOS 16+ are captured), self-handle resolution, allowlist filter, atomic file writes with attachment copying.
- **In-thread confirmation**: `osascript` subprocess send via `Messages.app` — `✓ Saved: <filename>` on success, `✗ <reason>` on failure. 15-second echo guard prevents the app's own replies from re-capturing.
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

- **Full Disk Access must be granted manually** after first launch. The onboarding sheet deep-links to the right System Settings pane and polls every 2 seconds; no workaround exists — macOS does not allow apps to request FDA programmatically.
- **First in-thread reply triggers an Automation prompt**. The app shows a pre-prompt explainer immediately before; if the user denies, replies fail until they re-enable Automation → Messages in System Settings. The denied-state UI directs the user there.
- **Group chats are intentionally not captured** in v1 (`chat_style == 43` is dropped at the filter). Planned for v1.1.
- **No auto-update**. Re-download from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases) to upgrade. Settings and state persist across upgrades.

For the build-by-build context behind these features, see `_build_plan/milestones/{1,2,3,4}/milestone-log.md`. For the architectural rationale (why local-mode-only, why not the Mac App Store), see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`.

[Unreleased]: https://github.com/NoiseMeldOrg/rapture-mac/compare/v1.0.18...HEAD
[1.0.18]: https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/v1.0.18
