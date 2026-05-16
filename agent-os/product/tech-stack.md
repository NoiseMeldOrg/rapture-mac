# Technical Stack

> Last Updated: 2026-05-16
> Version: 1.0.0

## Platform & Language

- **Platform:** macOS (menu-bar app)
- **Minimum macOS:** macOS 14.0 (Sonoma)
- **App framework:** Native macOS (SwiftUI)
- **Language:** Swift 5.9+
- **Development environment:** Xcode 26+
- **UI framework:** SwiftUI + `MenuBarExtra(.window)` style
- **Architecture:** MVVM with async/await + `@Observable`

## Reason for macOS 14 deployment target

- `MenuBarExtra(.window)` (macOS 13+ but with .window style improvements in 14)
- `SMAppService.mainApp` for launch-at-login (macOS 13+, polished in 14)
- Observation framework `@Observable` (macOS 14+)
- Mirrors iOS app's preference for using modern APIs over wide compatibility

## Apple Frameworks

- **AppKit (bridged):** `NSOpenPanel` for folder picker, `NSStatusItem` indirectly via `MenuBarExtra`
- **Foundation:** `URLSession` (not used in v1; reserved for v1.1 cloud mode), `FileManager`, `Process` (for `osascript`), `FileCoordinator` (for atomic writes)
- **ServiceManagement:** `SMAppService.mainApp` for launch-at-login
- **UserNotifications:** `UNUserNotificationCenter` for catch-up summary fallback when reply mode is off
- **OSLog:** Structured logging via `Logger`

## Third-party dependencies (SPM)

- **GRDB.swift** — Swift SQLite wrapper, read-only against `~/Library/Messages/chat.db`. Chosen over raw `sqlite3` for safer async API and prepared statement handling. https://github.com/groue/GRDB.swift

That's it. No Sendblue SDK (no cloud mode in v1), no networking stack beyond Foundation.

## Data flow

```
~/Library/Messages/chat.db  ←  iCloud syncs this when Mac is awake
        │
        │ GRDB read-only poll, WHERE ROWID > watermark
        ▼
ChatDBWatcher  →  MessageEvent (AsyncStream)
        │
        ▼
MessageFilter  ←  SelfHandleResolver, EchoGuard
        │
        ▼  (if .capture)
FileWriter  →  <output-folder>/<ISO-UTC>.txt
        │
        ▼  (write result)
Replier  →  AppleScriptSender  →  osascript  →  Messages.app  →  iMessage reply
        │
        └→  EchoGuard.track()  (so the reply doesn't re-capture itself)
```

## Persistence

- **`~/Library/Application Support/Rapture for Mac/settings.json`** — user preferences (output folder URL, allowlist, reply mode, etc.)
- **`~/Library/Application Support/Rapture for Mac/state.json`** — runtime state (chat.db watermark, self-handle cache timestamp, recent echo entries)
- **Atomic writes:** `.tmp` → `rename(2)` for both files.
- **Output folder:** user-chosen via `NSOpenPanel`. Stored as bookmark data so the path survives across launches even if the folder moves.

## Permissions

| Permission | Required for | UX |
|---|---|---|
| Full Disk Access | Reading `~/Library/Messages/chat.db` | Onboarding sheet → deep-link to System Settings → poll every 2s |
| Automation → Messages.app | `osascript` send via Messages | Pre-prompt → OS prompt on first send |
| User-selected folder | Output destination | `NSOpenPanel` with `canCreateDirectories=true`, bookmark persistence |

## Sandboxing

**Off.** Sandboxing would block:
- Reading `chat.db` (system-protected path)
- Writing to arbitrary user folders (Dropbox, Drive, etc.)
- AppleScript control of Messages.app
- Spawning `osascript` as a child process

All easier outside the sandbox. Distribution is signed + notarized DMG, not Mac App Store.

## Distribution

- **Code signing:** Developer ID Application certificate, team `P8PLTH44DF` (shared with rapture-ios)
- **Hardened runtime:** ON (required for notarization)
- **Notarization:** `notarytool` via App Store Connect API key `GX6DYX9S2M` (shared with rapture-ios; see `~/.appstoreconnect/private_keys/`)
- **Stapling:** `xcrun stapler staple` the notarized DMG
- **Distribution channel:** TBD — likely direct download from a NoiseMeld page

## Versioning

Plan: mirror rapture-ios's git-commit-count auto-versioning via a Run Script build phase. Implementation deferred to Phase 14.

## Development tooling

- **Xcode 26+**
- **GitHub:** `NoiseMeldOrg/rapture-mac` (private)
- **Testing:** XCTest (no UI tests in v1 — pipeline is testable via unit tests against fixture chat.db rows)
- **CI/CD:** None in v1
- **MCP servers:** XcodeBuildMCP, axiom plugin — already configured globally; no per-repo MCP config needed

## Out of scope (v1)

- **Cloud / networking:** No Hummingbird, no cloudflared, no Sendblue, no webhook listener, no MMS download. Entirely deferred to v1.1.
- **Keychain:** No secrets in v1 (no API keys to store).
- **Analytics:** No PostHog / TelemetryDeck. Add only if there's a real reason.
- **Auto-update:** No Sparkle. Add when distribution is mature.
