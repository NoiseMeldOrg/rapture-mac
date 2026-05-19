# Milestone 4 — Public Release

You are entering plan mode to plan and then build milestone 4 of this project.

## Context

- Read `@_build_plan/prd.md` for the milestone scope and "Done when" criteria.
- Read `@agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md` for line-level implementation detail (this milestone covers phase 14 — code signing, notarization, DMG packaging — plus the FOSS public-flip work).
- Read `@agent-os/product/tech-stack.md` "Distribution" section for the signing team (`P8PLTH44DF`), notarization API key (`GX6DYX9S2M`), and the canonical commitment to GitHub Releases as the distribution channel.
- Read `@agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md` for the "Why this can't be in the Mac App Store" rationale (so the agent doesn't propose MAS submission as part of this milestone).
- Read all prior milestone logs (`@_build_plan/milestones/1-first-capture/milestone-log.md`, `@_build_plan/milestones/2-confirmation-and-recovery/milestone-log.md`, `@_build_plan/milestones/3-user-control/milestone-log.md`) for context on what's built and how.
- `CLAUDE.md` (project agent instructions) is loaded automatically.

## Your task

1. Plan the implementation for **only** milestone 4 as defined in the PRD. Do not plan or build anything from later milestones.
2. After the user confirms the plan, build only what is in milestone 4's scope. This milestone is mostly tooling and distribution — signing build phase, notarization script, DMG packaging, public-repo flip, supporting docs (`SECURITY.md`, `CONTRIBUTING.md`), and the first GitHub Release.
3. Verify your work against the "Done when" criteria for milestone 4 in the PRD.
4. When complete, write a `milestone-log.md` in this folder (`_build_plan/milestones/4-public-release/milestone-log.md`) summarizing:
   - What was built (build phases, scripts, tooling, docs)
   - The signing/notarization output paths and how to reproduce a release
   - Any decisions made during implementation that weren't pre-specified in the PRD
   - Any deviations from the PRD and why

Ask me any clarifying questions using AskUserQuestion tool to lock in the implementation plan for this milestone.
