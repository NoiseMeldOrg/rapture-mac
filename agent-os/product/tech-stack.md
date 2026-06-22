# Tech Stack

> Last Updated: 2026-05-16
> Version: 1.0.0

## Platform & Language

- macOS 14+ (Sonoma) menu-bar app — `LSUIElement=YES`, no Dock icon
- Swift 5.9+, Xcode 26+
- SwiftUI + `MenuBarExtra(.window)` style
- MVVM with async/await + `@Observable`

## Why macOS 14 deployment target

- `MenuBarExtra(.window)` polish (macOS 13+, refined in 14)
- `SMAppService.mainApp` for launch-at-login (macOS 13+, polished in 14)
- Observation framework `@Observable` (macOS 14+)
- Mirrors the iOS app's preference for modern APIs over wide compatibility

## Apple frameworks

- **AppKit (bridged):** `NSOpenPanel` for folder picker
- **Foundation:** `FileManager`, `Process` (for `osascript`), `FileCoordinator` (atomic writes)
- **ServiceManagement:** `SMAppService.mainApp` for launch-at-login
- **UserNotifications:** `UNUserNotificationCenter` for catch-up fallback when reply mode is off
- **OSLog:** structured logging via `Logger`

## Third-party (SPM)

- **GRDB.swift** — Swift SQLite wrapper, read-only against `~/Library/Messages/chat.db`. Chosen over raw `sqlite3` for safer async API and prepared-statement handling. https://github.com/groue/GRDB.swift

That's it. No Sendblue SDK (no cloud mode in v1), no networking stack beyond Foundation.

## Persistence

- `~/Library/Application Support/Rapture for Mac/settings.json` — user preferences
- `~/Library/Application Support/Rapture for Mac/state.json` — runtime state (chat.db watermark, self-handle cache timestamp, recent echo entries)
- `~/Library/Application Support/Rapture for Mac/output-folder.path` — plain-text absolute path of the current output folder (implemented via `OutputFolderSidecar`). Public contract for downstream consumers (Claude Code SessionStart hook, OpenClaw / Hermes skills, custom scripts). Rapture rewrites this atomically whenever the user picks or changes the output folder in Settings → General (and on first-launch default initialization), so consumers track folder changes without reading `settings.json`.
- **Atomic writes:** `.tmp` → `rename(2)` for all four files
- **Output folder:** user-chosen via `NSOpenPanel`, stored as a plain absolute-path `URL` in `settings.json`. The app is **not** sandboxed, so no security-scoped bookmark is needed. Defaults to `~/Documents/Rapture Notes/` (auto-created) on first launch when none is configured, so the app is functional the moment FDA is granted. Changing the folder relocates the existing notes tree to the new location automatically (`AppState.setOutputFolder` → `OutputFolderMigrator`): same-volume atomic rename, cross-volume copy-verify-delete, merge-never-clobber on collisions, source left intact on failure. The capture pipeline is quiesced via `CaptureGate` during the move.

## Permissions

| Permission | Required for | UX |
|---|---|---|
| Full Disk Access | Reading `~/Library/Messages/chat.db` | Onboarding sheet → deep-link to System Settings → poll every 2s |
| Automation → Messages.app | `osascript` send via Messages | Pre-prompt → OS prompt on first send |
| User-selected folder | Output destination | `NSOpenPanel` with `canCreateDirectories=true`; path persisted in `settings.json` (no bookmark — app is unsandboxed) |

## Sandboxing

**Off.** Sandboxing would block:

- Reading `chat.db` (system-protected path)
- Writing to arbitrary user folders (Dropbox, Drive, etc.)
- AppleScript control of Messages.app
- Spawning `osascript` as a child process

All easier outside the sandbox. Distribution is signed + notarized DMG, not Mac App Store.

## Distribution

- **License:** Apache-2.0. Matches `claude-channel-rapture`; mirrors the FOSS posture across the Rapture product line.
- **Source:** [`NoiseMeldOrg/rapture-mac`](https://github.com/NoiseMeldOrg/rapture-mac) (public).
- **Binaries:** Developer ID-signed + notarized DMG attached to GitHub Releases. End users drag the `.app` into Applications.
- **Code signing:** Developer ID Application, team `P8PLTH44DF` (shared with rapture-ios)
- **Hardened runtime:** ON (required for notarization)
- **Notarization:** `notarytool` via App Store Connect API key `GX6DYX9S2M` (shared with rapture-ios; see `~/.appstoreconnect/private_keys/`)
- **Stapling:** `xcrun stapler staple` the notarized DMG

### Mac App Store

Not in v1, not in v1.1, and not by choice. The MAS sandbox blocks `chat.db` reads regardless of TCC grants and blocks the `osascript` subprocess used for in-thread `✓ Saved` replies. A future "cloud-only" SKU built from a subset of the codebase could plausibly ship in MAS (no chat.db, no AppleScript), but that's a v2 product question, not a v1 design constraint.

## Versioning

Plan: mirror rapture-ios's git-commit-count auto-versioning via a Run Script build phase. Implementation deferred to Phase 14.

## Development tooling

- **Xcode 26+**
- **GitHub:** `NoiseMeldOrg/rapture-mac` (private)
- **Testing:** XCTest. No UI tests in v1 — the pipeline is testable via unit tests against fixture chat.db rows.
- **CI/CD:** none in v1

## Out of scope for v1

- **Networking:** no Hummingbird, cloudflared, Sendblue, webhook listener, MMS download. Entirely deferred to v1.1 with VPS-relay architecture.
- **Keychain:** no secrets in v1.
- **Analytics:** no PostHog / TelemetryDeck.
- **Auto-update:** no Sparkle.
