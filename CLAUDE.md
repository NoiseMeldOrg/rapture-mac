# CLAUDE.md

> Rapture for Mac — Agent OS Configuration

## What this repo is

A macOS menu-bar app that captures Siri-dictated iMessages into `.txt` files on disk. Companion to the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app under the same product umbrella.

**v1 ships local mode only** (polls `~/Library/Messages/chat.db`, replies via AppleScript). Cloud mode (Sendblue) is deferred to v1.1 with a VPS-relay architecture, not an on-Mac webhook.

## Agent OS docs

### Product context
- **Mission:** @agent-os/product/mission.md
- **Tech stack:** @agent-os/product/tech-stack.md
- **Roadmap:** @agent-os/product/roadmap.md

### Active spec
- **v1 (Local-Mode Capture):** @agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md

## Cross-repo parity

This project is part of the Rapture product line. When making decisions about branding, file layout, versioning, distribution, or shared concepts (auth, subscriptions, settings persistence), **consult the iOS repo first** — `../rapture-ios/` — and mirror its conventions where they translate to macOS. Notably:

- **Auto-versioning:** Mirror iOS's git-commit-count scheme (see `../rapture-ios/Rapture/Scripts/set_git_version.sh`) once distribution lands (Phase 14).
- **Signing team:** `P8PLTH44DF` (shared with rapture-ios).
- **Notarization API key:** `GX6DYX9S2M` (shared; see `~/.appstoreconnect/private_keys/`).
- **Bundle ID convention:** `noisemeld.RaptureMac` (mirrors iOS's `noisemeld.Rapture`).

## Tech stack summary

- **Language:** Swift 5.9+
- **Deployment target:** macOS 14 (Sonoma) — for `MenuBarExtra(.window)`, `SMAppService`, Observation framework
- **UI:** SwiftUI
- **DB layer:** GRDB.swift (read-only against `chat.db`)
- **Subprocess:** Foundation `Process` for `osascript`
- **Sandboxing:** No (needs FDA, arbitrary folder writes, AppleScript control of Messages.app)
- **Distribution:** Developer ID signed + notarized DMG

## Reference implementations

The local-mode design is a structural port of:
- `/Volumes/Dock SSD/Source/Repos/anthropics/claude-plugins-official/external_plugins/imessage/server.ts`

See `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md` for the verified contract details.

## Workflow

1. **Check the spec:** `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md` is the current source of truth.
2. **Implement in phase order:** The plan numbers phases 1–14. Phase 1 (this scaffold) is done. Phase 2 (Xcode project scaffold) is next.
3. **Mirror iOS conventions:** Folder structure, naming, MVVM separation, atomic file writes, `@Observable` for state — all carry over.

## Claude Code skills for this work

Searched against the v1 phase plan. Install on demand with `npx skills add <owner/repo@skill> -g -y` — none of the third-party ones are installed yet.

**On the critical path:**

- `terrylica/cc-skills@imessage-query` — already knows `chat.db` schema and decodes `attributedBody` binary blobs. Cross-check against `references.md` before Phases 4–5.
- `martinholovsky/claude-skills-generator@applescript` — `osascript` patterns + input validation (the skill is self-flagged HIGH-RISK, which is honest given we pass untrusted text). Phase 9.
- `avdlee/swift-concurrency-agent-skill@swift-concurrency` — async/await, `AsyncStream`, `@Observable`, Sendable / actor isolation. Inspects build settings before recommending fixes. Phases 3–10.
- `firebase/agent-skills@xcode-project-setup` — modern folder-sync `.xcodeproj`; refuses Ruby/xcodeproj gem. Phase 2.
- `rudrankriyam/app-store-connect-cli-skills@asc-notarization` — DevID-signed DMG notarization via `notarytool` (not Mac App Store). Phase 14.

**Review-time (Phases 11–13):**

- `avdlee/swiftui-agent-skill@swiftui-expert-skill` — SwiftUI review across iOS 15+ / macOS (preferred over `twostraws/swiftui-pro` which targets iOS 26+/Swift 6.2 only).
- `rshankras/claude-code-apple-skills@macos-development` — broad macOS guidance including sandboxing/entitlements review. Useful at Phase 13.

**Already installed globally and on-target here:**

- `opensrc` — fetch GRDB.swift source during Phase 5.
- `explain-code` — work through `external_plugins/imessage/server.ts` during Phases 4–9 porting.
- `vibe-security` — pre-distribution audit of the `osascript` subprocess invocation and bookmark/permission handling.

**Skipped:** `dimillian/skills@macos-menubar-tuist-app` (Tuist, not Xcode project); `axiom-code-signing` (`asc-notarization` is more direct); `axiom-grdb` (built for advanced queries, our polling is simpler); `xcode-build-optimization-agent-skill@*` (project too small for build-time optimization).

## Notes

- **No Mac App Store in v1.** Sandboxing would require entirely different permission flows and would block AppleScript control of Messages.app. Distribute via signed + notarized DMG.
- **No analytics in v1.** Add PostHog (mirroring iOS) only if there's a real reason.
- **Full Disk Access is the primary friction point.** Polling `~/Library/Messages/chat.db` requires FDA. The onboarding UX has to make this painless.
