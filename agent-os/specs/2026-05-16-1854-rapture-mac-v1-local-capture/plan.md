# Rapture for Mac — v1 (Local-Mode Capture)

> Spec snapshot from shaping session 2026-05-16. Source of truth lives in `rapture-mac/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md` once that repo is bootstrapped.

## Context

The user wants a tiny macOS menu-bar companion to the Rapture iOS app that turns Siri-dictated iMessages into files on disk. The motivating flow: their phone is across the room, **locked, untouched** — they say *"Hey Siri, send a text to me saying rent is due on the 5th."* Siri transcribes and sends. A menu-bar app on the Mac sees the message arrive, writes a timestamped `.txt` to a folder they picked (local, Dropbox, Drive — all just paths), copies any attachments, and replies in the chat with a short capture confirmation. The folder is also the integration surface for a personal AI assistant that watches it and decides what to do with each note.

**The defining property is that the iPhone side is fully hands-free from a locked device.** Siri is the entire interface.

**Why this spec is local-mode-only:** A full design exists at `~/.claude/plans/can-you-help-me-goofy-clover.md` describing both a local mode (chat.db polling, AppleScript replies) and a cloud mode (dedicated Sendblue number, cloudflared tunnel, on-Mac webhook listener). v1 ships the local mode only. Putting an inbound webhook on a personal Mac undermines the product promise — the Mac sleeps, the tunnel dies with it, Sendblue's retry window is undocumented, and the architecture leaks "service that accepts work from the internet" into "device that does work for me." Cloud mode lands later on a VPS-relay architecture (Sendblue → user's hetzner VPS → push to Mac), removing the on-Mac webhook entirely. v1.1 architecture is deferred.

## Decisions (locked during shaping)

| | |
|---|---|
| App name | **Rapture for Mac** |
| Bundle ID | `noisemeld.RaptureMac` |
| Repo | **New private repo `NoiseMeldOrg/rapture-mac`** at `/Volumes/Dock SSD/Source/Repos/NoiseMeldOrg/rapture-mac` |
| Spec location (snapshot) | `rapture-ios/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/` |
| Spec location (canonical) | `rapture-mac/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/` |
| Deployment target | macOS 14 (Sonoma) |
| Language | Swift 5.9+ |
| UI | SwiftUI + `MenuBarExtra(.window)` |
| DB layer | GRDB.swift (read-only against chat.db) |
| Sandboxing | **No** — needs FDA, arbitrary folder writes, AppleScript control of Messages.app |
| Distribution | Developer ID-signed + notarized DMG. **No** Mac App Store in v1. |
| Modes shipped | **Local mode only** (chat.db + AppleScript) |
| Modes deferred | Cloud mode (Sendblue + webhook + cloudflared) — entirely out of v1 |

## Reference contracts (verified during shaping)

The local-mode design is a direct port of `external_plugins/imessage/server.ts`. Exploration confirmed the following exact contracts the Swift port must honor:

- **Polling SQL** (server.ts:120–129) joins `message ← chat_message_join ← chat`, left-joins `handle`, watermark = `m.ROWID`, ordered ASC. Open DB **read-only**. 1-second poll interval (server.ts:771).
- **`attributedBody` decoder** (server.ts:82–102): find `NSString\0` marker → scan to `0x2B` → read length prefix (1 byte direct, or `0x81` → 1-byte LE, `0x82` → 2-byte LE, `0x83` → 3-byte LE) → UTF-8 decode. Return `null` on missing marker, missing `0x2B`, or bounds overflow.
- **Self-handle SQL** (server.ts:177–185): `SELECT DISTINCT account FROM message WHERE is_from_me=1 AND account IS NOT NULL AND account != '' LIMIT 50`. Strip `E:` / `p:` prefix (regex `^[A-Za-z]:`), lowercase, cache in `Set<String>`. Recomputed periodically.
- **Filter drops** (server.ts:777–798): `chat_style==null` drop; `chat_style==43` (group) requires stricter allowlist; `chat_style==45` is DM; `service != "iMessage"` drop unless `allowSMS=true`; empty text + no attachments drop; `is_from_me==1` drop; `handle_id==NULL` drop.
- **Attachment SQL** (server.ts:166–171): join via `message_attachment_join`. Expand tilde paths.
- **Apple epoch** (server.ts:77): `978_307_200` seconds; `message.date` is **nanoseconds**, divide by 1e6 for ms.
- **AppleScript send** (server.ts:418–424, 459–467): `tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)`. Invoke `osascript ['-', text, chatGuid]` via `Process`, script via stdin.
- **Echo guard** (server.ts:431–457): 15-second window, key = `chatGuid + 0x00 + normalize(text)`. Normalize = strip `' Sent by Claude'` suffix, strip ZWJ + variation selectors, normalize smart quotes to ASCII, trim, collapse whitespace, cap at 120 chars. Track on send, consume on inbound.

The Sendblue/boop-agent reference work from the shaping exploration is **not used in v1** but is preserved in `references.md` so v1.1 can pick it up.

---

## Phase 1 (Task 1): Spec docs + repo bootstrap

Snapshot the shaping into `rapture-ios/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`:
- `plan.md` (this file)
- `shape.md` (scope, decisions, why local-only)
- `references.md` (imessage plugin + boop-agent paths, contract corrections)
- `standards.md` (N/A — rapture-ios has no agent-os/standards/ yet)
- `visuals/` (empty)

Then bootstrap the new repo:
1. `gh repo create NoiseMeldOrg/rapture-mac --private --clone` into `/Volumes/Dock SSD/Source/Repos/NoiseMeldOrg/`.
2. Seed `README.md`, `.gitignore` (Swift/Xcode template + `.DS_Store` + `._*`), `CLAUDE.md` (point at this spec, parity with rapture-ios), `agent-os/product/{mission.md, tech-stack.md, roadmap.md}`.
3. Copy this spec folder into `rapture-mac/agent-os/specs/` so source of truth lives there going forward.

## Phase 2: Xcode project scaffold

Create `RaptureMac.xcodeproj` in `rapture-mac/RaptureMac/`. Mirror rapture-ios's folder layout where it makes sense.

- macOS 14.0 deployment target.
- App entitlements: **no** sandbox. Hardened runtime ON (required for notarization). Add `com.apple.security.automation.apple-events` once Replier is built (Phase 7).
- `Info.plist`: `LSUIElement = YES` (no Dock icon, menu-bar-only).
- `RaptureMacApp.swift`: `@main` struct with `MenuBarExtra("Rapture for Mac", systemImage: "text.bubble") { MenuBarView() }.menuBarExtraStyle(.window)`.
- `AppState.swift`: `@Observable` container for `settings`, `state` (watermark, echo cache, stats), `errorBanner`. Held as `.environment(appState)` from root.
- Add GRDB.swift via SPM (`https://github.com/groue/GRDB.swift`).
- Folder layout:

```
RaptureMac/
  App/                     RaptureMacApp.swift, AppState.swift
  Watcher/                 ChatDBWatcher.swift, AttributedBodyDecoder.swift, MessageRow.swift
  Filter/                  MessageFilter.swift, SelfHandleResolver.swift, EchoGuard.swift
  Writer/                  FileWriter.swift
  Reply/                   Replier.swift, AppleScriptSender.swift
  UI/                      MenuBarView.swift, SettingsGeneralView.swift, SettingsAllowlistView.swift, PermissionsView.swift
  Models/                  MessageEvent.swift, CapturedMessage.swift, Settings.swift, PersistedState.swift
  Resources/               Info.plist, Assets.xcassets
```

## Phase 3: Models

- `MessageEvent`: `rowid: Int64`, `guid: String`, `text: String?`, `attributedBody: Data?`, `dateAppleNs: Int64`, `isFromMe: Bool`, `cacheHasAttachments: Bool`, `service: String`, `handleId: String?`, `chatGuid: String`, `chatStyle: Int?`. `dateUTC: Date` computed via `978_307_200 + dateAppleNs / 1_000_000_000`.
- `CapturedMessage`: post-filter struct passed to FileWriter — `messageEvent`, `decodedText`, `attachments: [AttachmentRef]`, `catchup: Bool`.
- `AttachmentRef`: `sourcePath: String`, `mimeType: String?`, `transferName: String?`.
- `Settings`: Codable struct matching the plan's `settings.json` shape, trimmed (no `cloudMode` field):
  ```swift
  struct Settings: Codable {
    var outputFolder: URL?
    var allowedHandles: [String] = []
    var allowSMS: Bool = false
    var launchAtLogin: Bool = true
    var paused: Bool = false
    var replyMode: ReplyMode = .all  // .all | .errorsOnly | .off
  }
  ```
- `PersistedState`: `chatDbWatermark: Int64`, `selfHandlesCacheTs: Date`, `recentSentEchoes: [EchoEntry]`.
- `SettingsStore` + `StateStore`: load/save to `~/Library/Application Support/Rapture for Mac/{settings.json, state.json}`. Atomic write (`.tmp` → `rename(2)`).

## Phase 4: AttributedBodyDecoder

Pure function `static func decode(_ data: Data) -> String?`. No I/O. Fully unit-testable in isolation — write fixtures from real `attributedBody` blobs (record a few from your own chat.db via a one-off `sqlite3` extract). Honor every edge case from `server.ts:82–102`.

## Phase 5: ChatDBWatcher

- Open `~/Library/Messages/chat.db` with GRDB `DatabasePool` in **read-only** mode.
- On open failure (typical cause: FDA not granted), publish a `permissionRequired(.fullDiskAccess)` state. Do not crash. UI shows the prompt (Phase 13).
- On first-ever launch: seed watermark to `SELECT MAX(ROWID) FROM message`. Persist immediately.
- Background `Task { while !cancelled { try await pollOnce(); try await Task.sleep(for: .seconds(1)) } }`.
- `pollOnce()` runs the SQL above with `WHERE m.ROWID > ?`. Maps each row → `MessageEvent`. Emits via `AsyncStream<MessageEvent>`.
- For each batch, advance watermark only **after** the downstream pipeline reports durable success. If the app crashes mid-batch, re-poll picks up where it left off.
- On every emission, also pull attachment rows for that `message_id` and attach to the event.

## Phase 6: SelfHandleResolver

- Init: run the `SELECT DISTINCT account ...` query. Strip `E:` / `p:` prefix via regex `^[A-Za-z]:`. Lowercase. Store in `Set<String>`.
- Refresh every 60s via a separate `Task`.
- Expose `func isSelf(handle: String?) -> Bool` (normalize the input the same way).

## Phase 7: MessageFilter

`func filter(_ event: MessageEvent, selfHandles: Set<String>, settings: Settings) -> FilterDecision`. Returns `.capture(decodedText:)` or `.drop(reason:)` for telemetry.

Apply in this order (mirrors `server.ts:777–798`):
1. `chat_style == nil` → drop (`reason: .unknownChatStyle`)
2. `chat_style == 43` (group) → drop (v1 ignores groups)
3. `service != "iMessage" && !settings.allowSMS` → drop (`.smsBlocked`)
4. `is_from_me == true` → drop (`.fromSelf`)
5. `handle_id == nil` → drop (`.noSenderHandle`)
6. Decode text (use `m.text` if present, else `AttributedBodyDecoder.decode(attributedBody)`)
7. Decoded empty + no attachments → drop (`.tapbackOrEmpty`)
8. **Echo guard check**: if matches a recent outbound, drop (`.echoOfOurReply`)
9. Capture if (`isSelf(handle_id)` OR `allowedHandles.contains(handle_id)`); else drop (`.notAllowlisted`)

## Phase 8: FileWriter

- `func write(_ captured: CapturedMessage, to folder: URL) async throws -> WriteResult`.
- Filename: `ISO8601` UTC of `dateUTC` with `:` → `-` (e.g., `2026-05-16T14-32-08Z.txt`). Atomic: write to `<name>.txt.tmp`, then `rename(2)`.
- Body: just the decoded text. If attachments exist, append:
  ```
  
  Attachments:
  - <sibling-folder>/<filename1>
  - <sibling-folder>/<filename2>
  ```
- Attachments: create sibling folder `<name>/`. Copy each source file. If source missing, retry once after 2s. If still missing, write the `.txt` anyway and record the failure in `WriteResult.failedAttachments`.
- Output folder unwritable / disk full / permission denied → `WriteResult.failure(reason:)` with a one-line user-facing message.

## Phase 9: AppleScriptSender + Replier + EchoGuard

- `AppleScriptSender.send(text: String, toChatGuid: String) async throws`. Invokes `/usr/bin/osascript -` via `Process`, pipes the AppleScript on stdin, passes `text` and `chatGuid` as `argv`. Script: `on run argv ↵ tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv) ↵ end run`.
- First-ever invocation triggers macOS Automation → Messages prompt. Phase 13 shows a pre-prompt.
- `Replier`: subscribes to `FileWriter` results. Composes reply:
  - Success (`.all` mode): `✓ Saved: <filename>.txt`
  - Success (`.errorsOnly` or `.off`): no reply on success
  - Failure: `✗ <reason>` (e.g., `✗ Folder not writable`)
  - `.off`: no reply ever; errors still surface in menu bar
- `EchoGuard`:
  - On `Replier.send()`, call `EchoGuard.track(chatGuid:, text:)`. Stores `(chatGuid, normalize(text), expiresAt: now + 15s)` in a bounded LRU.
  - On every inbound, `MessageFilter` calls `EchoGuard.consume(chatGuid:, text:)`.
  - `normalize(text)`: lowercase, strip ZWJ + variation selectors, smart quotes → ASCII, trim, collapse whitespace, cap at 120 chars.

## Phase 10: Catch-up after restart

- On launch, `ChatDBWatcher` reads persisted watermark. Every missed row flows through the pipeline.
- Tag each `MessageEvent` with `isCatchup: Bool`. Watcher knows it's in catch-up if the first batch after launch has > 3 rows.
- `Replier` in catch-up mode:
  - ≤3 → per-message replies as usual.
  - 4+ → suppress per-message replies. After the last file in the batch is durably written, send **one** summary to the self-chat: `📥 Caught up: <N> notes captured (<M> failed).`
  - `replyMode == .errorsOnly`: skip the success summary; still send if any failed.
  - `replyMode == .off`: no iMessage. Fire a `UNUserNotification` instead.

## Phase 11: Settings window

Tabs:
- **General**: output folder picker (`NSOpenPanel`, persist bookmark data), launch at login (`SMAppService.mainApp`), reply mode picker.
- **Allowlist**: simple `List` of handles. Self-chat is always captured implicitly.
- **About**: version, link to repo, "Last error" diag dump.

## Phase 12: Menu bar UI

Status item (`text.bubble`). Window content:
- `Local: ✓ capturing` (or `– paused` / `⚠ FDA needed` / `⚠ DB locked`)
- `Today: <N> notes`
- `Last: <relative time>`
- `Last error: <text>` (only if any)
- Divider
- `Pause capture` / `Resume capture`
- `Open notes folder`
- `Settings…`
- `Quit`

## Phase 13: Permissions UX

1. **Full Disk Access**: first chat.db read failure → modal sheet, deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`, poll every 2s.
2. **Automation → Messages.app**: first Replier `osascript` call → pre-prompt, then OS prompt fires.
3. **Folder picker**: `NSOpenPanel` with bookmark data persistence. **First-launch default**: if no folder is configured (clean install, no prior Settings file), auto-create and use `~/Documents/Rapture Notes/` so capture works immediately after FDA is granted — no forced "pick a folder" step before the first message can land. User can change the folder later in Settings → General. Surfaced during PRD shaping (2026-05-17) as load-bearing for the frictionless-onboarding promise.

## Phase 14: Distribution

- Developer ID Application cert (team `P8PLTH44DF`).
- `codesign` with hardened runtime + `--entitlements`.
- `notarytool` via API key `GX6DYX9S2M` (see rapture-ios MEMORY.md).
- Package as DMG via `create-dmg` or `hdiutil`. Staple notarization ticket.

## Verification (end-to-end)

1. Build, grant FDA, configure output folder.
2. Via Siri: *"Hey Siri, send a text to myself saying verification one."* → `.txt` lands ~1s; reply `✓ Saved: …` arrives.
3. Allowlisted contact → captures + replies.
4. Non-allowlisted contact → no capture, no reply.
5. Tapback → no capture.
6. `allowSMS=false` SMS → no capture. Flip → next SMS captures.
7. Self-message with photo → `.txt` + attachment folder.
8. Quit, send self a text, relaunch → watermark catches up.
9. Echo guard: `✓ Saved` reply not re-captured.
10. `replyMode=.errorsOnly`: success silent, failure replies.
11. `replyMode=.off`: no replies ever.
12. **Catch-up small**: 2 missed messages → 2 per-message replies.
13. **Catch-up large**: 5+ missed → one summary reply, files in send order.
14. **Catch-up with writer failure**: chmod folder `-w` mid-batch, watermark only advances past successful writes.
15. **Crash recovery**: `kill -9` mid-batch → resumes cleanly, no duplicates.

## Critical files / paths

- `~/Library/Messages/chat.db` — read source
- `~/Library/Application Support/Rapture for Mac/settings.json`
- `~/Library/Application Support/Rapture for Mac/state.json`
- `<user-chosen folder>/` — output destination

## Reference files

See `references.md`.

## Out of scope for v1

- Entire cloud mode (Sendblue, cloudflared, webhook, MMS, HMAC).
- Group chats (`chat_style == 43`).
- Multiple output folders.
- Contacts framework name resolution.
- Edit / unsend tracking.
- Mac App Store distribution.
- Auto-update.
- Two-way conversation with personal-AI consumer of folder.

## v1.1 candidates

- **Cloud mode via VPS relay** (Sendblue → hetzner VPS → push to Mac via APNs or long-poll).
- Group chat support.
- Contacts framework allowlist names.
- Auto-update via Sparkle.
