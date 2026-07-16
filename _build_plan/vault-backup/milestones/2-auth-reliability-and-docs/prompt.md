# Milestone 2 — Auth Reliability, Failure UX & Docs

You are entering plan mode to plan and then build milestone 2 of this feature.

## Context

- Read `@_build_plan/vault-backup/prd.md` for the full feature context and locked decisions.
- Read `@_build_plan/vault-backup/milestones/1-backup-engine/milestone-log.md` to understand what M1 built — **especially the git-runner protocol seam and exactly how M1 records/surfaces errors.** M2 builds auth-failure and divergence-failure UX on top of that; do not rebuild the engine.

### Repo truth (the PRD is the *what*; these are the *how*)

- **`@CLAUDE.md`** — the hard rule that governs this milestone: **any new networking must update PRIVACY's grep claim in the same change as the code.** M1 confined all `git` invocation to one file; M2 makes PRIVACY tell the truth about it. This milestone is *mostly* that docs pass plus the failure UX.
- **`@PRIVACY.md`** — read the current grep claim in full. It currently asserts `grep URLSession\.` returns exactly three files (`TriageAI/AnthropicEngine.swift`, `TriageAI/AnthropicWire.swift`, `Enrichment/URLSessionLinkFetcher.swift`). You are adding a **second mechanism** (a `git` subprocess) and a **fourth file**. The claim becomes "two mechanisms, four files": the three `URLSession` files, plus the one file M1 confined `git` invocation to. Add a second grep (for the `git` executable path / `Process` launch in that file) and re-verify **both** greps verbatim, pasting the real output.
- **`@agent-os/product/tech-stack.md`** — the enumerated-outbound list (currently Sparkle + Anthropic + link enrichment). Add `git` via `Process`.

### The exact files to touch

- **The git-runner file from M1** (e.g. `RaptureMac/RaptureMac/VaultBackup/GitBackupRunner.swift`) — add remote-protocol detection (SSH vs HTTPS) and classify a push failure as auth-vs-divergence-vs-other. Keep it the single confined networking file.
- **`RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`** — the backup status line from M1 gains specific, actionable failure states (auth failure names the fix; divergence says "resolve in git/Obsidian"; offline and nothing-to-commit stay distinct and calm).
- **Docs (mandatory, same change as the code that makes them true):**
  - **`PRIVACY.md`** — fourth outbound path (git push, opt-in, only to the user's own already-configured remote — no new recipient), the second grep, the "two mechanisms, four files" framing, re-verified verbatim.
  - **`SECURITY.md`** — the new capability; the `.gitignore`-respecting, never-`-f` guarantee (the audit that confirmed `.gitignore` protects `Security/` + the SSN note was 2026-07-15).
  - **`README.md`** — capture → triage → version-controlled off-site.
  - **`CHANGELOG.md`** — the feature entry.
  - Decide whether a dated `agent-os/specs/` folder + a `roadmap.md` line are warranted as durable truth (triage-engine M5 is the precedent for that backport).

### Locked decisions (do not re-litigate)

- **The app never rewrites the user's remote, generates keys, or calls the GitHub API.** It *diagnoses* and *guides*. The HTTPS→SSH switch is a documented setup step (done by hand for this install on 2026-07-16); the app tells the user when it's needed and why, and stops there.
- **A conflict rebase can't resolve is surfaced, never force-pushed and never auto-merged.**
- **Auth failure, divergence failure, drive-offline, and nothing-to-commit are four visually distinct, calm states** — not one generic "backup failed."

### Why the auth UX matters (the motivating history)

The obsidian-git plugin made **zero commits for three days and nobody noticed**, almost certainly because HTTPS + `git-credential-osxkeychain` couldn't authenticate in its environment and it failed silently. The entire justification for this feature living in Rapture is that it *won't* be silent. So the single most important thing M2 ships is: when a push can't authenticate, the user *sees* a specific message that names the fix (switch the remote to SSH), not a generic failure and not nothing.

## Your task

1. Plan the implementation for **only** milestone 2.
2. After the user confirms the plan, build it.
3. Verify against the "Done when" criteria. Tests still run with **no real `git` and no network**: use the injected runner to simulate auth-failure and unresolvable-divergence and assert the correct distinct error states surface. Re-run PRIVACY's greps verbatim as part of verification and paste the output.
4. Write a `milestone-log.md` in this folder:
   - **Start with `## What's new in the app`** — the user-facing changes, framed as capabilities.
   - Then: what was built, decisions not pre-specified, any residuals, and deviations from the PRD and why. This completes the feature — note whether a durable `agent-os/specs/` backport was done.

Ask clarifying questions with the AskUserQuestion tool to lock the plan.
