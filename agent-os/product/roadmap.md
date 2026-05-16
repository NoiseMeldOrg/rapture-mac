# Product Roadmap

> Last Updated: 2026-05-16
> Version: 1.0.0
> Status: v1 in active development

## Phase 1: Repo bootstrap (Complete)

1. [x] **Spec docs in rapture-ios** — Snapshot of shaping session at `rapture-ios/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`. `XS`
2. [x] **GitHub repo created** — `NoiseMeldOrg/rapture-mac` (private). `XS`
3. [x] **Seed files** — `.gitignore`, `README.md`, `CLAUDE.md`. `XS`
4. [x] **agent-os scaffold** — `product/{mission,tech-stack,roadmap}.md` mirroring rapture-ios. `XS`
5. [x] **Spec copied to canonical location** — `rapture-mac/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`. `XS`

## Phase 2: Xcode project scaffold

6. [ ] **Create `RaptureMac.xcodeproj`** — macOS 14 target, SwiftUI menu bar app, `LSUIElement=YES`, hardened runtime on, no sandbox. Add GRDB via SPM. `S`
7. [ ] **App shell** — `RaptureMacApp.swift` with `MenuBarExtra(.window)`, `AppState` as `@Observable` root. Empty menu, just "Quit" for now. `XS`

## Phase 3: Models + persistence

8. [ ] **Models** — `MessageEvent`, `CapturedMessage`, `AttachmentRef`, `Settings`, `PersistedState`, `ReplyMode`. `XS`
9. [ ] **Stores** — `SettingsStore` and `StateStore` with atomic JSON writes to `~/Library/Application Support/Rapture for Mac/`. `S`

## Phase 4: AttributedBody decoder

10. [ ] **`AttributedBodyDecoder.decode(_:)`** — Pure Swift port of the JS byte-scan algorithm. Unit tests with fixture blobs extracted from real chat.db rows. `S`

## Phase 5: chat.db watcher

11. [ ] **`ChatDBWatcher`** — GRDB read-only `DatabasePool`, 1s polling, ROWID watermark persisted on every batch. `AsyncStream<MessageEvent>` output. Attachment query joined per row. `M`
12. [ ] **Permission failure surfaces cleanly** — App publishes `permissionRequired(.fullDiskAccess)` state, doesn't crash. `XS`

## Phase 6: Self-handle resolution

13. [ ] **`SelfHandleResolver`** — Background task refreshes self-handle set every 60s. Normalization matches the JS reference. `XS`

## Phase 7: Filter

14. [ ] **`MessageFilter`** — All 9 drop rules in order (mirrors `server.ts:777–798`). Returns `.capture(decodedText:)` or `.drop(reason:)`. Decision telemetry for menu bar diagnostics. `S`

## Phase 8: File writer

15. [ ] **`FileWriter`** — Atomic `.tmp` → `rename(2)` write. Attachment sibling folder. One-retry-on-missing-attachment. Returns `WriteResult` with failure detail. `S`

## Phase 9: AppleScript replier + echo guard

16. [ ] **`AppleScriptSender`** — `Process` invocation of `osascript -` with stdin script, argv text + chatGuid. Handle Automation permission denial. `S`
17. [ ] **`Replier`** — Compose `✓ Saved` / `✗ <reason>` based on `replyMode`. Trigger on every `WriteResult`. `XS`
18. [ ] **`EchoGuard`** — 15s LRU. Normalize matches JS reference (lowercase, strip ZWJ, smart quotes → ASCII, collapse whitespace, cap 120). `S`

## Phase 10: Catch-up

19. [ ] **Catch-up detection** — First batch after launch with >3 messages → `isCatchup=true`. `XS`
20. [ ] **Catch-up replier mode** — ≤3 per-message; 4+ summary; `UNUserNotification` fallback when `replyMode=.off`. `S`

## Phase 11: Settings window

21. [ ] **Settings shell** — `Window` (not `Settings` scene), tabs: General, Allowlist, About. `S`
22. [ ] **General tab** — Folder picker (`NSOpenPanel` with bookmark), launch-at-login (`SMAppService`), reply mode picker. `S`
23. [ ] **Allowlist tab** — `List` editor for handles. Explains self-chat is always captured. `XS`
24. [ ] **About tab** — Version, repo link, last-error diag. `XS`

## Phase 12: Menu bar UI

25. [ ] **`MenuBarView`** — Status line, today count, last time, last error, pause/resume, open folder, settings, quit. `S`

## Phase 13: Permissions UX

26. [ ] **Full Disk Access onboarding** — Modal sheet, deep-link to `x-apple.systempreferences:...`, poll every 2s, dismiss when granted. `S`
27. [ ] **Automation pre-prompt** — Explain before OS prompt fires. `XS`

## Phase 14: Distribution

28. [ ] **Code signing build phase** — Developer ID, hardened runtime, entitlements. `S`
29. [ ] **Notarization script** — `notarytool` + `stapler`. `S`
30. [ ] **DMG packaging** — `create-dmg` or `hdiutil`. `XS`
31. [ ] **First signed + notarized release** — Distribution channel TBD. `XS`

## v1.1 (deferred)

32. [ ] **Cloud mode via VPS relay** — Sendblue → user's hetzner VPS → push to Mac. Replaces the on-Mac webhook design from the original plan with a relay-based one that survives Mac asleep / off. Transport TBD (APNs silent push vs Mac long-poll vs WebSocket). `L`
33. [ ] **Group chat support** — `chat_style == 43` with optional `requireMention` regex. `S`
34. [ ] **Contacts framework integration** — Resolve names in allowlist UI. `XS`
35. [ ] **Auto-update** — Sparkle. `S`

---

> Notes
> - **macOS 14 deployment target** — explicit choice to use modern APIs (`@Observable`, `SMAppService`, `MenuBarExtra(.window)`) over wide compatibility. Mirrors rapture-ios's iOS 16+ approach.
> - **No sandbox** — required for FDA, arbitrary folder writes, AppleScript control. Distribution is signed + notarized DMG, not Mac App Store.
> - **Local mode is the entire v1.** No Sendblue, no cloudflared, no webhook listener. Cloud mode is v1.1 with VPS-relay, never on-Mac webhook.

> Effort Scale
> - XS: 1 day
> - S: 2-3 days
> - M: 1 week
> - L: 2 weeks
> - XL: 3+ weeks

> Reference implementation (local mode is a structural port of)
> - `/Volumes/Dock SSD/Source/Repos/anthropics/claude-plugins-official/external_plugins/imessage/server.ts`
> - See `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md` for verified contract details.
