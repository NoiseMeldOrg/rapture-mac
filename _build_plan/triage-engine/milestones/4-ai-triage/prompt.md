# Milestone 4 — AI Triage

You are entering plan mode to plan and then build milestone 4 of the triage-engine feature.

## Context

- Read `@_build_plan/triage-engine/prd.md` for the locked scope and this milestone's boundaries.
- Read the milestone logs for milestones 1–3 in `@_build_plan/triage-engine/milestones/` — especially milestone 1's watcher/pipeline decisions and milestone 3's detection seam (AI plugs into it here).
- Read the repo `@CLAUDE.md` and `@CONTRIBUTING.md`. Key references before planning:
  - **Engines.** Apple on-device foundation models via the FoundationModels framework — availability-gate at runtime (`#available(macOS 26.0, *)` plus the model-availability check; the deployment target stays macOS 14). The BYO-key engine calls the Anthropic Messages API with plain `URLSession` (no SDK — the no-new-dependencies rule holds). Consult the `claude-api` skill for current model IDs and request shapes; classification of short notes is a small-cheap-model task.
  - **Key storage.** The Anthropic key is the app's first secret — store in the Keychain, never in `settings.json`. Note `agent-os/product/tech-stack.md` currently says "no Keychain in v1"; this milestone updates that line.
  - **AI must never block filing.** Milestone 1 locked the deterministic fallback: AI unavailable/slow/erroring → the capture files deterministically, immediately, and is not retroactively re-triaged. Plan where AI sits in the arrival path so this holds under real latency (the capture-to-filed feel should stay in seconds).
  - `RaptureMac/RaptureMac/App/RuntimeEnvironment.swift` — no model calls or network from the test host; every AI path needs a seam with an injected fake for tests
  - `RaptureMac/RaptureMac/UI/SettingsView.swift` + `SettingsGeneralView.swift` — by this milestone the triage settings surface is getting large (mode, handoffs, AI toggle, key entry, engine status, privacy lines, enrichment next). Decide section-vs-dedicated-tab deliberately; the Settings window precedent supports either.
- **Behavioral reference (read if reachable):** `~/Documents/Rapture Notes/CLAUDE.md` — the classification hints list (top-wins ordering), the title-cleanup worked examples, and the conservative "when unsure, stash rather than act" posture. The app's taxonomy is the PRD's four classes (task/idea/journal/link) + `Notes/` fallback — do not import the rulebook's richer external classes.
- **Honest-docs rule for this milestone:** the BYO-key engine is the app's first user-facing outbound network capability beyond Sparkle. Ship it with a minimal truthful `PRIVACY.md`/`README.md` patch (opt-in, user-supplied key, what is sent where; the grep-verification claim must not be left stale). The full narrative overhaul is milestone 5, but nothing lands silently here.
- Tests: injected fake engine covering classify/title/format outputs and every failure mode (timeout, refusal, garbage output → deterministic fallback). Prompt-quality iteration against real engines is manual; the suite must pass with zero network and zero model access. Skills: `tdd`, `swift-concurrency`, `claude-api`.

## Your task

1. Plan the implementation for **only** milestone 4 as defined in the PRD (AI toggle, engine auto-resolution + status/privacy lines, secure key entry, task/idea/journal/link routing, smart titles, light body formatting with `## Raw`, sharper handoff detection behind the M3 toggles, deterministic fallback). No enrichment (milestone 5), no custom taxonomies, no gating.
2. After the user confirms the plan, build only what is in milestone 4's scope.
3. Verify against the PRD's "Done when" for milestone 4 — live checks with whichever engines this Mac supports, plus a forced-unavailability check showing immediate deterministic filing. Run the full test suite.
4. When complete, write a `milestone-log.md` in this folder summarizing what was built, unspecified decisions (prompt design, engine resolution details, Settings layout choice), anything milestone 5 needs to know, and any deviations.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
