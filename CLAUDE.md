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
- **App icon:** Reuse the iOS app icon at `../rapture-ios/Rapture/Rapture/Assets.xcassets/AppIcon.appiconset`. M1 (Xcode scaffold) copies it into `RaptureMac/Resources/Assets.xcassets/AppIcon.appiconset` rather than designing a new one — keeps the product family visually consistent and removes a real M1 task. The macOS `.icns` is built from the same source set automatically by Xcode's asset compiler.

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
- `anthropics/claude-plugins-official/external_plugins/imessage/server.ts`

See `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md` for the verified contract details.

## Workflow

1. **Check the spec:** `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md` is the current source of truth.
2. **Implement in phase order:** The plan numbers phases 1–14. Phase 1 (this scaffold) is done. Phase 2 (Xcode project scaffold) is next.
3. **Mirror iOS conventions:** Folder structure, naming, MVVM separation, atomic file writes, `@Observable` for state — all carry over.

## Claude Code skills for this work

Searched against the v1 phase plan. Some are installed globally (workflow tools + project-domain helpers); the rest are install-on-demand for specific phases. Install with `npx skills add <owner/repo@skill> -g -y`.

**Planning + workflow (installed globally 2026-05-18):**

- `mattpocock/skills@setup-matt-pocock-skills` — required prerequisite for the other mattpocock skills (per-repo configuration: tracker, labels, doc layout).
- `mattpocock/skills@grill-with-docs` — interview-style challenge of plans against the domain model, with `CONTEXT.md` + ADR outputs. The highest-leverage skill for the planning phase we're in; reach for it before the next big decision (e.g., the sibling-deliverables question).
- `mattpocock/skills@tdd` — red-green-refactor loop. Reach for it from Phase 4 onward — the AttributedBody decoder is a textbook TDD target (pure byte-scan with known fixtures).
- `mattpocock/skills@diagnose` — structured debugging loop (reproduce → minimize → hypothesize → instrument → fix → test). Earns its keep the first time `chat.db` surprises us.
- `mattpocock/skills@zoom-out` — broader architectural context for unfamiliar code. Useful while reading `external_plugins/imessage/server.ts` and `imsg`'s source during Phases 4–9 porting.

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
- **Full Disk Access is the primary friction point.** Polling `~/Library/Messages/chat.db` requires FDA. The onboarding UX has to make this painless. **FDA + app updates:** replacing the app bundle can drop the prior build's FDA grant in TCC, so the new build re-runs FDA onboarding and then needs a **quit-and-reopen** (a running process doesn't see a newly-granted FDA until it relaunches). A Sparkle *auto-update* **preserves** the FDA grant across the in-place swap — confirmed by a 1.0.80→1.0.83 live-test (no re-prompt, capture kept working), since TCC honors the stable Developer ID designated requirement. Only a *manual* drag-replace install drops it. So auto-update is seamless; manual reinstalls aren't.
- **Tests run inside the app.** The XCTest bundle is hosted in `Rapture.app`, so the app's `@main` startup runs during `xcodebuild test`. Any launch-time side effect that hits the network, spawns a shell, or touches a TCC-protected resource destabilizes the headless test host — notably opening `chat.db` raises the FDA prompt, which can surface as an intermittent `Restarting after unexpected exit` (looks like a flaky-test crash but is the TCC prompt). Gate all such startup machinery behind `ProcessInfo.processInfo.isRunningXCTests` (`RuntimeEnvironment.swift`). See CONTRIBUTING.md → "Architecture and code style."

## `_build_plan/`

The `_build_plan/` folder contains PRDs and per-milestone prompts used to scaffold build-outs. These files are **not functional** — no code, configuration, or runtime logic in this codebase should import, reference, or depend on anything inside `_build_plan/`.

The folder is **preserved as a historical record** (not deleted after build-out). For durable architectural decisions that evolve with the codebase, refer to `agent-os/specs/` and `agent-os/product/` — those are the source of truth; `_build_plan/` is the frozen build-out snapshot.

- **Root (`prd.{md,html}`, `milestones/`)** — the v1 initial build-out (2026-05-19). Durable truth: `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`.
- **`triage-engine/`** — the built-in triage engine build-out, **complete (5/5 milestones, 2026-07-13)**: core → destination resilience → Reminders/Calendar handoff → AI triage → link enrichment + docs story. This feature deliberately reversed two mission.md commitments (no built-in AI; no in-app categorizing) in favor of output neutrality; milestone 5 updated `mission.md`/`CONTEXT.md`/README/PRIVACY/SECURITY accordingly. Durable truth: [`agent-os/specs/2026-07-13-2230-triage-engine/`](agent-os/specs/2026-07-13-2230-triage-engine/). The app now has three enumerated outbound network paths (Sparkle opt-out; BYO-key Anthropic and link-enrichment fetches, both opt-in) — any new networking must update PRIVACY's grep claim in the same change.
- **`destination-onboarding/`** — vault detection, subfolder containment, and migration consent. **Planned 2026-07-15, not yet built (0/3 milestones).** Shaped from a v1.0.98 dogfood in which a week of correctly-triaged notes stranded in the default folder because the app never asked where they should go, and the hand-move that followed desynced both ledgers — every failure was discoverability, not capability. Scope is deliberately narrow: it **extends** `OutputFolderMigrator` (shipped v1.0.69) rather than rebuilding it, adds **no networking** (PRIVACY's three paths stay three), and keeps output neutral (detection decides *where* to write, never *how*). Explicitly rejected during shaping: security-scoped bookmarks (the app is unsandboxed) and note-level dedup. Vault git auto-backup was split into its own feature (below).
- **`vault-backup/`** — a **backup-health watchdog**: Rapture *watches* whether the notes folder's git repo is current and warns when it's fallen behind. **Planned 2026-07-16, not yet built (0/1 milestone).** Reshaped twice: (1) a separate signed `launchd` helper app to git-push the vault → (2) Rapture doing the git push itself → (3) **Rapture only watching, never pushing.** The third reshape (on the user's challenge) is the durable design: the one real benefit of Rapture pushing (backing up while Obsidian is closed) barely applies when Obsidian is usually open, while the costs (a fourth outbound path in the message-reading app, git auth/key/divergence surface, scope drift) are real. So the purpose-built pusher (obsidian-git on an SSH remote) does the backup, and Rapture supplies the missing piece — loud, always-on detection when backup falls behind. **Read-only, ZERO networking** (reads local git refs via `Process`: `status`/`rev-list @{u}..`/`log`; a successful push advances the local tracking ref, so push-success is detectable with no fetch), so **PRIVACY is unchanged** — its `grep URLSession\.` claim still returns exactly three files. Mechanism-agnostic (doesn't assume obsidian-git). Menu-bar warning is opt-in/off by default; the passive Settings status line always shows when the destination is a git repo. The `NoiseMeld/second-brain` remote was switched HTTPS→SSH on 2026-07-16 so the *actual* pusher authenticates reliably (that's the pusher's concern, not Rapture's). Spec: [`_build_plan/vault-backup/prd.md`](_build_plan/vault-backup/prd.md).
