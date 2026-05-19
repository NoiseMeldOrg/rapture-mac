# Milestone 1 — First Capture

You are entering plan mode to plan and then build milestone 1 of this project.

## Context

- Read `@_build_plan/prd.md` for the milestone scope, data model, and "Done when" criteria.
- Read `@agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md` for line-level implementation detail (the 14 phases that group into the 4 milestones; this milestone covers phases 2–8 plus the FDA half of phase 13).
- Read `@agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md` for upstream references to port from (Anthropic's iMessage plugin `server.ts`, `openclaw/imsg`) and the data-plane "Swift port, not runtime imsg dep" ADR.
- Read `@agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md` for architectural decisions and constraints (why-local-only, why-not-Shortcut, why-not-MAS).
- This is Milestone 1; there is no prior `milestone-log.md` to read.
- `CLAUDE.md` (project agent instructions) is loaded automatically.

## Your task

1. Plan the implementation for **only** milestone 1 as defined in the PRD. Do not plan or build anything from later milestones.
2. After the user confirms the plan, build only what is in milestone 1's scope.
3. Verify your work against the "Done when" criteria for milestone 1 in the PRD.
4. When complete, write a `milestone-log.md` in this folder (`_build_plan/milestones/1-first-capture/milestone-log.md`) summarizing:
   - What was built (files created, models added, modules introduced)
   - Any decisions made during implementation that weren't pre-specified in the PRD
   - Anything the next milestone will need to know
   - Any deviations from the PRD and why

Ask me any clarifying questions using AskUserQuestion tool to lock in the implementation plan for this milestone.
