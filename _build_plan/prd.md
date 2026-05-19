# Rapture for Mac

> **About these build-plan files:** Everything in `_build_plan/` (this PRD and the per-milestone folders) is a **temporary documentation and guidance artifact** for the initial build-out of this codebase. These files are not functional — no code, configuration, runtime logic, tests, or deployment process should import, read, reference, or depend on anything in `_build_plan/`. Once the initial milestones are built and shipped, the entire `_build_plan/` folder is expected to be deleted from the codebase. Do not treat it as long-living documentation.

## What we're building

Rapture for Mac is a menu-bar app that turns Siri-dictated iMessages into timestamped `.txt` files in a folder any AI assistant can read. The capture flow is fully frictionless — no tap, no button press, no app to open, no shortcut to install, no unlock — just *"Hey Siri, text me…"* from across the room with the standard iPhone in your pocket; the file lands on your Mac in seconds, and an in-thread `✓ Saved` reply confirms it without the user's eyes leaving where they were. The folder is the integration surface — Claude, ChatGPT, Gemini, any tool that reads files can consume the captures.

Built native macOS in Swift 5.9+ on the macOS 14+ deployment target, with SwiftUI's `MenuBarExtra(.window)`, MVVM + async/await + `@Observable`, and GRDB.swift as the only third-party dependency (read-only against `~/Library/Messages/chat.db`). Apache-2.0 source on GitHub; distributed as a signed + notarized DMG on GitHub Releases — not the Mac App Store, since the sandbox blocks `chat.db` reads and the `osascript` subprocess used for in-thread replies. The build is structured around four user-testable milestones; each one delivers a meaningfully better product than the last.

---

### What the app does

- Watches the user's iMessage history live and writes each captured message to a `.txt` file in a folder of their choice
- Captures messages-to-self always (no setup); captures from other contacts only when they are on a user-managed allowlist
- Sends a `✓ Saved: <filename>` reply in the iMessage thread so the user gets audible confirmation on their phone (standard message-received chime)
- Catches up on every missed message after the Mac wakes or the app restarts; collapses large catch-up batches into a single summary reply
- Surfaces status in the menu bar: today's count, last capture, last error, pause/resume, open folder, quit
- Provides a Settings window with a folder picker, allowlist editor, reply-mode picker (All / Errors only / Off), and launch-at-login
- Walks the user through the two required macOS permissions (Full Disk Access, Automation → Messages) with deep-links to System Settings and plain-language explainers

---

### Already provided by the existing codebase

Nothing yet. This is a fresh Xcode project scaffold — there is no pre-built auth, app shell, settings system, or persistence layer to omit from this PRD. Everything described from Milestone 1 onward is yet to be built. The closest thing to a "starter" is Apple's default Xcode macOS app template (an empty `App` struct + `MenuBarExtra` scene), which provides essentially nothing of substance for this app.

---

### Out of scope

- **Cloud mode (Sendblue)** — deferred to v1.1 with a VPS-relay architecture; running a webhook listener on the Mac would die when the Mac sleeps and break the trust promise.
- **Group chat support** (`chat_style == 43`) — v1 ignores group threads; downstream filter explicitly drops them.
- **Contacts framework name resolution** — the allowlist uses raw handles (phone / email); no friendly-name lookup.
- **Edit / unsend tracking** — captures are point-in-time; later edits don't propagate.
- **Mac App Store distribution** — structurally impossible (sandbox blocks `chat.db` reads and the `osascript` subprocess used for replies).
- **Auto-update (Sparkle)** — manual download from GitHub Releases for v1.
- **Analytics** — no PostHog, TelemetryDeck, or telemetry of any kind.
- **Routing Rapture iOS dictations into this folder** — sibling-repo concern (tracked in `claude-channel-rapture` and `rapture-api-gateway` `FUTURE-INTEGRATIONS.md`); adding it here would violate the spec's "no networking in v1" boundary.
- **In-app browsing / search / preview** of captured notes — the folder *is* the UI; use Finder, Spotlight, ripgrep, or the user's AI assistant.
- **In-app editing, tagging, or categorizing of captures** — `.txt` files are immutable; the downstream AI assistant decides what to do with them.
- **Built-in AI or LLM integration** — this app is the capture layer, not the AI; vendor neutrality is the differentiator.
- **Audio capture of the original dictation** — text only; the audio lives in iMessages on the user's iPhone.
- **Multi-folder destinations** — one output folder per install.
- **Mac Notification Center pings on each capture** — the iMessage reply is the confirmation; a Mac notification would be redundant noise.
- **Encryption / password protection of captures** — `.txt` files only; users who need encryption point the output folder at an encrypted volume.

---

### Data model

The app's persistent state is two small JSON files (atomic `.tmp` → `rename(2)` writes). Output artifacts (`.txt` files and attachment folders) are produced into the user's chosen output folder and are not "owned" by the app once written.

#### Settings (`~/Library/Application Support/Rapture for Mac/settings.json`)

- `outputFolder` — the folder the user picked for captures, stored as a security-scoped bookmark so Dropbox/Drive paths survive across launches
- `allowedHandles` — phone numbers / Apple ID emails whose messages should be captured beyond self-chat
- `allowSMS` — whether to capture SMS/RCS too. Default off — SMS sender IDs are spoofable
- `launchAtLogin` — whether to auto-start with the Mac
- `paused` — whether capture is currently paused (set from the menu bar)
- `replyMode` — `All` / `ErrorsOnly` / `Off`

#### PersistedState (`~/Library/Application Support/Rapture for Mac/state.json`)

- `chatDbWatermark` — the highest `ROWID` processed; catch-up reads everything above it on next launch
- `selfHandlesCacheTs` — when the user's own iMessage handles were last refreshed
- `recentSentEchoes` — last ~15 seconds of `✓ Saved` replies the app sent, used to filter the app's own confirmations out if they return as inbound
- `lastError` — the most recent capture failure, if any (surfaced in the menu bar)

#### Output artifacts (in the user's chosen folder)

- A `<timestamp>.txt` file per captured message — body is the decoded message text; if attachments existed, an `Attachments:` section is appended listing sibling paths
- A `<timestamp>/` sibling folder per message-with-attachments, containing the copied attachment files

#### Relationships

- `Settings` and `PersistedState` are independent files; neither references the other.
- One captured iMessage → one `.txt` file and zero or more attachment files in its sibling folder.
- `chatDbWatermark` is a high-water mark against `chat.db` `message.ROWID`; everything above it is "new."
- `recentSentEchoes` maps to replies sent in the last 15 seconds, used to drop those if they return as inbound (so confirmations don't re-capture themselves).

---

## Milestone 1 — First Capture

The app captures qualifying iMessages and writes them to disk. No UI yet — the app runs invisibly. No replies yet — captures are silent. The user's only evidence that anything happened is `.txt` files appearing in `~/Documents/Rapture Notes/`.

### What gets built

- Xcode project scaffold (`RaptureMac.xcodeproj`), macOS 14+ target, `LSUIElement=YES`, hardened runtime ON, no sandbox, GRDB.swift via SPM
- Models for messages, captures, attachments, settings, persisted state, reply mode
- `Settings` and `PersistedState` stores backed by atomic JSON in `~/Library/Application Support/Rapture for Mac/`
- `AttributedBody` decoder (binary-blob byte-scan) so Siri-dictated messages — which omit the plain `text` column on iOS 16+ — actually surface
- `chat.db` watcher with 1-second polling and a `ROWID` watermark that advances only after durable writes
- Self-handle resolver that figures out the user's own iCloud addresses automatically
- Filter that drops anything not self-chat or allowlisted, plus the eight other drop rules from the spec
- File writer that produces `<timestamp>.txt` atomically (`.tmp` → `rename(2)`) and copies attachments to a sibling folder
- First-launch default output folder at `~/Documents/Rapture Notes/` (auto-created)
- Full Disk Access onboarding sheet with deep-link to System Settings and polling every 2 seconds until granted

### What milestone 1 explicitly does NOT include

- Menu-bar UI of any kind (no popover, no status, no controls)
- Any in-thread `✓ Saved` reply (Milestone 2 territory)
- Catch-up on launch (Milestone 2)
- Settings window (Milestone 3)
- Allowlist editor (Milestone 3) — the allowlist *concept* exists in the filter, but with a hardcoded empty list for now
- Code signing or distribution (Milestone 4)

### Done when

The user can grant Full Disk Access, leave the app running invisibly, send themselves an iMessage from any device on their iCloud account, and within ~1 second see a `<timestamp>.txt` file appear in `~/Documents/Rapture Notes/` containing exactly the dictated text. Sending an iMessage with a photo also produces the sibling folder with the copied image.

---

## Milestone 2 — Confirmation & Recovery

The app now confirms each capture in-thread and recovers gracefully from being asleep or quit. Still no UI for the user to interact with — but every capture is visibly confirmed on their phone, and nothing gets dropped.

### What gets built

- AppleScript sender (`osascript` subprocess) for posting replies via Messages.app
- Replier that composes `✓ Saved: <filename>` on success and `✗ <reason>` on failure, gated by reply mode (hardcoded to `.all` for this milestone)
- 15-second echo guard so the app's own `✓ Saved` replies don't re-capture as new notes
- Automation → Messages pre-prompt explainer fired just before the OS dialog appears
- Catch-up detection on launch (first batch with more than 3 messages → catch-up mode)
- Per-message replies for small catch-ups (1–3 messages); single summary reply (`📥 Caught up: N notes captured (M failed)`) for large catch-ups (4+)
- `UNUserNotification` fallback for catch-up summaries when reply mode is later set to `.off` (the plumbing lands here; the toggle that actually triggers it lands in Milestone 3)

### What milestone 2 explicitly does NOT include

- Menu-bar UI (Milestone 3)
- Settings window or reply-mode picker (Milestone 3) — reply mode is hardcoded to `.all` for now
- Allowlist editor (Milestone 3)
- Code signing / distribution (Milestone 4)

### Done when

The user sends themselves an iMessage and within ~3 seconds receives a `✓ Saved: <filename>` reply in the same thread. The user quits the app, sends themselves 5 more messages from another device, relaunches the app, sees the 5 missed `.txt` files appear in their folder, and receives a single summary reply on their phone ("📥 Caught up: 5 notes captured"). No reply re-triggers a capture — the echo guard holds.

---

## Milestone 3 — User Control

The user can now see what the app is doing and change how it behaves without quitting. Adds the full menu-bar UX, the Settings window with all three tabs, and the allowlist editor.

### What gets built

- Menu-bar popover with status line (`✓ capturing` / `– paused` / `⚠ FDA needed` / `⚠ error`), today's note count, last capture relative time, last error (when present), pause/resume, open folder, settings, quit
- Menu-bar icon visual change when paused
- Settings → General tab: folder picker (`NSOpenPanel` + security-scoped bookmark, drag-and-drop supported), launch-at-login toggle (`SMAppService`), reply-mode picker (All / Errors only / Off) wired to actually change replier behavior, allow-SMS toggle with spoofing-risk explainer
- Settings → Allowlist tab: simple add/remove list editor; accepts phone numbers or Apple ID emails; explanatory note that self-chat is always captured
- Settings → About tab: version string (git-commit-count derived), GitHub repo link, Apache-2.0 attribution, Diagnostics disclosure showing last error and state file path, acknowledgments
- The hardcoded empty allowlist from Milestone 1 is now actually editable

### What milestone 3 explicitly does NOT include

- Code signing or notarization (Milestone 4)
- DMG packaging (Milestone 4)
- Public GitHub repo flip (Milestone 4)
- Auto-update (out of scope for v1)
- Analytics or telemetry (out of scope for v1)

### Done when

The user clicks the menu-bar icon, sees `✓ capturing | Today: 7 notes | Last: 2 min ago`, pauses capture, watches a new self-sent message NOT produce a `.txt` file, resumes capture, watches a new self-sent message produce a `.txt`, opens Settings, picks a different folder, adds an allowlisted contact, switches reply mode to "Errors only", and confirms the new behavior matches.

---

## Milestone 4 — Public Release

The app becomes installable by anyone — signed, notarized, packaged as a DMG, and attached to a GitHub Release on a now-public Apache-2.0 repo.

### What gets built

- Code signing build phase with Developer ID Application certificate (team `P8PLTH44DF`, shared with rapture-ios)
- Hardened runtime entitlements; Automation → Messages entitlement
- Notarization script using `notarytool` and the App Store Connect API key `GX6DYX9S2M` (shared with rapture-ios)
- DMG packaging (`create-dmg` or `hdiutil`) with a stapled notarization ticket
- Repo flipped from private to public on GitHub
- `LICENSE` (Apache-2.0, already in place), `SECURITY.md`, `CONTRIBUTING.md`, polished `README.md` for the front door
- First GitHub Release with the DMG attached and release notes

### What milestone 4 explicitly does NOT include

- Auto-update / Sparkle (out of scope for v1)
- Mac App Store submission (structurally impossible — see "Out of scope")
- CI/CD pipelines (out of scope for v1; manual build-and-notarize is the v1 release flow)
- Analytics (out of scope for v1)

### Done when

A first-time user can navigate to `https://github.com/NoiseMeldOrg/rapture-mac`, find the latest Release, download the DMG, double-click to open, drag `Rapture for Mac.app` into Applications, launch it, go through the FDA and Automation prompts, send themselves an iMessage from across the room, and receive a `✓ Saved` confirmation — without ever opening a terminal or seeing the source code.
