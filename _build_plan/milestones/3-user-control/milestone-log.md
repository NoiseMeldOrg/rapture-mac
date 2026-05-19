# Milestone 3 — User Control · build log

> Authored at end of M3 build, 2026-05-19. Covers Phases 11–12 of the spec and wires up the settings the earlier milestones referenced but had hardcoded.

## Status

**Built and unit-verified.** All 73 unit tests pass (M1's 8 + M2's 36 + M3's 29). Build completes with zero new warnings; one inherited M1 warning in `SelfHandleResolver` (an `await` on a non-async expression) was left alone because it's outside M3's scope and predates this milestone.

End-to-end "Done when" verification (click menu bar, pause, change folder, edit allowlist, switch reply mode) is queued for a human session — the test loop here covers the pure logic; the visual workflow needs a person at the keyboard.

## What was built

### Scene topology — `RaptureMacApp.swift`

Restructured from "single auto-opening Window" to "MenuBarExtra as the primary surface plus two on-demand Windows":

- **`MenuBarExtra(.menuBarExtraStyle(.window))`** is declared first so it serves as the app's "main scene" and the two Windows below stay closed at launch. Label is a private `MenuBarLabel` view whose `.task` is the reliable app-launch hook for `pipeline.start()`.
- **`Window(id: "permissions")`** — opened by `openWindow(id:)` from `MenuBarLabel` when `appState.permissionState == .fullDiskAccessRequired`. No longer auto-opens.
- **`Window(id: "settings")`** — opened from `MenuBarView`'s Settings… button.

Every window-opener path calls `NSApp.activate(ignoringOtherApps: true)` first (the LSUIElement quirk you flagged). The `.task` inside each Window's body also re-activates as a defensive belt-and-suspenders for the case where the window is reopened after first-appear.

### `MenuBarLabel` (private to `RaptureMacApp`)

Tiny view whose lifetime equals the app's. Hosts:

- The state-driven SF Symbol (`text.bubble` capturing · `pause.fill` paused · `exclamationmark.triangle.fill` permission/automation needed)
- The one-shot `.task` that calls `pipeline.start()` and, if the resulting `permissionState` is `.fullDiskAccessRequired`, calls `openWindow(id: "permissions")`
- An `.onChange(of: appState.permissionState)` that re-fires the same `openWindow` path if FDA is revoked later (e.g., user toggles it off in System Settings and the next chat.db read fails)

### `MenuBarView` — popover content

In `UI/MenuBarView.swift`. ~300pt wide. Renders:

- **Status block**: a primary line from `MenuBarStatus.line(...)` plus a secondary `"Today: N notes · Last <relative time>"` from `RelativeDateTimeFormatter(unitsStyle: .abbreviated)`
- **Action rows** (custom row-label style so they read like menu items, not buttons):
  - Pause Capture / Resume Capture (toggles `Settings.paused`; disabled when not in `.ok` permission state)
  - Open Notes Folder (disabled when no output folder is set)
  - Settings… (opens the Settings window)
  - Quit
- When FDA or Automation is needed, the Pause row is replaced by "Show permissions help…" which opens the permissions Window directly.

The Pause row's icon flips between `pause.fill` and `play.fill` so the affordance reads correctly in both states.

### `MenuBarStatus` — pure status-line resolver

In `UI/MenuBarStatus.swift`. `static func line(permission:automation:paused:lastError:) -> Line` produces a `(kind, primary, iconName)` triple. Priority order, highest first: FDA needed > Automation needed > Paused > Error > Capturing. The `.unknown` permission state — which exists only for the millisecond between `AppState.init()` and `pipeline.start()` resolving — falls through to capturing, with a test (`testUnknownPermissionShowsCapturingDuringStartup`) documenting that as intentional rather than a hole.

### Settings window — `SettingsView` + three tab views

- `UI/SettingsView.swift` — `TabView` host (General · Allowlist · About). Fixed 560×440. `.task` activates the app for the LSUIElement quirk.
- `UI/SettingsGeneralView.swift`:
  - Output folder section: read-only path display, "Change…" button (`NSOpenPanel(canChooseDirectories: true, canCreateDirectories: true)`), `.onDrop(of: [.fileURL])` target that accepts a folder URL drop and writes through to settings
  - Launch-at-login: Toggle bound to `LaunchAtLoginController.isEnabled` (SMAppService status is the source of truth, per the locked decision). Inline error message on failure, and a hint when `SMAppService.mainApp.status == .requiresApproval` directing the user to System Settings → General → Login Items
  - Reply mode: inline `Picker` over `ReplyMode.allCases` with user-facing labels ("Reply to every capture" / "Reply on failures only" / "Never reply")
  - Allow SMS: Toggle with the spoofing-risk subtitle from the PRD
- `UI/SettingsAllowlistView.swift`: `TextField` + Add button (Add is disabled when the input normalizes to empty), `List` of current handles with red `minus.circle.fill` remove buttons, footer note that self-chat is always captured
- `UI/SettingsAboutView.swift`: app-name and version line (`v\(CFBundleShortVersionString) (build \(CFBundleVersion))` — currently `v0.1.0 (build 1)`), Apache-2.0 attribution, GitHub repo link, and a `DisclosureGroup("Show paths and last error")` that surfaces output-folder / settings.json / state.json paths and the most recent error if any

### `LaunchAtLoginController`

Tiny wrapper around `SMAppService.mainApp` in `UI/LaunchAtLoginController.swift`. `isEnabled` is synchronous; `setEnabled(_:)` throws so the view can show an inline error. The status comparison is `== .enabled`, so `.requiresApproval` and `.notRegistered` both display as off — matching what the user sees in System Settings.

### `AllowlistInput` — pure normalization helper

In `App/AllowlistInput.swift`. `normalize(_:)` trims whitespace and strips Apple's `E:` / `p:` letter-prefix the same way `SelfHandleResolver.normalize` does, but does NOT lowercase — `MessageFilter` already compares both raw and normalized, and an Apple-ID email with a deliberately mixed case shouldn't be silently flattened. `appending(_:to:)` dedupes case-insensitively before adding.

### Pause behavior — DEFER (per locked decision #1)

- `BatchProcessor` gains a `wasPausedLastBatch: Bool` flag plus a new pure helper `BatchProcessor.policy(paused:wasPausedLastBatch:isFirstNonemptyBatchSeen:batchSize:) -> Policy`. The instance method `process(batch:)` calls into the helper and applies the returned policy (defer the batch, or process it and possibly enter catch-up mode).
- On `paused == true`: hold the batch, do NOT advance the watermark, do NOT touch `isFirstNonemptyBatchSeen`, flip `wasPausedLastBatch` true. The watcher keeps polling at 1Hz (no coordination with the watcher needed).
- On the next non-paused batch with `wasPausedLastBatch == true`: clear `isFirstNonemptyBatchSeen` so the resume batch is re-evaluated as a potential catch-up trigger. A 4+ resume batch fires the "📥 Caught up: N notes captured" summary path that M2 already wired.

### Today-count + last-capture, persistent

Added to `PersistedState`:

- `todayCount: Int`
- `todayDate: Date?` — used for calendar-day rollover detection
- `lastCaptureAt: Date?`

Custom `init(from:)` extended with `decodeIfPresent` defaults (continuing the M1→M2 pattern; M2-vintage `state.json` decodes fine without migration). Pure helpers on `PersistedState`:

- `displayedTodayCount(at:calendar:)` — returns 0 when `todayDate` is on a different calendar day from "now", so the UI rolls over at midnight without persisting a write
- `static incrementing(currentDate:currentCount:at:calendar:)` — the rollover/increment math, unit-tested in isolation

`StateStore.recordSuccess(at:calendar:)` wires the pure helper into the live store and is called from `BatchProcessor` in the writer-success branch.

### Observability

`StateStore` and `SettingsStore` are now `@Observable` (with `@ObservationIgnored` on their static `log` properties to silence noise). Views read `appState.state.state.todayCount` / `appState.settings.settings.paused` and re-render automatically when those stores call `update { ... }`. `SettingsStore.binding(for:)` gives views a `Binding<V>` over any `WritableKeyPath<Settings, V>` so Toggle / Picker bindings stay declarative without losing the "save on every change" invariant.

### Permissions polish (env note 3)

`PermissionsView` picked up one defensive paragraph: "Not in the list? Click the **+** button in System Settings and add Rapture for Mac manually." This is the dev-build friction you flagged from M2 — signed releases won't hit it, but dev builds at `/tmp` paths often need the manual add. The rest of the FDA flow is unchanged.

## Tests added

| Suite | Count | Coverage |
|---|---:|---|
| `MenuBarStatusTests` | 7 | Status priority matrix: capturing default, FDA beats everything, automation beats paused/error, paused beats error, error shown when nothing else wrong, empty error treated as no-error, unknown-permission-shows-capturing |
| `AllowlistInputTests` | 10 | `normalize`: trim, empty-returns-nil, Apple-prefix strip, prefix-only nil, non-letter prefix preserved. `appending`: new entry, case-insensitive dedupe, empty refusal, distinct entries, normalize-before-checking |
| `TodayCountTests` | 6 | `incrementing` from nil, same-day bump, new-day reset. `displayedTodayCount` returns count when same day, zero when stale, zero when date nil. Calendar pinned to UTC so fixtures behave on any host time zone |
| `BatchProcessorTests` (M2 carry-over) | +6 | `policy(...)` returns: deferred on pause with state hold, resume-after-pause clears firstSeen and triggers catchup, resume of 2 is not catchup, live batch honors firstSeen, first-ever batch of 5 is catchup, two consecutive paused batches don't drift firstSeen |
| **M1 + M2 carry-over** | 44 | unchanged, all green |
| **Total** | **73** | |

All 73 tests pass in 0.047s.

## Verification commands

Per the M1/M2 environment notes (exFAT AppleDouble files break codesign — derived data must live on internal APFS):

```sh
xcodebuild -derivedDataPath /tmp/RaptureMacDerived -scheme RaptureMac clean build   # ** BUILD SUCCEEDED **
xcodebuild -derivedDataPath /tmp/RaptureMacDerived -scheme RaptureMac test          # 73 tests, 0 failures
```

Build emits no new warnings. One pre-existing warning in `SelfHandleResolver.swift:27` (`await` on a non-async expression) carries over from M1 — out of M3 scope; flagging here so it's not forgotten.

## Decisions made during implementation that weren't pre-specified

1. **`BatchProcessor.policy(...)` is the testable pure helper instead of testing `process(...)` end-to-end.** Following M2's `isCatchup(...)` pattern. The instance method does the side effects (mutating `isFirstNonemptyBatchSeen` / `wasPausedLastBatch`, advancing the watermark, calling the writer) but the *decision* about defer/process/catchup is a pure function of four inputs and is unit-tested as such. Avoids standing up an `AppState` + `Replier` + `EchoGuard` + writer mock + provider closures just to exercise pause/resume.

2. **Pause defers without re-seeding the watermark even if the watcher gets restarted mid-pause.** Quitting the app during pause means on relaunch, the watcher's persisted watermark is wherever it was at pause-start. The first batch on relaunch sees `paused == true` (Settings.paused persists), defers, holds the watermark. The user has to unpause for capture to resume — same UX whether the pause spanned an app restart or not. No special migration path needed.

3. **`SettingsStore.binding(for:)` returns a `Binding<V>` from a `WritableKeyPath<Settings, V>`.** Lets views write `Toggle("…", isOn: appState.settings.binding(for: \.allowSMS))` without exposing a public setter on `settings` or pulling in `@Bindable`. The closure captures `self`, so the binding correctly funnels through `update { ... }` and persistence fires automatically. SwiftUI 6.0+; safe under macOS 14.

4. **`SettingsAboutView` reads version strings from `Bundle.main.infoDictionary` directly rather than via a wrapper.** Two strings, no logic. Wrapping it as `AppVersion.short` / `.build` would be ceremony. Once M4 wires git-commit-count auto-versioning, those values flow through `CFBundleShortVersionString` / `CFBundleVersion` the same way — the view doesn't need to change.

5. **`MenuBarStatus` treats `.unknown` permission as capturing.** Documented in test `testUnknownPermissionShowsCapturingDuringStartup` with a comment explaining why: `.unknown` exists only between `AppState.init()` and the first `pipeline.start()` poll, which is sub-millisecond in practice. Showing "✓ Capturing" briefly is benign; showing "⚠ FDA needed" before we've actually checked would be a lie.

6. **Allowlist input does NOT lowercase.** Emails are case-preserving by Apple ID convention; phone numbers don't care. `MessageFilter` already compares both raw and normalized forms, so dropping case in the UI just makes the displayed list less faithful to what the user typed. Dedupe is case-insensitive (so `Hi@Example.com` and `hi@example.com` collapse to whichever was added first), but the surviving entry keeps the original casing.

7. **Drag-and-drop on the folder picker accepts the first dropped item only.** SwiftUI's `.onDrop(of: [.fileURL], …)` can technically multi-load, but multi-folder destinations are explicitly out of scope for v1. First-wins matches the PRD's "one output folder per install."

8. **`LaunchAtLoginController` treats anything other than `.enabled` as "off" in the toggle's read path.** `.requiresApproval` (user has to click Approve in System Settings) and `.notRegistered` (default) both display as off. Users see a hint sentence below the toggle when status is `.requiresApproval` directing them to System Settings → General → Login Items. The toggle's write path still calls `register()` for the `.requiresApproval` case, which is a no-op in macOS terms but cleanly re-prompts the user if they had previously rejected approval.

9. **The output folder drop target visualises with a 2pt accent-color border** when targeted. Subtle enough to look intentional in default-light and default-dark, no asset work.

10. **`@ObservationIgnored` on the static `Logger` properties of `StateStore` and `SettingsStore`.** Without it, the `@Observable` macro tries to wrap the static `log` in observation tracking, which fails to compile (statics aren't instance-tracked). Explicit annotation keeps the compiler happy and is the standard pattern in Apple's `@Observable` docs.

## What M4 will need to know

- **No new entitlements.** M2 added `com.apple.security.automation.apple-events`; M3 adds nothing. Hardened runtime is still ON in the project settings, ready for M4 codesigning.
- **`SMAppService.mainApp.register()` is now called from the UI.** The first time a user toggles launch-at-login on, macOS may show a one-time approval dialog ("Allow Rapture for Mac to register as a Login Item?"). The dialog comes from the OS — no in-app pre-prompt needed. Worth a sentence in the README / DMG-bundled docs at M4 release time.
- **Version reads from `CFBundleShortVersionString` / `CFBundleVersion`.** Currently `0.1.0` / `1`. M4's git-commit-count auto-versioning needs to update those (likely via a `Run Script` build phase that writes them into the generated Info.plist) — the About tab will pick it up automatically.
- **`MenuBarLabel` is private to `RaptureMacApp`.** If M4 wants to surface a different icon in the menu bar based on signing/distribution context (e.g., a "Beta" decorator), the inline view is the place. Don't bother extracting unless there's a real reason.
- **Diagnostics tab paths are computed via `AppSupportDirectory.url()`.** That's `~/Library/Application Support/Rapture for Mac/` for both Debug and Release builds — sandbox-relative redirection isn't a concern since v1 doesn't sandbox. M4's DMG copy will land users in the same location, no migration required.
- **Pause is persistent across launches.** A user who quits while paused stays paused on relaunch (Settings.paused is in `settings.json`). M4's signed release should test this corner — it's correct behavior but easy to mistake for a bug if someone forgets they paused.

## Deviations from the PRD / plan, and why

- **Security-scoped bookmarks are NOT used for the output folder.** The PRD mentions them for "Dropbox/Drive paths survive across launches." Without sandboxing — and v1 explicitly opts out — a plain `URL` survives launches with full read/write access to any user-owned path. Bookmarks would add code and a layer of failure modes (stale-bookmark handling) for zero behavioral benefit in v1. If a future MAS-targeting variant ever happens, this is one of the places that has to change; recording the decision here so it's findable.
- **`Settings` scene was not used.** The plan and PRD both call for `Window`-based Settings rather than SwiftUI's `Settings` scene, and that's what shipped. The `Settings` scene's CMD+, default keybinding isn't a clear win for an `LSUIElement` app with no app menu — users open Settings from the menu-bar popover, not from a keyboard shortcut. Cost: no automatic CMD+, handler. Acceptable.
- **`replyMode` picker shows three radio rows (`pickerStyle(.inline)`) instead of a dropdown.** The PRD doesn't specify visual style. Three options is the sweet spot for an inline radio set — fewer modal steps than a dropdown, and the descriptions ("Reply to every capture" / "Reply on failures only" / "Never reply") fit on one line. If this turns into a problem at M4 polish, swap to `.menu` style with one line edit.
- **"Re-check permissions" button on the menu bar — out.** Considered during planning. The status-line + the "Show permissions help…" affordance covers the user's recovery path. A redundant "Re-check" button would imply manual polling, which isn't how the FDA detection actually works (the watcher retries chat.db opens every 2 seconds in the background and flips state automatically when access is granted).

## Files that didn't exist at the start of M3 and now do

```
RaptureMac/RaptureMac/App/AllowlistInput.swift
RaptureMac/RaptureMac/UI/LaunchAtLoginController.swift
RaptureMac/RaptureMac/UI/MenuBarStatus.swift
RaptureMac/RaptureMac/UI/MenuBarView.swift
RaptureMac/RaptureMac/UI/SettingsAboutView.swift
RaptureMac/RaptureMac/UI/SettingsAllowlistView.swift
RaptureMac/RaptureMac/UI/SettingsGeneralView.swift
RaptureMac/RaptureMac/UI/SettingsView.swift
RaptureMac/RaptureMacTests/AllowlistInputTests.swift
RaptureMac/RaptureMacTests/MenuBarStatusTests.swift
RaptureMac/RaptureMacTests/TodayCountTests.swift
```

## Files modified

- `RaptureMac/RaptureMac/RaptureMacApp.swift` — scene restructure (MenuBarExtra first, two on-demand Windows); private `MenuBarLabel` view hosts the app-launch hook.
- `RaptureMac/RaptureMac/App/BatchProcessor.swift` — pause/resume `Policy` helper, pause gating in `process(batch:)`, `appState.state.recordSuccess(...)` call in the writer-success branch.
- `RaptureMac/RaptureMac/Models/PersistedState.swift` — three new fields (`todayCount`, `todayDate`, `lastCaptureAt`) with backward-compatible decoder defaults; pure `displayedTodayCount` and `incrementing` helpers.
- `RaptureMac/RaptureMac/Persistence/StateStore.swift` — `@Observable`, new `recordSuccess(at:calendar:)` method.
- `RaptureMac/RaptureMac/Persistence/SettingsStore.swift` — `@Observable`, new `binding(for:)` key-path helper for SwiftUI Bindings.
- `RaptureMac/RaptureMac/UI/PermissionsView.swift` — one defensive paragraph about the `+` button in System Settings.
- `RaptureMac/RaptureMacTests/BatchProcessorTests.swift` — 6 new pause/resume policy tests.

Total: 11 new files + 7 modified. Folder-sync `.pbxproj` picked up all new files without manual edits (per M1's project setup).
