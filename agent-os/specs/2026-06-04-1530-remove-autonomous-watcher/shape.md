# Shaping notes — remove autonomous watcher

## Scope

Remove the launchd-driven autonomous note processor (`com.user.rapture-notes-watch` + `Scripts/*-watch.sh` + the `claude-watch` half of `examples/claude-code/manifest.json` + the watcher-specific Swift integration code + tests). Keep the SessionStart hook as the one path for Claude-Code-driven triage. Keep the Integrations panel UI; the Claude Code card just collapses to a single install option.

## Decisions

- **Watcher-only removal, panel stays.** The Integrations panel UI shipped in v1.0.64 is fine — its design discovers consumers dynamically from `examples/<name>/manifest.json`. Dropping one `installs[]` entry naturally drops one card row; the framework doesn't need surgery. OpenClaw / Hermes / Generic CLI cards stay as documentation.
- **Live uninstall as part of this work.** Don't ship the new build with a stale launchd job still running.
- **Standards: N/A.** Matches the precedent set in `2026-05-16-1854-rapture-mac-v1-local-capture`. The repo's `agent-os/standards/` entries are placeholders pending `/index-standards`.
- **Visuals: none.** No new screens. The UI change is one card row disappearing.
- **Backward compat:** none needed. This is Michael's tool, Michael is the only user, the watcher is being deleted by the same person who installed it.

## Why this is happening (the panel's read, condensed)

The accountability panel (Volkar, Andrey, Susan, Jesus, Dad) was unanimous. Three load-bearing observations:

1. **The log shows zero processing since 2026-06-02.** The watcher has been broken for two days and Michael didn't notice. That's evidence it wasn't earning its keep, not that the bug was subtle.
2. **`claude -p` is the wrong shape for freeform routing.** Claude Code is interactive by design — TCC inheritance, permission prompting, real thinking. The watcher tried to harness it non-interactively with `--permission-mode bypassPermissions`, `< /dev/null` stdin tricks, and (next iteration) a `timeout` wrapper. Each workaround was a symptom of the wrong tool choice. The SessionStart hook is the right shape and already ships.
3. **The pattern in play was "shipping a feature to justify having built it."** The Integrations panel was shipped 2026-06-02. Two days later one of its install options was dead. Michael was about to fix it on reflex; the panel named that as theater, not engineering, and pushed for the simplification instead.

The pattern Susan named: "this is README polish at 11pm anger looking for a job." Today's earlier work (the iCloud-replay dedup `ContentDedupCache` + reply-text simplification, shipped as v1.0.65) was real engineering. The watcher rescue would have been busy-work dressed as urgency.

## Context

- **Visuals:** None.
- **References:** see `references.md`.
- **Product alignment:** preserves the mission's "the folder is the integration surface" commitment. Any LLM that reads files can still consume the folder. Removing the watcher removes one *delivery mechanism* for one specific consumer (Claude Code) and leaves the other delivery mechanism (the hook) — and every non-Claude-Code consumer — completely untouched.

## Standards applied

None — see `standards.md`.

## What we are NOT changing

- The menu-bar app's capture pipeline (chat.db poll, MessageFilter, EchoGuard, ContentDedupCache, FileWriter, Replier) — that's load-bearing and was just upgraded.
- The folder layout (`~/Documents/Rapture Notes/` with `.txt` files + `processed/YYYY-MM/`).
- The SessionStart hook installer (`Scripts/install-claude-hook.sh`) and its check script.
- The OpenClaw / Hermes / Generic CLI example cards.
- The Integrations panel framework (discovery, runner, bundled resources).

## Risk register

- **Risk:** removing files referenced from the Xcode project file might break the build if folder-sync doesn't update cleanly.
  - **Mitigation:** the project uses `fileSystemSynchronizedGroups` (verified during the v1.0.65 work). Deleting files from synced folders auto-removes them from the target.
- **Risk:** a test references a deleted file or type and the test target won't compile.
  - **Mitigation:** Task 7 walks each test file before deleting.
- **Risk:** the Integrations panel framework code (IntegrationRunner, etc.) has a watcher-specific code path that won't compile cleanly after the trim.
  - **Mitigation:** Task 5 reads each Swift source before editing.
