# Milestone 2 — Confirmation & Recovery · build log

> Authored at end of M2 build, 2026-05-19. Covers Phases 9–10 of the spec plus the Automation half of Phase 13.

## Status

**Built and unit-verified.** All 44 unit tests pass (M1's 8 + M2's 36). Build completes cleanly with zero warnings under Swift 5 mode. The data-plane and reply-plane are wired end-to-end inside `Pipeline → BatchProcessor → Replier → AppleScriptSender`.

**End-to-end "Done when" verification (Siri-dictated message → `.txt` file + `✓ Saved` reply on phone) is gated on a human granting Automation permission and sending themselves an iMessage** — it can't run inside this Claude Code session, since the first send triggers macOS's TCC Automation dialog which only a person at the keyboard can answer.

## What was built

### Models (Phase 3 additions)

In `RaptureMac/Models/`:

- `EchoEntry` — `Codable Sendable Equatable` triple holding `chatGuid`, `normalizedText`, `expiresAt`. One entry per outbound reply Rapture sends. Persisted into `state.json`.
- `AutomationPermissionState` — `unknown / prePromptPending / required / ok` enum. Observable on `AppState`; mirrors the existing `permissionState` pattern from M1's FDA flow.
- `PersistedState` extended with `recentSentEchoes: [EchoEntry] = []` and `automationPrePromptShown: Bool = false`. Custom `init(from:)` uses `decodeIfPresent` with defaults for both new keys, so M1-vintage `state.json` files decode without migration.

### EchoGuard (Phase 9)

`Filter/EchoGuard.swift`. `@MainActor final class` backed by `StateStore`, plus three pure `nonisolated static` helpers that hold all the logic and carry full test coverage:

- `normalize(_:)` — 7-step pipeline mirroring `server.ts:431–457`: strip `" Sent by Claude"` suffix (case-insensitive, end-anchored) → strip ZWJ + variation selectors → smart quotes to ASCII → lowercase → collapse whitespace runs → trim → cap at 120 chars. 13 EchoGuardTests cover each step.
- `appendEntry(into:chatGuid:text:now:)` — appends with TTL, prunes expired in the same pass.
- `consumeMatch(from:chatGuid:text:now:)` — returns `(matched: Bool, remaining: [EchoEntry])`. Matching is one-shot (consumed entries are dropped).

The `@MainActor` instance methods `track()` and `consume()` are thin wrappers that read/mutate `StateStore.state.recentSentEchoes`. 15-second TTL is implicit (no explicit LRU cap) — the window is small enough that the array stays bounded by traffic, not by an arbitrary limit.

### SelfChatResolver (new — required for catch-up summary)

`Filter/SelfChatResolver.swift`. `@MainActor final class` that resolves the canonical self-chat GUID at startup so the catch-up summary always lands in the user's self-chat thread (per locked decision #1 with user during planning).

- SQL: `SELECT c.guid FROM chat c JOIN chat_handle_join chj ON chj.chat_id = c.ROWID JOIN handle h ON h.ROWID = chj.handle_id WHERE c.style = 45 AND LOWER(h.id) IN (?,?,...) LIMIT 1`.
- 5-minute refresh cadence (slower than `SelfHandleResolver`'s 60s — the self-chat GUID rarely changes once Apple has assigned one).
- Receives its self-handles via a `@MainActor () -> Set<String>` closure that captures `SelfHandleResolver` weakly. This avoids tight coupling and keeps the resolver testable.

### AppleScriptSender (Phase 9, sender half)

`Reply/AppleScriptSender.swift`. `nonisolated final class` (default-actor-isolation for the project is MainActor, so the `nonisolated` annotations are explicit) implementing the spec-verified osascript contract:

- `script` static is a frozen string matching `server.ts:418–424` literally: `on run argv ↵ tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv) ↵ end run`. Tested for byte-equality against the spec contract.
- `send(text:toChatGuid:)` spawns `/usr/bin/osascript -` via `Process`, pipes the script on stdin, passes `[text, chatGuid]` as argv. Captures stderr.
- On `exitCode != 0`, throws `AppleScriptSendError(exitCode:stderr:)`. `isPermissionDenied` classifier matches three TCC patterns: `-1743`, `"Not authorized to send Apple events"`, and `"Not allowed to send Apple events to application Messages"`. 5 AppleScriptSenderTests cover the classifier matrix plus the script byte-equality check.
- Work runs in `Task.detached(priority: .userInitiated)` so the @MainActor consumer task doesn't block on the subprocess.

### Replier (Phase 9, composer half)

`Reply/Replier.swift`. `@MainActor final class` orchestrating per-message and catch-up replies. Surface:

- `replyForWrite(captured:result:settings:)` — per-message reply. Skips when `captured.isCatchup == true`. Composes text via the pure helper below; sends via `sendChat(...)`.
- `sendCatchupSummary(successCount:failureCount:selfChatGuid:replyMode:)` — single summary reply. Resolves destination (chat vs notification) via the pure helper; routes accordingly.
- `composeReplyText(replyMode:outcome:)` — pure helper. `.all + success → "✓ Saved: <filename>"`, `.all + failure → "✗ <reason>"`, `.errorsOnly + success → nil`, `.errorsOnly + failure → "✗ <reason>"`, `.off → nil`. (Locked decision #2 with user: Replier respects `Settings.replyMode` now; M3 just adds the UI picker.)
- `composeCatchupText(successCount:failureCount:)` — pure. `"📥 Caught up: N notes captured"` when `failureCount == 0`, `"📥 Caught up: N notes captured (M failed)"` otherwise.
- `catchupDestination(replyMode:selfChatGuid:)` — pure. Returns `.notification` when `replyMode == .off` OR `selfChatGuid == nil`; `.chat(guid)` otherwise. **Note**: `.errorsOnly` does *not* suppress catch-up summaries (a summary that's purely informational is still useful when running in errors-only mode; only `.off` silences everything). Documented in `ReplierTests.testCatchupDestinationNotificationWhenErrorsOnlyAndSelfChatKnown`.
- Per-send flow inside `sendChat`:
  1. **Pre-prompt gate**: if `state.automationPrePromptShown == false`, set `appState.automationPermissionState = .prePromptPending`, run `AutomationPrompt.showPrePrompt()` (NSAlert.runModal), persist the flag, then proceed.
  2. Send via `AppleScriptSender`. On success: `echoGuard.track(...)` and flip state to `.ok`.
  3. On `AppleScriptSendError.isPermissionDenied`: flip state to `.required`, show `AutomationPrompt.showDenied()` (NSAlert with "Open System Settings" deep-link), record error.

### NotificationDispatcher (Phase 10, fallback plumbing)

`Reply/NotificationDispatcher.swift`. Thin wrapper around `UNUserNotificationCenter`. Used only by the catch-up summary fallback (when `replyMode == .off` OR `selfChatGuid == nil`). Per-message notifications are M3 territory.

- `send(title:body:)` schedules an immediate notification (1-second trigger, since UN rejects truly-instant triggers).
- `requestAuthorizationIfNeeded()` requests `[.alert, .sound]` on first use.
- `@preconcurrency import UserNotifications` + `@unchecked Sendable` are required because `UNUserNotificationCenter` isn't yet annotated for Swift 6's strict concurrency.

### Automation Prompts (Phase 13, Automation half)

`Reply/AutomationPrompt.swift`. Pivoted from the originally-planned SwiftUI `Window` scene to `NSAlert.runModal()` during implementation — see "Decisions" below for the trade-off.

- `showPrePrompt() -> .proceed | .quit` — first-send explainer. "Rapture is about to reply in your Messages thread… macOS will ask whether to allow that." Two buttons: Continue / Quit.
- `showDenied()` — recovery flow after a `-1743` denial. "Open System Settings → Privacy & Security → Automation, find Rapture for Mac, turn Messages on." Buttons: Open System Settings / Dismiss.

### BatchProcessor (new — extracted from Pipeline for testability)

`App/BatchProcessor.swift`. `@MainActor final class` that owns the per-batch orchestration: filter → echo check → write → reply. Extracted from `Pipeline.handle(event:)` so the catch-up decision can be unit-tested without standing up chat.db / SelfHandleResolver.

- Tracks `isFirstNonemptyBatchSeen: Bool` privately.
- `isCatchup(batchSize:isFirstNonemptyBatchSeen:)` pure helper exposed for tests. Returns `true` when the first non-empty batch has more than 3 events; subsequent batches are always live mode. 6 BatchProcessorTests cover the matrix.
- Per-event flow:
  1. `MessageFilter.decide(...)` with the batch-level `isCatchup` propagated to `CapturedMessage`.
  2. On `.drop`: advance watermark, log, accumulate `droppedCount`.
  3. On `.capture`:
     - **Echo guard check** (Pipeline-side, not in `MessageFilter`, to keep the filter pure): `echoGuard.consume(chatGuid:, text:)`. On match → drop, advance watermark.
     - Otherwise write via `FileWriter`. On `.success`: advance watermark, fire per-message reply (unless `isCatchup`).
     - On `.failure`: record error, fire per-message error reply.
- After the batch is processed: if `isCatchup`, fire `replier.sendCatchupSummary(...)` with the accumulated counts.

### ChatDBWatcher API change

`Watcher/ChatDBWatcher.swift`. Return type of `events(watermarkProvider:)` changed from `AsyncStream<MessageEvent>` to `AsyncStream<[MessageEvent]>` (locked decision #3 with user during planning).

- Yields the entire poll result as one batch.
- Skips yielding when the poll returns zero events — `isFirstNonemptyBatchSeen` only flips on the first non-empty batch, so a long idle period at launch doesn't accidentally consume the catch-up trigger.
- Also marked `static let log` as `nonisolated` to silence a pre-existing Swift 6 warning about cross-actor log access from inside `Task.detached`.

### Pipeline integration

`App/Pipeline.swift` rewired:

- Constructs `EchoGuard`, `AppleScriptSender`, `NotificationDispatcher`, `Replier` lazily in `init` (so they exist before `start()` is called and before `dbPool` is available).
- `beginCapture(with:)` startup order: seed watermark → start `SelfHandleResolver` → start `SelfChatResolver` (which depends on the self-handle set) → construct `BatchProcessor` (which depends on both resolvers + replier + echoGuard) → start watcher → consume batches.
- Consumer task iterates `for await batch in stream { await batchProcessor.process(batch:) }`. Catchup detection lives in BatchProcessor.
- `stop()` cancels both resolvers, the FDA poll task, the consumer task, the watcher.

### Entitlements

`RaptureMac.entitlements` — added `com.apple.security.automation.apple-events = true`. Required for `osascript` to control Messages.app under hardened runtime (which will be turned on in M4).

## Tests added

| Suite | Count | Coverage |
|---|---:|---|
| `EchoGuardTests` | 13 | normalize matrix (suffix strip, ZWJ, smart quotes, whitespace, cap, lowercase, integration), `appendEntry` + `consumeMatch` pure helpers (match, mismatch, TTL expiry, pruning, one-shot consumption) |
| `AppleScriptSenderTests` | 5 | script byte-equality against spec, `isPermissionDenied` classifier matrix (`-1743`, "Not authorized", "Not allowed"), unrelated-error negative case, `userFacingMessage` formatting |
| `ReplierTests` | 12 | full `composeReplyText` matrix (3 modes × 2 outcomes), `composeCatchupText` (with and without failures, zero-success edge case), `catchupDestination` (chat / notification fallback / errorsOnly) |
| `BatchProcessorTests` | 6 | `isCatchup` decision matrix (1/3/4/5 first-batch, non-first-batch-of-10, threshold sentinel) |
| **M1 carry-over** (8) | **8** | `AttributedBodyDecoder` and the placeholder compile-check, all still green |
| **Total** | **44** | |

All 44 tests pass in 0.027s.

## Verification commands

Per M1's environment notes (the source SSD's exFAT generates `._*` AppleDouble files that break codesign — derived data must live on the internal APFS):

```sh
xcodebuild -derivedDataPath /tmp/RaptureMacDerived -scheme RaptureMac clean build  # ** BUILD SUCCEEDED **
xcodebuild -derivedDataPath /tmp/RaptureMacDerived -scheme RaptureMac test         # ** TEST SUCCEEDED **
```

Both run clean with zero warnings.

## Decisions made during implementation that weren't pre-specified

These deviated from the plan (in some cases) but didn't conflict with the PRD or spec. Captured here so M3 doesn't relitigate them.

1. **Automation pre-prompt UX is `NSAlert.runModal()`, not a SwiftUI `Window` scene.** The plan called for a second SwiftUI Window scene with state-driven content. During implementation, the friction of coordinating cross-scene state from a `@MainActor` class (Replier needs to *open* a SwiftUI Window, but `openWindow` is a SwiftUI environment value accessible only inside a `View` body) turned out to be load-bearing complexity for a one-shot dialog with two buttons. `NSAlert.runModal()` is native, blocks the main thread until acknowledged (which is exactly the semantics Replier wants — pause the pipeline until the user OKs the OS prompt), and required zero plumbing. The plan's `AutomationPrePromptView.swift` got replaced by `AutomationPrompt.swift` (an enum with two static methods). If M3 wants this surfaced inside the menu-bar UX instead of as a system alert, that's a deliberate change at that point.

2. **Echo guard check happens in `BatchProcessor`, not in `MessageFilter`.** The spec lists echo guard as filter rule #8. Implementing it that way would force `MessageFilter` to take shared mutable state, breaking its pure-function testability. Moving the check into `BatchProcessor.process(batch:)` right after `MessageFilter.decide` returns `.capture` keeps the filter testable and concentrates all the stateful "did we just send this?" logic in one place.

3. **EchoGuard exposes pure `nonisolated static` helpers (`appendEntry`, `consumeMatch`) and routes the `@MainActor` instance methods through them.** This pattern lets the test suite hit the core logic (TTL, one-shot match, pruning) without standing up a real `StateStore` (which would write to `~/Library/Application Support/Rapture for Mac/state.json`). Same pattern in `Replier` (composition helpers) and `BatchProcessor` (`isCatchup` helper). Mirrors M1's `AttributedBodyDecoder` style.

4. **`SelfChatResolver` refresh cadence is 5 minutes, not 60 seconds.** SelfHandleResolver runs hot (60s) because new self-handles can appear when the user adds an email to their iCloud account. The self-chat GUID, once Apple assigns it, doesn't change. 5 minutes is the relaxed cadence; the resolver is started after SelfHandleResolver completes its first fetch so it has a non-empty handle set on its first SQL query.

5. **`.errorsOnly` does NOT suppress the catch-up summary.** The PRD lists catch-up logic and reply-mode independently. A natural reading of `.errorsOnly` is "only send replies on failures" — which would suggest skipping the `📥 Caught up: 5 notes captured` summary if all 5 succeeded. The catch-up summary is *informational* (a state-recovery confirmation, not a per-message acknowledgement), and `.errorsOnly` is the kind of mode chosen by someone who finds per-message replies noisy but still wants to know when something significant happens. So `.errorsOnly` still produces the catch-up summary; only `.off` silences it (falling back to `UNUserNotification`). Documented in test `testCatchupDestinationNotificationWhenErrorsOnlyAndSelfChatKnown` so the next person who looks at this has the rationale immediately to hand.

6. **`AutomationPermissionState` has four cases (`unknown`, `prePromptPending`, `required`, `ok`), not the three planned.** `prePromptPending` was added during implementation to give the UI a way to distinguish "user has never seen the pre-prompt" from "user has seen the OS prompt and may have been denied." M3's menu bar can use this if surfacing "Automation: ⚠ pre-prompt outstanding" is useful.

7. **`PersistedState` decoder uses a custom `init(from:)` with `decodeIfPresent` defaults**, rather than Codable's auto-derivation. This handles the M1 → M2 schema bump silently: existing `state.json` files written by M1 don't have `recentSentEchoes` or `automationPrePromptShown` keys, but they decode fine and pick up the defaults.

8. **Swift 6 strict-concurrency warnings in M1 code were cleaned up while we were touching neighboring files.** `ChatDBWatcher.log` and `FileWriter`'s `FileManager` extension method are now `nonisolated`; `Pipeline`'s captured `stateStore` weak reference was replaced with a strong capture of `appState` (which is `@MainActor` and therefore `Sendable`). The build now produces zero warnings under Swift 5 mode, and is closer to Swift-6-clean.

## What M3 will need to know

- **`Settings.replyMode` is already honored** by `Replier.composeReplyText` / `composeCatchupText` / `catchupDestination`. M3 just adds the UI picker and writes through `SettingsStore.update { $0.replyMode = newMode }`. No code change in Replier required.
- **`appState.automationPermissionState` is observable** the same way M1's `permissionState` is. M3's menu-bar UI can surface `"⚠ Automation needed"` when it equals `.required`. The `.prePromptPending` state is rarely visible (it's set just before `NSAlert.runModal` blocks) but exists if M3 wants to drive a non-modal indicator.
- **`BatchProcessor` accumulates `successCount` / `failureCount` per batch** in its return value (`BatchOutcome`). M3's menu-bar "Today: N notes" counter can sum these into a per-day running total — wire it from inside the Pipeline's consumer task.
- **The Reply layer doesn't know about pause.** If `Settings.paused == true`, today the watcher still polls and `BatchProcessor` still processes — replies fire, files write. M3 needs to either gate at the watcher (cleanest), at BatchProcessor (preserves catch-up semantics on resume), or at the writer (preserves replies on already-captured messages, which doesn't make sense). Recommend gating at BatchProcessor entry: skip processing entirely when paused. The watermark stays put; resume continues from where it left off.
- **`NotificationDispatcher` is wired but currently only used by the catch-up summary fallback.** M3 may want to use it for per-message replies when `replyMode == .off` (the spec says "errors still surface in the menu bar" — that's M3's job, not a notification spam plan).
- **`AutomationPrompt.showDenied()` opens a deep-link to `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation`.** M3's About / Diagnostics tab can use the same URL for a "Re-check Automation permission" button.
- **`EchoGuard.track / consume` are the integration points** if M3 ever needs to manually invalidate echoes — e.g., if the user changes the output folder mid-stream and a queued `✓ Saved: <oldfolder>/...` reply is no longer accurate.
- **OSLog subsystem is `noisemeld.RaptureMac`.** New categories from M2: `EchoGuard`, `SelfChatResolver`, `AppleScriptSender`, `Replier`, `BatchProcessor`, `NotificationDispatcher`.

## Deviations from the PRD / plan, and why

- **`AutomationPrePromptView.swift` (SwiftUI Window scene) → `AutomationPrompt.swift` (NSAlert helpers).** See decision #1 above.
- **The plan called out a `Replying` protocol for testability.** Implementation went with extracting pure-function composition helpers on `Replier` instead. Same testability outcome, less type-system ceremony, no protocol-conformance overhead in production code paths. `BatchProcessor` depends on the concrete `Replier` directly; the catchup-decision logic that needed isolated testing was the `isCatchup` pure helper, not the full Replier interface.
- **`Replier.prePromptHandler` is injected via constructor closure (`@MainActor () -> Bool`), not via `prePromptCoordinator` protocol** as the plan suggested. Both achieve the same testability seam; the closure is simpler and avoids defining a single-method protocol.
- **No `AutomationPermissionState.unknown` → `.required` direct transition tested.** The flow is `unknown → prePromptPending → ok` on success, or `unknown → prePromptPending → required` on denial. The state machine is small enough that unit-testing every transition felt like ceremony.

## Files that didn't exist at the start of M2 and now do

- `RaptureMac/RaptureMac/Models/EchoEntry.swift`
- `RaptureMac/RaptureMac/Models/AutomationPermissionState.swift`
- `RaptureMac/RaptureMac/Filter/EchoGuard.swift`
- `RaptureMac/RaptureMac/Filter/SelfChatResolver.swift`
- `RaptureMac/RaptureMac/Reply/AppleScriptSender.swift`
- `RaptureMac/RaptureMac/Reply/Replier.swift`
- `RaptureMac/RaptureMac/Reply/NotificationDispatcher.swift`
- `RaptureMac/RaptureMac/Reply/AutomationPrompt.swift`
- `RaptureMac/RaptureMac/App/BatchProcessor.swift`
- `RaptureMac/RaptureMacTests/EchoGuardTests.swift`
- `RaptureMac/RaptureMacTests/AppleScriptSenderTests.swift`
- `RaptureMac/RaptureMacTests/ReplierTests.swift`
- `RaptureMac/RaptureMacTests/BatchProcessorTests.swift`

## Files modified

- `RaptureMac/RaptureMac/Models/PersistedState.swift` — added `recentSentEchoes`, `automationPrePromptShown`; custom decoder for forward-compat with M1 `state.json`.
- `RaptureMac/RaptureMac/App/AppState.swift` — added `automationPermissionState`.
- `RaptureMac/RaptureMac/App/Pipeline.swift` — wired Replier, EchoGuard, SelfChatResolver, BatchProcessor; consumer loop now drains a batch stream.
- `RaptureMac/RaptureMac/Watcher/ChatDBWatcher.swift` — `events(...)` returns `AsyncStream<[MessageEvent]>`; `log` is now `nonisolated`.
- `RaptureMac/RaptureMac/Writer/FileWriter.swift` — `FileManager` extension method is now `nonisolated` (Swift 6 cleanup).
- `RaptureMac/RaptureMac/RaptureMac.entitlements` — added `com.apple.security.automation.apple-events`.

Total: 13 new source files + 6 modified. Folder-sync `.pbxproj` picked up all new files automatically — no manual project file edits.
