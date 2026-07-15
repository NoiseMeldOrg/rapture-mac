# Milestone 1 — Vault-Aware Destination

You are entering plan mode to plan and then build milestone 1 of this feature.

## Context

- Read `@_build_plan/destination-onboarding/prd.md` for the full feature context, scope, data model, and locked decisions.
- This is milestone 1 — there is no prior milestone log to read.

### Repo truth (the PRD is the *what*; these are the *how*)

The PRD is deliberately implementation-free. **The code is the technical truth.** Read before planning:

- **`@CLAUDE.md`** — repo conventions. Note especially: tests run inside the app (gate launch-time side effects behind `RuntimeEnvironment.isRunningXCTests`), and `_build_plan/` is non-functional.
- **`@agent-os/specs/2026-06-22-1048-output-folder-auto-relocation/`** and **`@agent-os/specs/2026-06-26-0916-output-folder-data-safety-hardening/`** — the durable specs for the relocation machinery you're extending. Read both; they explain *why* the migrator is shaped the way it is.
- **`@agent-os/product/mission.md`** — output neutrality is a hard commitment. Detection decides *where* to write, never *how*.

### The exact files you will touch

- **`RaptureMac/RaptureMac/App/AppState.swift`** — `setOutputFolder` (async, `@MainActor`). The consent step slots in **after** the volume-absent guard and **before** `isRelocating`/`relocationStatus` are touched and before the capture gate is taken, so a decline is a clean silent return with `relocationStatus` still `.idle`. Its only production callers are `pickFolder()` and `handleDrop` in `SettingsGeneralView.swift`, so consent placed inside `setOutputFolder` covers both.
- **`RaptureMac/RaptureMac/Persistence/OutputFolderMigrator.swift`** — **do not restructure it.** Consent needs a dry run it doesn't expose today; `pairPlan`, `isAncestor`, `sameVolume`, and `directorySize` are already `static` and pure, so a `plan(from:to:)` returning collision/count/volume facts is a cheap addition on that existing seam. Note `migrate` moves **every top-level item including dotfiles**, and refuses nested paths (`isAncestor` → `MigrationError.nestedPaths`) — that refusal is why containment must be decided *before* a vault root is ever adopted.
- **`RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`** — the picker (`pickFolder`, `handleDrop`) and `outputFolderSection`. `relocationStatusView` and `destinationOfflineStatusView` are the house patterns for inline status.
- **`RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift`** — must point at the **final** destination including the container subfolder. It's a public contract for downstream consumers (Claude Code SessionStart hook, OpenClaw/Hermes skills) that read it verbatim as the notes root.
- **`RaptureMac/RaptureMac/Filter/TriageLedger.swift`** + **`RaptureMac/RaptureMac/Filter/EnrichedLinkLedger.swift`** — both key off **destination-relative** paths via `CaptureContract.relativePath(of:in:)`, and both `remap` only collision renames. This is why containment must go **through** `setOutputFolder` and not around it: prepend a subfolder without a real relocation and every stored relative path silently points one level up. The "leave them behind" consent option needs ledger **pruning** — add that deliberately; it does not exist yet.
- **`RaptureMac/RaptureMac/Writer/DestinationGuard.swift`** — `classify` is pure and probe-injectable. A path not under `/Volumes` can never be `.volumeAbsent`. Reuse it to decide whether a detected vault is reachable; do not write a second reachability rule.
- **`RaptureMac/RaptureMac/Persistence/AppSupportDirectory.swift`** — `defaultOutputFolder` (the `~/Documents/Rapture Notes` fallback, DEBUG-conditional).
- **New code** goes in a new folder following the house shape (e.g. `RaptureMac/RaptureMac/Destination/`). The project is folder-sync — **no pbxproj edits needed**.

### Reference implementations to mirror

- **`RaptureMac/RaptureMac/Handoff/HandoffEnableFlow.swift`** (and its sibling `TriageAI/AITriageEnableFlow.swift`) — **copy this shape for consent.** A `@MainActor enum` with a static method taking injected prompt closures and returning a `Result` struct. This is load-bearing for testability: `AppStateRelocationTests` calls `setOutputFolder` directly, so a bare `NSAlert.runModal()` inside would hang the suite. See `HandoffEnableFlowTests.swift` for the test shape.
- **`RaptureMac/RaptureMac/Reply/AutomationPrompt.swift`** — the `NSAlert` presentation half, for the real dialog.
- **`RaptureMac/RaptureMac/Handoff/SystemEventKitClient.swift`** — the "only file that imports the system framework, behind an injected protocol, XCTest-front-guarded" pattern. Vault detection reads a file Obsidian owns; put the real filesystem read behind an injected protocol the same way so tests never depend on whether Obsidian is installed.

### Verified facts — don't re-derive these

- Obsidian's vault list is at `~/Library/Application Support/obsidian/obsidian.json`, shape `{"vaults": {"<id>": {"path": "/abs/path", ...}, ...}}`. **Confirmed parsing on this machine**; the real vault is `/Volumes/Dock SSD/Obsidian/Second Brain` — an external volume, so the unreachable-vault path is live for the developer, not theoretical.
- The app is **not sandboxed** (`RaptureMac.entitlements`). Reading that config needs no entitlement, and **security-scoped bookmarks are out of scope** — there are zero usages in the codebase and `tech-stack.md` says explicitly none is needed.
- **This milestone adds no networking.** PRIVACY.md's grep claim must still return exactly three files afterward.

## Your task

1. Plan the implementation for **only** milestone 1 as defined in the PRD. Do not plan or build anything from milestones 2 or 3 (no first-run flow, no nudges, no vault-root rescue).
2. After the user confirms the plan, build only what is in milestone 1's scope.
3. Verify your work against the "Done when" criteria for milestone 1 in the PRD. Tests are **mandatory** — this touches the ledger, the highest-stakes state in the app. Cover at minimum: vault-config parsing (valid, malformed, missing, empty), reachable vs unreachable vaults, the containment decision (empty / already-ours / populated-by-someone-else), consent decline leaving state untouched, and ledger pruning on "leave them behind". Match the style in `RaptureMacTests` (see `AppStateRelocationTests`, `OutputFolderSafetyTests`, `FileSafetyTests`).
4. Update `README.md`, `PRIVACY.md`, and `CHANGELOG.md` as the PRD requires. For PRIVACY, re-run and re-verify the grep claim verbatim.
5. When complete, write a `milestone-log.md` in this folder. Structure it as follows:
   - **Start with a `## What's new in the app` section at the very top** — a short, scannable, human-readable list of the user-facing changes, framed as capabilities the user will now see, not technical artifacts.
   - Then, for the next milestone's agent: what was built (files created, seams added), decisions made that weren't pre-specified in the PRD, anything milestone 2 needs to know, and any deviations from the PRD and why.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
