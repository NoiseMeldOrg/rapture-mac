# References

## The spec being partially undone

### `agent-os/specs/2026-05-31-2030-integrations-panel/`
The spec that introduced the Integrations panel, including the `claude-watch` install option this work removes. Read for the rationale that was load-bearing at the time and to understand what stays vs. what goes. The panel framework (discovery, runner, bundled resources) was the durable part; the autonomous watcher half of the Claude Code card was the part that didn't survive contact with reality.

## The shape that stays — examples for the trimmed manifest

### `examples/claude-code/manifest.json` lines 11-21 (the surviving `claude-hook` entry)
After Task 3 trims the file, this is what the entire `installs[]` array looks like — one entry. Use it as the model.

### `examples/openclaw/manifest.json`, `examples/hermes/manifest.json`, `examples/cli/manifest.json`
Peer cards in the panel that already work as documentation-only (no `start`/`stop`/`restart`/`configFile`/`config`/`logs` keys, no runtime daemon). They prove the panel framework handles a card with a single install option (or zero — pure docs) without special-casing. The Claude Code card joins their shape after this change.

## The product commitment this change preserves

### `agent-os/product/mission.md` — "The folder is the integration surface" section
> "The output is intentionally trivial: one `.txt` file per captured message in a folder the user chose. No SDK, no protocol, no API, no Claude lock-in. … This is a hard product commitment, not an aspiration."

The autonomous watcher was a *delivery mechanism for one specific Claude Code consumer*, not the integration surface. The folder is the integration surface, the folder stays, and any LLM that reads files (including Claude Code via the hook) still consumes the folder. Removing the watcher does not touch the cross-LLM compatibility commitment.

## The fix that ran alongside this shaping

### `CHANGELOG.md` `[Unreleased]` block (as of 2026-06-04)
The same session that shaped this spec also shipped v1.0.65 — `ContentDedupCache` + `✅ Saved` reply-text simplification. Task 8 of this spec adds a `### Removed` block to the same `[Unreleased]` section. The two changes land in the same release.

### `RaptureMac/Filter/ContentDedupCache.swift`
Reference for the structural pattern this spec doesn't repeat — load-bearing component, kept and hardened. The accountability panel cited it as the contrast: "the dedup fix today was real engineering; the watcher rescue is theater."
