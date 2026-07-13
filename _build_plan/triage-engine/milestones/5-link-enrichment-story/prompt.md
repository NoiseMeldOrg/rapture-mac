# Milestone 5 — Link Enrichment & the New Story

You are entering plan mode to plan and then build milestone 5 (the final milestone) of the triage-engine feature.

## Context

- Read `@_build_plan/triage-engine/prd.md` for the locked scope and this milestone's boundaries.
- Read all prior milestone logs in `@_build_plan/triage-engine/milestones/`.
- Read the repo `@CLAUDE.md` and `@CONTRIBUTING.md`. Key references before planning:
  - `RaptureMac/RaptureMac/App/UpdaterController.swift` — the only prior outbound-network precedent (Sparkle, narrowly scoped, `SUEnableSystemProfiling = NO`); enrichment fetching should be equally narrow and equally documented
  - Enrichment mechanics: plain `URLSession`, no keys, no new dependencies. Article extraction = fetch HTML + readability-style text extraction in Swift. YouTube transcripts = unofficial caption endpoints, explicitly best-effort and expected to break occasionally — quiet retries, then silent give-up; the link note is always already filed and complete without the artifact. Never fetch from the test host (`isRunningXCTests`) and never fetch when the toggle is off.
  - Dedup fingerprints (mirroring the user's proven rulebook at `~/Documents/Rapture Notes/CLAUDE.md`): YouTube = the video ID (the slug after `v=` / `youtu.be/` / `shorts/` / `live/` — query params vary, the ID doesn't); articles = normalized URL (lowercase host, strip fragments and `utm_*`/tracking params, trailing slash). A re-captured duplicate files a new note pointing at the existing artifact — no re-fetch.
  - Artifact shape references: the `extract-transcript` and `extract-webpage` skills (installed globally on this machine) show what good transcript/article markdown looks like — mine their output conventions, not their implementations.
  - Rename-on-enrich: the one-time real-title rename happens only in the arrival window; reuse the collision walk; the appended artifact link must use a vault-agnostic relative markdown link.
- **The docs overhaul is half this milestone, not an afterthought.** Coordinated updates, all consistent with the shipped binary:
  - `README.md` — the story becomes capture → triage → your notes, no scripts required; the "Network: zero outbound" badge and verification prose must change to an honest statement of the three network capabilities (Sparkle always; Anthropic engine and enrichment, both opt-in)
  - `PRIVACY.md` — what is fetched/sent, when, under which toggles; updated verification instructions replacing the stale grep claim; permissions table complete
  - `agent-os/product/mission.md` + `CONTEXT.md` — the documented commitment reversal: output neutrality (any AI reads the triaged Markdown) replaces processing neutrality; in-app triage is now the product's core loop
  - `examples/` folder + `RaptureMac/RaptureMac/Persistence/OutputFolderScaffold.swift` template — reconcile the external-consumer story with built-in triage (downstream agents now consume triaged Markdown, not raw `.txt`)
- **Backport before done (Agent OS convention):** distill the durable design decisions from all five milestone logs into a dated `agent-os/specs/<YYYY-MM-DD-HHMM>-triage-engine/` folder and update `agent-os/product/roadmap.md` and `tech-stack.md`. `_build_plan/triage-engine/` stays as the frozen historical snapshot.
- Tests: fetching behind a seam with injected fixture responses (real YouTube/article HTML captured as fixtures); extraction and fingerprint normalization as pure, table-driven tests. Skills: `tdd`, `swift-concurrency`.

## Your task

1. Plan the implementation for **only** milestone 5 as defined in the PRD (enrichment toggle, transcript + article artifacts in `Links/Media/`, real-title rename + appended artifact link, enrichment dedup, quiet failure posture, and the full coordinated docs overhaul + agent-os backport). No X/Facebook/Instagram, no media downloads, no summarization, no backfill.
2. After the user confirms the plan, build only what is in milestone 5's scope.
3. Verify against the PRD's "Done when" for milestone 5 — live checks: a YouTube capture yields a renamed note + transcript artifact; an article capture yields an extract; a repeat capture doesn't re-fetch; enrichment off = no outbound requests beyond Sparkle (verify empirically, not just by grep); docs match the binary. Run the full test suite.
4. When complete, write a `milestone-log.md` in this folder summarizing what was built, unspecified decisions (extraction approach, retry/give-up policy, docs framing choices), the completed backport, and any deviations.

Ask me any clarifying questions using the AskUserQuestion tool to lock in the implementation plan for this milestone.
