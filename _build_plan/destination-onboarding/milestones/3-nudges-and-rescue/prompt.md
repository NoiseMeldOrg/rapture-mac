# Milestone 3 — Nudges & Vault-Root Rescue

You are entering plan mode to plan and then build milestone 3 of this feature.

## Context

- Read `@_build_plan/destination-onboarding/prd.md` for the full feature context, scope, data model, and locked decisions.
- Read **both** prior milestone logs — `@_build_plan/destination-onboarding/milestones/1-vault-aware-destination/milestone-log.md` and `@_build_plan/destination-onboarding/milestones/2-first-run-flow/milestone-log.md`. M1 owns detection/containment/consent; M2 owns the first-run choice and the exact semantics of `defaultDestinationNudgeDismissed`. **You consume both — rebuild neither.**

### Repo truth (the PRD is the *what*; these are the *how*)

- **`@CLAUDE.md`** — repo conventions.
- **`@agent-os/product/mission.md`** — the folder is the UI; the app never becomes a nag or a manager of the user's own notes.

### Why this milestone exists

M1 and M2 only reach people who open Settings or install fresh. **This milestone reaches the person the whole feature was written for**: the one who already installed Rapture, never got asked, and has a week of correctly-triaged notes stranded in the default folder. That was a real dogfood outcome, not a hypothetical.

### The exact files you will touch

- **`RaptureMac/RaptureMac/UI/MenuBarView.swift`** — `triageIntroNotice` (~lines 57–86) is the notice pattern to copy, rendered at ~line 21 between `statusBlock` and the `Divider()`. Layout: `HStack(alignment: .top, spacing: 8)` → 16pt SF Symbol → `VStack` of `.caption` headline + `.caption2` secondary → `Spacer()` → plain `xmark.circle.fill` with `.accessibilityLabel("Dismiss")`. Dismissal persists via `appState.state.update { $0.triageIntroShown = true }` → `StateStore.update` → atomic `state.json` write.
- **`RaptureMac/RaptureMac/UI/MenuBarStatus.swift`** — **do not add a new `Kind`.** `MenuBarStatus.Kind` is a closed enum consumed in `MenuBarView`. "Still on the default folder" is not a status — `.capturing` is the truthful state; the app is working correctly, just in the wrong place. The notice slot is the right home.
- **`RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`** — `outputFolderSection` is where the quiet permanent line goes, alongside the existing `relocationStatusView` / `destinationOfflineStatusView` inline-status patterns.
- **`RaptureMac/RaptureMac/Models/PersistedState.swift`** — `defaultDestinationNudgeDismissed` (added in M2). Read M2's log for its exact semantics before using it. If M3 needs a second flag for the rescue notice, mirror the same five sites, **lenient decode included** — a strict key wipes every existing user's ledgers via `StateStore.load`'s fallback.
- **`RaptureMac/RaptureMac/App/AppState.swift`** — `setOutputFolder`, which both surfaces route into. Neither notice may switch a destination on its own.

### The hard part: vault-root rescue

`OutputFolderMigrator.migrate` **refuses nested paths** — `isAncestor` in either direction throws `MigrationError.nestedPaths`. So moving `<vault>` → `<vault>/Rapture Inbox` is rejected outright, and the rescue **cannot** simply call `setOutputFolder` with a nested target. It needs its own mechanism.

Two cautions from the code map, both load-bearing:

- **The ledgers key off destination-relative paths** (`CaptureContract.relativePath(of:in:)`), and their `remap` only handles collision renames. If the rescue changes the root without a real relocation, every stored relative path silently points one level up. Whatever mechanism you choose must leave `TriageLedger` and `EnrichedLinkLedger` resolving correctly — prove it with a test, not by inspection.
- **`migrate` moves every top-level item including dotfiles.** A vault root holds `.obsidian/` and the user's own notes. The rescue must move **only Rapture's own folders** (`Notes/`, `Links/`, `Tasks/`, `Ideas/`, `Journal/`, `Links/Media/`, and note+attachment sibling folders) — never the vault's content. This is the one place in the codebase where "move the whole tree" is exactly wrong. Do not repurpose `migrate` for it, and do not weaken `migrate` to allow it.

Related known gap, **explicitly not yours to fix**: `OutputFolderMigrator` has no guard preventing a vault root from being adopted as an output folder and later having `.obsidian/` moved out from under Obsidian by a subsequent relocation. It's logged separately. Don't fold it in; don't make it worse.

### Reference implementations to mirror

- **`RaptureMac/RaptureMac/UI/MenuBarView.swift`** → `triageIntroNotice` — the notice shape and its persisted dismissal.
- **`RaptureMac/RaptureMac/Handoff/HandoffEnableFlow.swift`** — injected-closure decision seams, so tests never block on a real dialog.

## Your task

1. Plan the implementation for **only** milestone 3 as defined in the PRD.
2. After the user confirms the plan, build only what is in milestone 3's scope.
3. Verify your work against the "Done when" criteria for milestone 3 in the PRD. Tests are **mandatory** and must cover: the notice appearing only when a vault is detected AND the user is on the default AND the question is unsettled; dismissal persisting across relaunch; the Settings line surviving dismissal; vault-root detection; and — most importantly — **the rescue leaving both ledgers resolving and the vault's own content untouched**.
4. Update `README.md` and `CHANGELOG.md` as the PRD requires. This milestone completes the feature, so also check whether `agent-os/product/roadmap.md` and a dated `agent-os/specs/` folder should record it as durable truth (the triage engine's M5 is the precedent — see `_build_plan/triage-engine/milestones/5-link-enrichment-story/milestone-log.md` for how that backport was done).
5. When complete, write a `milestone-log.md` in this folder. Structure it as follows:
   - **Start with a `## What's new in the app` section at the very top** — a short, scannable, human-readable list of the user-facing changes, framed as capabilities the user will now see, not technical artifacts.
   - Then: what was built, decisions made that weren't pre-specified in the PRD, any residuals or known gaps worth carrying forward, and any deviations from the PRD and why.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
