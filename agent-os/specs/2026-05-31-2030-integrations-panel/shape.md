# Integrations Panel — Shaping Notes

## Scope

A new **Integrations** tab inside the existing Settings window that lets a non-Terminal user install, configure, and monitor every downstream consumer of the Rapture notes folder (Claude Code SessionStart hook, autonomous launchd watcher, OpenClaw, Hermes, generic CLI, and whatever lands in `examples/` later) from the app UI.

The panel is **UI + state + invocation**. The shell scripts in `Scripts/` remain the source of truth for what each integration *does*; the panel shells out to them and parses the output. No install logic is reimplemented in Swift.

The panel is discovered dynamically from `examples/` at runtime: drop a new `examples/<name>/` folder (with an optional `manifest.json`) into the app bundle's `Resources/examples/`, and a card appears. No hardcoded list, no view-code change required to add a consumer.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Panel placement | New `.integrations` case in the existing `SettingsView` `TabView` | Slot into the existing window; don't redesign General/Allowlist/About. Brief explicitly excludes a Settings-window rebuild. |
| Card model | **One card per `examples/<name>/` folder**, install profiles stacked inside as disclosure sections | User choice during shaping. `examples/claude-code/` → one card with "SessionStart hook" and "Autonomous watcher" stacked. `examples/{cli,hermes,openclaw}/` → one informational card each (no install scripts in `Scripts/` today). |
| Discovery | Walk `Bundle.main.examplesURL` at runtime; one card per subfolder | Vendor-neutral by construction. Adding a new recipe is a file-system change, not a code change. |
| Manifest | `examples/<name>/manifest.json`, all fields optional | Defaults derived from filesystem (prettified folder name, README first paragraph after H1). Manifest overrides display name, description, declares `installs[]`, `docs[]`, per-install `config[]`, `requires`. Schema documented in new `examples/manifest-schema.md`. |
| Status source | `Scripts/status.sh` is the single live-state source; pure-function parser turns its `✓/✗ Label:` output into a typed `StatusReport` | `status.sh` was already designed to be parsed (structured ASCII). Polling it is cheap; reimplementing its launchd / fswatch / file-system checks in Swift would duplicate logic. |
| Status polling cadence | 5 s, only while the Integrations tab is visible | Matches the autonomous watcher's fastest interesting state-change (a note landing). Stops when the user leaves the tab — no idle background subprocess. |
| Subprocess invocation | Reuse the `AppleScriptSender` pattern: `Process()`, stdin/stderr pipes, typed `Error(exitCode, stderr)` | Same shape, same OSLog category, same failure surface as the only other subprocess in the app. |
| Script path resolution | `/bin/bash <bundled-resource-path>` — never `chmod +x` then exec | Hardened-runtime apps cannot rely on exec bits on Resources; `bash <path>` works regardless. Matches how the existing AppleScript sender passes the script via stdin. |
| Login-shell PATH | Captured once at app launch via `/bin/zsh -ilc 'echo $PATH'` and cached | `claude`, `jq`, `fswatch` live under `/opt/homebrew/bin`, which is not in the default `Process` env. Cache once, reuse for every script run. |
| Watcher config persistence | Write `~/.config/rapture-mac/watch.env` via `AtomicFile` (`.tmp` → `rename(2)`); re-run `install-claude-watch.sh` to inject into the launchd plist | Matches the existing config flow documented in `examples/watch.env.example` and `install-claude-watch.sh`'s PlistBuddy path. The panel does not edit the plist directly. |
| Bundling | One Run Script build phase in `RaptureMac.xcodeproj` that `rsync`s `Scripts/` and `examples/` into `Contents/Resources/` | Repo root stays the source of truth. Build copies in. No fetch-at-runtime (would violate PRIVACY.md's zero-outbound promise). |
| Prerequisite detection | `/usr/bin/which <name>` per declared CLI; missing → render copy-paste install command in a sheet | Honest about what's missing. No silent `brew install`. |
| TCC | Render `Grant permission…` deep-links unconditionally; no grant-state inspection | Inspecting TCC requires private APIs or `tccutil`. Deep-link is the same pattern `PermissionsView` already uses for FDA. |
| What ships in v1 of the panel | All four existing `examples/` folders surface as cards | Vendor neutrality. Only Claude Code has live install state today because it's the only one with bundled install scripts. CLI / Hermes / OpenClaw render with `Open README` + `Open in Finder` only. Future PRs add scripts to give them live state. |

## Why one card per folder (and not one per install profile)

The brief left this open and we picked **one card per folder, install profiles stacked inside** during shaping. The losing alternative was **one card per install profile** — Claude Code would have produced two top-level cards, "Claude Code — SessionStart hook" and "Claude Code — Autonomous watcher".

The folder-as-card model wins because:

1. **The folder is the unit of contribution.** `examples/<name>/` is what someone adds in a PR; the `README.md` lives at that level; the docs cross-reference (`README.md` ↔ `autonomous.md`) live inside the folder. One card per folder mirrors how contributors think about adding a consumer.
2. **Mode-relationship is preserved.** Hook and watcher are alternatives (`Run one or the other, not both — they'd race on the same files.` — autonomous.md:115). Stacking them inside the same card makes the choice visible. Two flat cards in a list would visually equate them with unrelated consumers like CLI or Hermes.
3. **Shared per-consumer state has a home.** Per-consumer-folder docs links, prerequisite badges that apply to all installs in the folder, and `Open in Finder` belong at the card level — not duplicated across two cards.

The trade-off is denser cards. For Claude Code specifically (the only multi-install folder today), the card will be tall. Disclosure sections (`▸ Section name`) collapse the less-relevant install when both are present, so the visual weight is manageable.

## Why filesystem-walk discovery (and not a hardcoded list)

Vendor neutrality is structural, not editorial. README states *"the folder is the only integration surface."* If the panel hardcoded a list of consumers, every new recipe would need a Swift change before it could ship — which gates additions on the maintainer's release cadence and makes Claude / OpenClaw / Hermes / CLI privileged tenants rather than peers.

Filesystem walk inverts that: a contributor adds `examples/<their-tool>/`, drops in a `README.md` (and optionally a `manifest.json` if they want live install state), and the next build of the app shows their card automatically. No code review of the SwiftUI side, no naming the consumer in `IntegrationDiscovery.swift`, no list to maintain.

The cost is a runtime directory walk on app launch. With four folders today it's negligible; even at 50 consumers it's a single `FileManager.contentsOfDirectory` call plus 50 small JSON reads, done once per launch.

## Why bundle Scripts + examples (and not fetch at runtime)

PRIVACY.md commits — provably, via grep — to zero outbound network calls. The README's install story today is `curl … | bash`, which works fine when the user is in their shell. The panel could mimic that by `curl`ing scripts from `raw.githubusercontent.com` at install-button time.

That would break the privacy promise. Worse, it would be invisible-to-the-user breakage: an `URLSession` call buried in a button handler is not what someone reading PRIVACY.md expects when they verified there are no network entitlements.

Bundling sidesteps the whole question. The scripts ship as Resources, signed and notarized with the app. Installing a consumer is a local file-read + a `/bin/bash` subprocess — same trust boundary as the existing `osascript` reply. The privacy posture stays honest.

Downside: a user who wants the *latest* install script must update the app. Acceptable. The scripts are small and stable; the auto-version bumps on every commit anyway.

## Why don't break the capture pipeline

The chat.db capture pipeline (`ChatDBWatcher`, `AttributedBodyDecoder`, `MessageFilter`, `SelfHandleResolver`, `FileWriter`, `EchoGuard`, `AppleScriptSender`, `Replier`) is the product. Everything in v1.0.x — including the echo-cascade fixes (v1.0.27) and dedup-by-guid (v1.0.29) — is hard-won by responding to real incidents in production with real users. The Integrations panel adds value at the layer *above* the captures (downstream consumers of the folder) and has no business touching anything in the capture path.

This is mechanically enforced by milestone scope: the new code lives entirely in `RaptureMac/Integrations/`, the only modified existing files are `SettingsView.swift` (one new tab case), `AppState.swift` (one new property), `project.pbxproj` (one new build phase), and `CHANGELOG.md`. The 73-test suite must pass unchanged before any PR opens.

## Why no log viewer / no in-app CLAUDE.md editor

Two scope guardrails the brief calls out, both honored:

- **`Open logs`** runs `open -t /tmp/rapture-notes-watch.out.log` — opens the user's default `.txt` viewer (often BBEdit, TextEdit, or `tail -f` in Terminal via their `.txt` association). Building a log viewer in-app would re-implement `Console.app` poorly for one specific case.
- **CLAUDE.md routing rules** are user-customized per the README's example flow. The panel offers `Open in Finder` on the notes folder; from there the user opens `CLAUDE.md` in whatever editor they like. Building an editor would imply a schema we'd have to evolve, which there isn't — the file is freeform markdown.

## Why TCC deep-links are unconditional (no grant-state detection)

The `PermissionsView` pattern for Full Disk Access polls every 2 s waiting for the OS to update the read-availability of `chat.db`. That works because `chat.db` is a file we can attempt to open and observe success/failure of. There is no equivalent for Reminders / Calendar / Contacts — TCC grant state is held in a system-protected database that requires private APIs or `tccutil` to inspect.

So the panel renders the `Grant permission…` button unconditionally. The user clicks it whether or not it's needed; if they've already granted, the System Settings pane opens and shows the toggle as on — harmless. The opposite (omitting the button because we *think* they've granted) would silently leave a user wondering why their consumer doesn't work.

## Context

- **Visuals:** None provided. The card mockup the user picked during shaping (preview in the AskUserQuestion that drove the card-model decision) is the design contract. Screenshots will be added to the PR description, not this spec.
- **References:** Three existing-codebase references, plus the upstream v1 spec for voice and structure. See `references.md`.
- **Product alignment:** Reinforces the README's *"the folder is the only integration surface"* posture by making vendor-neutrality structurally enforceable (filesystem-walk discovery) rather than editorially. Sits above the v1 capture pipeline; does not modify it.
- **Out of scope (carried from the v1 spec):** No networking. No telemetry. No Mac App Store. No analytics. No auto-update. The Integrations panel's existence does not change any of these.

## Standards Applied

- **None applicable** (same posture as the v1 spec).
- New code follows the established conventions: `@Observable @MainActor`, atomic file writes via the project's existing helper, OSLog subsystem `noisemeld.RaptureMac`, pure-helper test pattern (extract decision logic into `nonisolated static` helpers), XCTest with fixtures under `RaptureMacTests/Fixtures/`.
