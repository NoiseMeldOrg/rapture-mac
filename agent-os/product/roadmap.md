# Product Roadmap

> Last Updated: 2026-05-16
> Version: 1.0.0
> Status: v1 in active development

Faithful 14-phase plan from `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md`. Effort is shaped as `XS` (1 day), `S` (2–3 days), `M` (1 week), `L` (2 weeks).

## Phase 1: Repo bootstrap (Complete)

1. [x] gh repo created — `NoiseMeldOrg/rapture-mac` (private). `XS`
2. [x] Seed files — `.gitignore`, `README.md`, `CLAUDE.md`. `XS`
3. [x] agent-os scaffold — `product/{mission,tech-stack,roadmap}.md`. `XS`
4. [x] Spec copied to canonical location. `XS`

## Phase 2: Xcode project scaffold

5. [ ] Create `RaptureMac.xcodeproj` — macOS 14 target, SwiftUI menu-bar, `LSUIElement=YES`, hardened runtime ON, no sandbox. GRDB via SPM. `S`
6. [ ] `RaptureMacApp.swift` shell — `MenuBarExtra(.window)`, `AppState` as `@Observable` root. `XS`

## Phase 3: Models + persistence

7. [ ] Models — `MessageEvent`, `CapturedMessage`, `AttachmentRef`, `Settings`, `PersistedState`, `ReplyMode`. `XS`
8. [ ] `SettingsStore` + `StateStore` — atomic JSON writes to `~/Library/Application Support/Rapture for Mac/`. `S`

## Phase 4: AttributedBody decoder

9. [ ] `AttributedBodyDecoder.decode(_:)` — pure Swift port of the `server.ts:82–102` byte-scan algorithm. Unit tests against fixture blobs. `S`

## Phase 5: chat.db watcher

10. [ ] `ChatDBWatcher` — GRDB read-only `DatabasePool`, 1s polling, ROWID watermark, `AsyncStream<MessageEvent>` output, attachment join per row. `M`
11. [ ] Permission failure surfaces cleanly — publishes `permissionRequired(.fullDiskAccess)`, doesn't crash. `XS`

## Phase 6: Self-handle resolution

12. [ ] `SelfHandleResolver` — 60s refresh task; normalization matches `server.ts:177–185`. `XS`

## Phase 7: Filter

13. [ ] `MessageFilter` — 9 drop rules in order (mirrors `server.ts:777–798`). Returns `.capture` or `.drop(reason)` for menu-bar diagnostics. `S`

## Phase 8: File writer

14. [ ] `FileWriter` — atomic `.tmp` → `rename(2)`. Attachment sibling folder. One-retry on missing attachment. `WriteResult` with failure detail. `S`

## Phase 9: AppleScript replier + echo guard

15. [ ] `AppleScriptSender` — `Process` invocation of `osascript -` with stdin script, argv `[text, chatGuid]`. Handle Automation permission denial. `S`
16. [ ] `Replier` — compose `✓ Saved` / `✗ <reason>` based on `replyMode`. Trigger on every `WriteResult`. `XS`
17. [ ] `EchoGuard` — 15s LRU. Normalize matches `server.ts:431–457` (lowercase, strip ZWJ, smart quotes → ASCII, collapse whitespace, cap 120). `S`

## Phase 10: Catch-up

18. [ ] Catch-up detection — first batch after launch with >3 messages → `isCatchup=true`. `XS`
19. [ ] Catch-up replier mode — ≤3 per-message; 4+ summary; `UNUserNotification` fallback when `replyMode=.off`. `S`

## Phase 11: Settings window

20. [ ] Settings shell — `Window` (not `Settings` scene), tabs: General, Allowlist, About. `S`
21. [ ] General tab — folder picker (`NSOpenPanel` + bookmark), launch-at-login (`SMAppService`), reply mode picker. `S`
22. [ ] Allowlist tab — `List` editor for handles. Self-chat is always captured. `XS`
23. [ ] About tab — version, repo link, last-error diag. `XS`

## Phase 12: Menu bar UI

24. [ ] `MenuBarView` — status line, today count, last time, last error, pause/resume, open folder, settings, quit. `S`

## Phase 13: Permissions UX

25. [ ] Full Disk Access onboarding — modal sheet, deep-link to `x-apple.systempreferences:...`, poll every 2s. `S`
26. [ ] Automation pre-prompt — explain before OS prompt fires. `XS`

## Phase 14: Distribution

27. [ ] Code signing build phase — Developer ID, hardened runtime, entitlements. `S`
28. [ ] Notarization script — `notarytool` + `stapler`. `S`
29. [ ] DMG packaging — `create-dmg` or `hdiutil`. `XS`
30. [ ] Flip repo to public on GitHub + add `LICENSE` (Apache-2.0), `SECURITY.md`, `CONTRIBUTING.md`. `XS`
31. [ ] First signed + notarized release — GitHub Releases, DMG attached. `XS`

## v1.1 (deferred)

32. [ ] Cloud mode via VPS relay — Sendblue → user's hetzner VPS → push to Mac. Transport TBD (APNs silent push vs Mac long-poll vs WebSocket). Replaces the on-Mac webhook design from the original plan. `L`
33. [ ] Group chat support — `chat_style == 43` with optional `requireMention` regex. `S`
34. [ ] Contacts framework integration — resolve names in allowlist UI. `XS`
35. [ ] Auto-update — Sparkle. `S`

---

> **macOS 14 deployment target.** Explicit choice to use modern APIs (`@Observable`, `SMAppService`, `MenuBarExtra(.window)`) over wide compatibility.
> **No sandbox.** Required for FDA, arbitrary folder writes, AppleScript control. Distribution is signed + notarized DMG.
> **Reference implementation:** `external_plugins/imessage/server.ts` — see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md`.
