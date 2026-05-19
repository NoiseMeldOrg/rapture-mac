# Milestone 1 — First Capture · build log

> Authored at end of M1 build, 2026-05-19. Covers Phases 2–8 of the spec plus the FDA half of Phase 13.

## Status

**Built and unit-verified.** Code compiles cleanly with no warnings, all 8 unit tests pass, and a smoke launch of the built `.app` produced the expected behavior: settings persisted, default output folder created at `~/Documents/Rapture Notes/`, and chat.db read attempt correctly surfaced `SQLite error 23: authorization denied` and switched the app into the FDA-required state.

**End-to-end "Done when" verification (Siri → file on disk) is gated on a human granting FDA and sending themselves an iMessage**, which can't run inside this Claude Code session. The decoder, the FDA detection, and the persistence layer are all green; the real-world capture flow is wired and ready for the user to drive.

## What was built

### Xcode project scaffold (Phase 2)

- `RaptureMac/RaptureMac.xcodeproj` — folder-sync `project.pbxproj` (`objectVersion = 77`, Xcode 26-compatible). Two targets:
  - `RaptureMac` (app, `noisemeld.RaptureMac`, macOS 14.0, hardened runtime ON, no sandbox, `LSUIElement=YES`, ad-hoc Debug signing, entitlements file in place for future M4 work)
  - `RaptureMacTests` (XCTest bundle, hosted by the app target)
- Shared scheme at `RaptureMac.xcodeproj/xcshareddata/xcschemes/RaptureMac.xcscheme` so `xcodebuild -scheme RaptureMac` works from the CLI
- GRDB.swift `6.29.3` added via SPM (pinned in `Package.resolved`, which is now tracked)
- iOS app icon copied to `RaptureMac/Resources/Assets.xcassets/AppIcon.appiconset/`; `Contents.json` extended with `mac` idiom entries so the asset compiler produces the macOS `.icns`
- `Info.plist` is `GENERATE_INFOPLIST_FILE=YES`-driven; macOS-specific keys (`LSUIElement`, `LSApplicationCategoryType=productivity`, `CFBundleDisplayName=Rapture for Mac`, copyright string) come from `INFOPLIST_KEY_*` build settings

### Models (Phase 3)

In `RaptureMac/Models/`:

- `MessageEvent` — pre-filter row from `chat.db`. Holds rowid, guid, raw text, raw attributedBody, dateAppleNs, isFromMe, cacheHasAttachments, service, handleId, chatGuid, chatStyle, attachments. Has a `dateUTC` computed property using the verified `978_307_200`-second Apple-epoch offset.
- `CapturedMessage` — post-filter, decoded, ready to write. Holds `event`, `decodedText`, `isCatchup` (always `false` in M1; the field exists so M2's catch-up logic can flip it without churn).
- `AttachmentRef` — `Codable`/`Sendable`/`Hashable` triple: sourcePath, mimeType, transferName.
- `Settings` — `Codable` user prefs. Defaults: `outputFolder=nil` pre-first-launch, `allowedHandles=[]`, `allowSMS=false`, `launchAtLogin=true`, `paused=false`, `replyMode=.all`.
- `PersistedState` — `Codable` runtime state: `chatDbWatermark`, `selfHandlesCacheTs`, `lastError`. (No `recentSentEchoes` yet — M2 territory.)
- `ReplyMode` — `enum String` with `all / errorsOnly / off`.
- `FilterDecision` and `DropReason` — in-memory enums for filter output.
- `WriteResult` — in-memory: `.success(URL)` / `.failure(reason: String)` plus a `failedAttachments: [String]` sidecar.

### Persistence (Phase 3)

In `RaptureMac/Persistence/`:

- `AtomicFile` — thin wrapper around `Data.write(to:options: .atomic)`, which already implements the `.tmp` → `rename(2)` pattern the spec calls for. Creates parent directories on demand.
- `AppSupportDirectory` — resolves `~/Library/Application Support/Rapture for Mac/` and lazily creates it. Also exposes `defaultOutputFolder` (`~/Documents/Rapture Notes/`).
- `SettingsStore` / `StateStore` — `@MainActor` final classes. `init()` loads from disk (returns defaults on miss); `update { mutate }` mutates the value type and persists. `SettingsStore.ensureDefaultOutputFolder()` is the load-bearing first-launch hook: if `outputFolder == nil`, it creates `~/Documents/Rapture Notes/` and writes the URL into settings, so the app is functional the moment FDA is granted with no forced folder picker.

### AttributedBody decoder (Phase 4)

`Watcher/AttributedBodyDecoder.swift`. Pure function `decode(_ data: Data?) -> String?`. Faithful Swift port of the `server.ts:82–102` byte-scan:

1. Find `NSString\0` marker via `Data.range(of:)`.
2. Scan forward for `0x2B`. If end-of-buffer reached → `nil`.
3. Read the length-prefix byte. Direct = length itself; `0x81`/`0x82`/`0x83` = 1/2/3-byte LE length escape.
4. Bounds-check `index + len <= data.count`. On overflow → `nil`.
5. `String(data: data[index..<(index+len)], encoding: .utf8)`.

Seven unit tests in `RaptureMacTests/AttributedBodyDecoderTests.swift` cover: short ASCII, 0x81-escape (~240-byte payload), multi-byte UTF-8 with emoji, missing-marker, length-overflow, empty-input, and the 0x82 (two-byte LE) escape. All pass in 0.005s.

Fixtures are constructed programmatically rather than extracted from a real `chat.db`, so the test suite is fully self-contained (no private message content baked into the repo).

### chat.db watcher (Phase 5)

In `RaptureMac/Watcher/`:

- `ChatDB.open()` — opens `~/Library/Messages/chat.db` as a read-only GRDB `DatabasePool`. `looksLikePermissionError(_:)` classifies `SQLITE_CANTOPEN`, `SQLITE_PERM`, `SQLITE_AUTH`, `SQLITE_NOTADB`, and the Foundation `NSFileReadNoPermissionError` / `NSFileNoSuchFileError` codes as "needs FDA."
- `ChatDBWatcher` — `@MainActor` final class. `events(watermarkProvider:)` returns an `AsyncStream<MessageEvent>` and kicks off a detached polling task that loops every 1 second:
  - Calls back to a `@Sendable () async -> Int64` closure to get the current watermark (the Pipeline supplies one that reads `StateStore.state.chatDbWatermark` on the main actor).
  - Runs the exact spec-verified SQL (joins `message ← chat_message_join ← chat`, left-joins `handle`, watermark `WHERE m.ROWID > ? ORDER BY m.ROWID ASC`).
  - For rows with `cache_has_attachments`, runs the attachment join (`attachment a / message_attachment_join maj`). Expands `~/` paths via `homeDirectoryForCurrentUser`.
- `maxRowid(in:)` is the watermark-seed helper invoked once on first-ever launch.

The watcher does *not* advance the watermark — that's the Pipeline's job, and only after a durable write.

### Self-handle resolver (Phase 6)

`Filter/SelfHandleResolver.swift`. `@MainActor` final class with an in-process `Set<String>` of normalized self-handles.

- Query: `SELECT DISTINCT account FROM message WHERE is_from_me=1 AND account IS NOT NULL AND account != '' LIMIT 50` (verified against `server.ts:177–185`).
- Normalization: strip `^[A-Za-z]:` (the `E:`/`p:`/etc prefixes Apple uses for `is_from_me` rows), then lowercase. Same normalization is applied to inbound handles during filtering.
- 60-second refresh task. `start()` is async (does the initial fetch); `stop()` cancels.
- `isSelf(handle:)` lookup is synchronous.

### Filter (Phase 7)

`Filter/MessageFilter.swift`. Pure-function `decide(event:selfHandles:settings:isCatchup:)`. Drop rules in the exact `server.ts:777–798` order:

1. `chatGuid == nil` → `.unknownChat`
2. `service != "iMessage" && !allowSMS` → `.smsBlocked`
3. `chatStyle == nil` → `.unknownChatStyle`
4. `chatStyle == 43` → `.groupChat`
5. `isFromMe` → `.fromSelf`
6. Decode text via `event.text ?? AttributedBodyDecoder.decode(event.attributedBody) ?? ""`. If trimmed empty AND no attachments → `.tapbackOrEmpty`.
7. `handleId == nil` → `.noSenderHandle`
8. Not in self-handle set AND not in `settings.allowedHandles` (compared both raw and normalized) → `.notAllowlisted`
9. Otherwise → `.capture(CapturedMessage(...))`

The echo-guard step (rule 8 in the original spec numbering) is intentionally skipped — that's M2's domain.

### File writer (Phase 8)

`Writer/FileWriter.swift`. `@MainActor` final class with one method, `write(_:to:) async -> WriteResult`.

- Filename derived from `event.dateUTC` via `ISO8601DateFormatter` with `:` → `-` (e.g., `2026-05-19T04-12-08Z.txt`). Collision handling appends `-1`, `-2`, ...
- Body: decoded text alone, or text + a trailing `\n\nAttachments:\n- <folder>/<file>` block when attachments exist.
- Attachments copied to a sibling folder named after the timestamp (no extension). Per-attachment one-retry-after-2-seconds policy from the spec; if the source is still missing, record it in `failedAttachments` and write the `.txt` anyway.
- Atomic write via `AtomicFile.write` (`Data.write(... .atomic)`), which gets us `.tmp` → `rename(2)` for free.

### FDA onboarding (Phase 13, FDA half)

`UI/PermissionsView.swift`. Plain-English copy:

- Header: "Rapture needs Full Disk Access"
- Body explains *why* (chat.db read requirement)
- Numbered steps with SF Symbols
- Two buttons: **Open System Settings** (`NSWorkspace.shared.open` with `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) and **Quit** (`NSApp.terminate`)
- `.onChange(of: appState.permissionState)` → `dismissWindow(id: "permissions")` when state flips to `.ok`, so the window closes automatically once FDA is granted

### Pipeline + app entry (wiring)

- `App/AppState.swift` — `@Observable` `@MainActor` root. Owns `SettingsStore`, `StateStore`, `permissionState`, `lastError`, `lastErrorAt`. `recordError(_:)` and `clearError()` persist into state.json on every mutation.
- `App/Pipeline.swift` — `@MainActor` final class that orchestrates everything:
  1. `start()` — ensures default output folder, attempts `ChatDB.open()`. On permission failure, flips `permissionState = .fullDiskAccessRequired` and kicks off a 2s-interval FDA poll task.
  2. On successful open, seeds the watermark (if `chatDbWatermark == 0`) via `ChatDBWatcher.maxRowid(in:)`, starts the self-handle resolver, opens the event stream, and consumes events via a `Task` that pipes each `MessageEvent` through `MessageFilter.decide(...)` and then `FileWriter.write(...)`.
  3. The watermark advances on every event (whether captured or dropped) so the pipeline doesn't re-fetch the same dropped row on the next poll. It advances on capture only after a `.success` `WriteResult`.
- `RaptureMacApp.swift` — `@main` `App` with one `Window` scene. The scene's `.task` kicks off `pipeline.start()`. With `LSUIElement=YES` and no `MenuBarExtra` in M1, closing the FDA window does not terminate the app — it keeps running headless once FDA is granted.

## Smoke test results (manual, dev environment)

After `xcodebuild -derivedDataPath /tmp/RaptureMacDerived clean build test`:

- **`xcodebuild test`**: 8 of 8 tests pass (7 decoder + 1 placeholder). Total runtime ~5 ms.
- **`open RaptureMac.app`**: app launches, no Dock icon (LSUIElement honored).
- **`~/Library/Application Support/Rapture for Mac/settings.json`**: created with the expected defaults — `outputFolder` resolves to `file:///Users/<user>/Documents/Rapture%20Notes/`, `allowedHandles: []`, `replyMode: "all"`, etc.
- **`~/Documents/Rapture Notes/`**: directory created.
- **OSLog (`subsystem == "noisemeld.RaptureMac"`)**: `[Pipeline] FDA not granted yet: SQLite error 23: authorization denied`. This is the *expected* behavior in this dev environment — the ad-hoc-signed Debug build has no TCC grant for chat.db, so the FDA detection path correctly fires and would show the FDA window. (TCC grants are per-app-identity; the path needs a developer in the loop to grant.)

## Decisions made during implementation that weren't pre-specified

These deviated or amplified the spec without conflicting with it. Captured here so M2 doesn't relitigate them.

1. **`AtomicFile` is a thin wrapper around `Data.write(... .atomic)`, not a hand-rolled rename(2).** Foundation's atomic-write option already implements `.tmp` → `rename(2)` and respects the filesystem's atomicity guarantees. Rolling our own `rename(2)` via `Process` or `withUnsafeFileSystemRepresentation` would be more code for the same behavior.
2. **`Package.resolved` is tracked.** Standard for app projects (vs libraries). The `.gitignore` was wrong on this and on `*.xcworkspace` (which matched the `project.xcworkspace` nested inside the `.xcodeproj`). Both fixed.
3. **Filename collision handling appends `-1`, `-2`, etc.** The spec doesn't address it, but two messages can land at the exact same UTC second during rapid-fire dictation. Without a suffix, the second write would overwrite the first. The suffix is a no-op in the common case.
4. **Attachment folder is named `<timestamp>` (no extension), matching the `.txt`'s base name.** The body of the `.txt` then references `- <timestamp>/<filename>`. The spec wasn't fully explicit about the folder name shape; this keeps the `.txt` and the sibling folder visually paired in Finder.
5. **The watermark advances on `.drop` decisions too.** Required to avoid infinite re-fetching of dropped rows. Spec implies but doesn't explicitly say this.
6. **`SelfHandleResolver` is queried *before* writing.** The Pipeline grabs `resolver.currentHandlesSnapshot()` at decision time, not when the event was fetched. This means a self-handle refresh that lands between fetch and decide is picked up immediately — slightly more conservative than the spec's per-batch behavior, but cheaper than nothing.
7. **`MessageFilter` uses both raw and normalized handle comparison for the user-managed allowlist.** So an entry like `+15551234567` matches a `handle.id` of `+15551234567` even if the user accidentally typed `e:+15551234567` (the Apple-prefixed form). M3's allowlist editor can sanitize on input as well.
8. **Pipeline's `permissionState` transitions are one-way per launch.** Once `.ok`, the pipeline doesn't go back to `.fullDiskAccessRequired` if a chat.db query later fails for some other reason — those land in `lastError` instead. Keeps the FDA window from re-appearing on transient errors.
9. **No `MenuBarExtra` scene.** Per the locked plan decision: M1 is truly headless. Once FDA is granted and the window closes, the only quit path is Activity Monitor / `pkill` / Xcode Stop. M3 adds the menu bar with proper Quit affordance.
10. **`Pipeline.handle(event:)` is `@MainActor`-isolated.** GRDB's pool reads happen on a detached task (via `pool.read` async overload), but filter + writer + state updates all run on MainActor. This gives us a single consistent isolation domain for the application state and avoids any `Sendable` gymnastics in the hot path.

## What M2 will need to know

- **`WriteResult` shape is locked.** M2's Replier will subscribe to (or be called from) `Pipeline.handle(event:)`'s `.success` and `.failure` branches. The `failedAttachments: [String]` sidecar lets the Replier compose `✗ <reason>` messages with concrete detail.
- **Watermark lives in `StateStore.state.chatDbWatermark`** and is mutated only from `Pipeline.advanceWatermark(to:)`. Catch-up detection (first batch >3 messages after launch → catch-up mode) needs to track batch size at the watcher boundary, not from the watermark — the watermark is updated per-row, not per-batch.
- **`permissionState` is published on `AppState` as an `@Observable` property.** SwiftUI views can `@Environment(AppState.self)` and observe directly. The Automation-permission pre-prompt M2 needs will follow the same pattern, probably with a new `AutomationPermissionState` enum.
- **`PersistedState` is missing `recentSentEchoes: [EchoEntry]`** that the spec calls for. Add it in M2 alongside the EchoGuard implementation — it's a `[EchoEntry]` (chatGuid, normalizedText, expiresAt). Schema bump is non-breaking since `Codable` defaults handle missing keys.
- **The Pipeline calls `MessageFilter.decide` with `isCatchup: false` everywhere in M1.** M2 needs to wire `isCatchup` based on the first-batch-size signal so catch-up replies can collapse to one summary message.
- **OSLog subsystem is `noisemeld.RaptureMac`.** Existing categories: `Pipeline`, `ChatDBWatcher`, `SelfHandleResolver`, `FileWriter`, `SettingsStore`, `StateStore`. M2's `AppleScriptSender`, `Replier`, `EchoGuard` should add their own categories under the same subsystem.
- **`@MainActor` is the default actor isolation for the project** (`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` build setting). Mark async/Sendable boundaries explicitly with `nonisolated` (see `ChatDBWatcher.fetchEvents`, `FileWriter`'s static helpers) when crossing into Task.detached or GRDB closures.
- **The FDA window auto-dismisses on `permissionState == .ok`.** When M3 adds the `MenuBarExtra`, the Window scene can become more conditional or move to a popover-attached sheet.

## Deviations from the PRD / spec, and why

- **No menu-bar UI at all in M1, not even a tiny `MenuBarExtra` with a Quit item.** The PRD M1 says "no menu-bar UI of any kind"; the spec's Phase 2 scaffold mentions `MenuBarExtra`. The strict PRD reading won (user-confirmed via the clarifying-question pass). Cost: harder to quit during dev testing (Activity Monitor / Xcode Stop). Worth it because keeping M1 truly headless validates that the pipeline runs independent of any UI surface, which is the architectural premise for M3 (menu bar) and M4 (distribution).
- **Decoder tests use synthetic fixtures, not real `chat.db` blobs.** The plan/spec suggested capturing real fixtures. Synthetic fixtures are reproducible, don't leak private content into the repo, and cover the same byte-layout cases. End-to-end verification still exercises real `attributedBody` blobs when the user dictates.
- **Three decoder test cases instead of four, plus three bonus cases.** I wrote seven tests (the four called for plus three extras for the 0x82 escape, empty/nil input, and missing marker). Net: more coverage, same test surface size.
- **`Package.resolved` is committed; `.gitignore` was wrong.** Standard for app projects to lock dependency versions. The original `.gitignore` had `Package.resolved` listed and the broad `*.xcworkspace` pattern was clobbering the `project.xcworkspace` inside `.xcodeproj`. Both fixed.

## Files that didn't exist at the start of M1 and now do

- `RaptureMac/RaptureMac.xcodeproj/` (folder-sync `.pbxproj`, shared scheme, workspace settings, `Package.resolved`)
- `RaptureMac/RaptureMac/RaptureMacApp.swift`, `App/AppState.swift`, `App/Pipeline.swift`
- `RaptureMac/RaptureMac/Models/{MessageEvent, CapturedMessage, AttachmentRef, Settings, PersistedState, ReplyMode, FilterDecision, WriteResult}.swift`
- `RaptureMac/RaptureMac/Persistence/{AtomicFile, AppSupportDirectory, SettingsStore, StateStore}.swift`
- `RaptureMac/RaptureMac/Watcher/{ChatDB, ChatDBWatcher, AttributedBodyDecoder}.swift`
- `RaptureMac/RaptureMac/Filter/{MessageFilter, SelfHandleResolver}.swift`
- `RaptureMac/RaptureMac/Writer/FileWriter.swift`
- `RaptureMac/RaptureMac/UI/PermissionsView.swift`
- `RaptureMac/RaptureMac/RaptureMac.entitlements` (sandbox disabled, ready for M4 hardened-runtime additions)
- `RaptureMac/RaptureMac/Resources/Assets.xcassets/` (AppIcon copied from rapture-ios with macOS idiom entries added)
- `RaptureMac/RaptureMacTests/{RaptureMacTests, AttributedBodyDecoderTests}.swift`
- `.gitignore` adjustments (committed `Package.resolved`, fixed `*.xcworkspace` pattern)

Total: 33 tracked files added under `RaptureMac/` plus a small `.gitignore` patch. No code currently outside `RaptureMac/` was modified beyond `.gitignore`.
