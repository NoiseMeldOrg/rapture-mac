# Milestone 2 — First-Run Destination Flow

You are entering plan mode to plan and then build milestone 2 of this feature.

## Context

- Read `@_build_plan/destination-onboarding/prd.md` for the full feature context, scope, data model, and locked decisions.
- Read `@_build_plan/destination-onboarding/milestones/1-vault-aware-destination/milestone-log.md` to understand what milestone 1 already built. **You are consuming M1's detection, containment, and consent — do not rebuild any of it.**

### Repo truth (the PRD is the *what*; these are the *how*)

- **`@CLAUDE.md`** — repo conventions. Critical here: **tests run inside the app**, so `@main` startup runs during `xcodebuild test`. Any launch-time side effect that hits a TCC-protected resource destabilizes the headless host — gate new startup machinery behind `RuntimeEnvironment.isRunningXCTests`. This milestone touches the launch path, so this rule is directly in your way if you ignore it.
- **`@agent-os/product/mission.md`** — "A capture system that drops messages — even occasionally — is worse than no system at all." That commitment is why the default folder stays as a safety net; see below.

### The exact files you will touch

- **`RaptureMac/RaptureMac/App/Pipeline.swift`** — `start()` calls `ensureDefaultOutputFolder()` at line ~82, before `startRelay`/`startTriage`/`startDestinationMonitor`/`attemptStart`. It is invoked from `RaptureMacApp.swift` via `MenuBarLabel`'s one-shot `.task`. **This is the exact seam where the folder is silently created today** — the menu-bar icon appears and the folder exists, with no window and no interaction.
- **`RaptureMac/RaptureMac/Persistence/SettingsStore.swift`** — `ensureDefaultOutputFolder()`. Its `guard settings.outputFolder == nil` is **the app's only first-run condition**. Everything you build keys off that fact.
- **`RaptureMac/RaptureMac/RaptureMacApp.swift`** — the `Window` scene declarations and `presentPermissionsIfNeeded`. The `"permissions"` window (id) is the **only** auto-presented window today, opened when `permissionState == .fullDiskAccessRequired`. Your destination window follows that pattern.
- **`RaptureMac/RaptureMac/UI/PermissionsView.swift`** — the existing FDA onboarding. It self-dismisses via `dismissWindow(id:)` on `.onChange(of: appState.permissionState)` when the grant lands. **Do not restyle or reorder the FDA step** — it's out of scope and it was dogfood-verified working. Your step comes *after* it.
- **`RaptureMac/RaptureMac/Models/PersistedState.swift`** — add `defaultDestinationNudgeDismissed` here, mirroring `triageIntroShown` at **five sites**: property, init default, assignment, `CodingKeys`, and **lenient decode** (`decodeIfPresent(Bool.self, forKey:) ?? false`). The lenient decode is **mandatory, not stylistic**: `StateStore.load` falls back to a fresh `PersistedState()` on any decode throw, so a strict key would wipe every existing user's ledgers. M2 sets this flag when the user picks "Keep the default"; M3 reads it.

### The load-bearing design constraint

**The default folder is still created as a safety net.** Do not gate folder creation on the user's answer. `mission.md` forbids dropping a capture, and a user who ignores the destination question for a day while dictating must not lose notes. The sequence is: default created (as today) → choice presented → picking a vault runs M1's migration, which is a no-op or trivial on a near-empty default folder. This is why M1 had to land first.

Useful corroboration: a nil `outputFolder` is already survivable everywhere (`DestinationMonitor.tick`, `RelayProcessor`, `BatchProcessor`, and `TriageWatcher` reads it lazily via `folderProvider`) — so you have latitude here. **Use that latitude for ordering, not for removing the safety net.**

### Reference implementations to mirror

- **`RaptureMac/RaptureMac/UI/PermissionsView.swift`** + its `Window` declaration in `RaptureMacApp.swift` — the shape for an auto-presented, self-dismissing onboarding window in an `LSUIElement` app. Note the `NSApp.activate(ignoringOtherApps:)` quirk: a menu-bar-only app must explicitly come to front.
- **`RaptureMac/RaptureMac/Handoff/HandoffEnableFlow.swift`** — the injected-closure, persist-on-success pattern, if your choice flow needs a testable decision seam.

## Your task

1. Plan the implementation for **only** milestone 2 as defined in the PRD. Do not plan or build anything from milestone 3 (no nudges, no vault-root rescue) and do not modify M1's detection/containment/consent beyond calling into it.
2. After the user confirms the plan, build only what is in milestone 2's scope.
3. Verify your work against the "Done when" criteria for milestone 2 in the PRD. This one needs a **real clean-install check**, not just unit tests: DEBUG builds use isolated containers (`Rapture for Mac (Debug)` / `~/Documents/Rapture Notes (Debug)/`) — remove those to simulate a fresh install without touching the installed app's real data. Tests must cover: the first-run condition, "keep the default" settling the question permanently, and a capture arriving before the choice is made still filing safely.
4. Update `README.md` and `CHANGELOG.md` as the PRD requires.
5. When complete, write a `milestone-log.md` in this folder. Structure it as follows:
   - **Start with a `## What's new in the app` section at the very top** — a short, scannable, human-readable list of the user-facing changes, framed as capabilities the user will now see, not technical artifacts.
   - Then, for the next milestone's agent: what was built, decisions made that weren't pre-specified in the PRD, anything milestone 3 needs to know (especially the exact semantics you gave `defaultDestinationNudgeDismissed`), and any deviations from the PRD and why.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
