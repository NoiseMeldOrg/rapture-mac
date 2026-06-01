# Integrations Panel — v1

> Spec snapshot from shaping session 2026-05-31-2030. Mirrors the structure of `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md`.

## Context

The shell scripts in `Scripts/` already let a Terminal-comfortable user install, configure, and supervise downstream consumers of the Rapture notes folder — the Claude Code SessionStart hook, the autonomous launchd watcher, and (eventually) any future install scripts for OpenClaw / Hermes / CLI. They are battle-tested, idempotent, and print structured `✓/✗ Label:` lines designed to be parsed.

The gap: a non-Terminal user cannot reach them. Today's install story is `curl https://raw.githubusercontent.com/… | bash`, which assumes a shell, a `brew` install of `jq` / `fswatch`, and willingness to read `status.sh` output by hand.

The Integrations panel closes the gap by surfacing every `examples/<name>/` folder as a card inside the existing Settings window, with action buttons that shell out to the bundled scripts. The panel is **UI + state + invocation only** — it does not reimplement install logic in Swift.

## Decisions (locked during shaping)

| | |
|---|---|
| Panel placement | New `.integrations` case in the existing `SettingsView` `TabView` |
| Card model | One card per `examples/<name>/` folder; install profiles stacked as disclosure sections |
| Discovery | Filesystem walk of `Bundle.main.examplesURL` at app launch |
| Manifest | `examples/<name>/manifest.json`, all fields optional; defaults derived from filesystem |
| Status source | `Scripts/status.sh` polled every 5 s while the Integrations tab is visible |
| Subprocess shape | `/bin/bash <bundled-script>`, env vars passed; mirrors `AppleScriptSender` pattern |
| Login-shell PATH | Cached once at app launch from `/bin/zsh -ilc 'echo $PATH'` |
| Watcher config persistence | `~/.config/rapture-mac/watch.env` via `AtomicFile`; re-run install to inject into the launchd plist |
| Bundling | Run Script build phase rsyncs `Scripts/` + `examples/` into `Contents/Resources/` |
| Prerequisite detection | `/usr/bin/which <name>` for each declared CLI; missing → copy-paste sheet |
| TCC | Unconditional `Grant permission…` deep-link buttons; no grant-state inspection |
| Cards shipped in v1 of the panel | All four existing `examples/` folders (claude-code, cli, hermes, openclaw) |
| Capture pipeline | **Not modified.** Existing 73-test suite must pass unchanged. |

## Reference contracts (verified during shaping)

These are the exact contracts the Swift code must honor. Drift here breaks the panel silently.

### `Scripts/status.sh` output format

`status.sh` is the single live-state source. Its output is structured ASCII with one `  ✓/✗ Label: value` line per fact. The parser regexes against this shape:

```
Rapture for Mac — Claude Code integration status
=================================================

SessionStart hook (opportunistic):
  ✓ Check script: <abs-path>
  ✓ Registered in <abs-path>

Event-driven watcher (autonomous):
  ✓ Worker script: <abs-path>
  ✓ Plist: <abs-path>
  ✓ Loaded in launchd (PID <N>; last exit code: <N>)         | or: (idle; last exit code: <N>)
  ✓ fswatch running: PID <N>                                  | absent if not running
  Last log line: [<iso-ts>] <free-form>

Notes folder:
  Path:        <abs-path>
  Source:      from Rapture's sidecar | from default
  Pending:     <N> .txt file(s) in root
  ✓ CLAUDE.md routing rules present                           | or: ✗ CLAUDE.md routing rules missing
```

Negative states use `✗ Not installed: <path> is missing` for hook script / worker / plist. Absent sections (e.g. `fswatch running:` when fswatch is dead) are detected by their absence in the output, not by a `✗` marker.

The parser is `nonisolated static func parse(_ stdout: String) -> StatusReport`. Pure function. Tested against captured-output fixtures for: nothing-installed, hook-only, watcher-loaded-running, watcher-loaded-idle, watcher-plist-only-not-loaded, fswatch-dead-but-launchd-up, pending 0/N, CLAUDE.md present/missing.

### `manifest.json` schema

All fields optional. Defaults fall through to filesystem-derived values.

```jsonc
{
  "displayName": "Claude Code",                    // default: prettified folder name
  "description": "Watch the notes folder…",        // default: first paragraph after README.md H1
  "docs": [                                        // default: ["README.md"] if present
    { "label": "Overview", "file": "README.md" },
    { "label": "Autonomous mode", "file": "autonomous.md" }
  ],
  "installs": [                                    // default: []
    {
      "id": "claude-hook",
      "name": "SessionStart hook",
      "description": "Opportunistic. Fires when you next open Claude Code.",
      "install": "Scripts/install-claude-hook.sh",     // path relative to bundle Resources root
      "uninstall": "Scripts/uninstall-claude-hook.sh",
      "statusKey": "hook",                              // which status-report section drives the pill
      "requires": { "cli": ["claude", "jq"] }
    },
    {
      "id": "claude-watch",
      "name": "Autonomous watcher",
      "description": "Sub-second. Always-on. Uses Agent SDK credits.",
      "install": "Scripts/install-claude-watch.sh",
      "uninstall": "Scripts/uninstall-claude-watch.sh",
      "start": "Scripts/start-watch.sh",
      "stop": "Scripts/stop-watch.sh",
      "restart": "Scripts/restart-watch.sh",
      "logs": [
        "/tmp/rapture-notes-watch.out.log",
        "/tmp/rapture-notes-watch.err.log"
      ],
      "statusKey": "watcher",
      "configFile": "~/.config/rapture-mac/watch.env",
      "config": [
        { "key": "RAPTURE_CLAUDE_WORKDIR", "label": "Claude workdir", "type": "folder", "default": "$HOME" },
        { "key": "RAPTURE_MEDIA_MODEL", "label": "Media model", "type": "select",
          "options": ["haiku", "sonnet", "opus"], "default": "sonnet" },
        { "key": "RAPTURE_TEXT_MODEL", "label": "Text model", "type": "select",
          "options": ["haiku", "sonnet", "opus"], "default": "haiku" }
      ],
      "requires": { "cli": ["claude", "jq", "fswatch"], "tcc": ["Reminders"] }
    }
  ]
}
```

`statusKey` values understood by the parser in v1: `"hook"`, `"watcher"`. Unknown values render a `?` pill on the card (the install is recognized, but its live state isn't checkable). The schema documentation lives at `examples/manifest-schema.md`.

### Watcher config flow

User changes a field in the watcher's config form (e.g. picks a new workdir):

1. Panel writes the field to `~/.config/rapture-mac/watch.env` via `AtomicFile.write(_:to:)`. (Create parent dir if missing.)
2. Panel shells out to `/bin/bash <bundle>/Scripts/install-claude-watch.sh`. The installer reads `watch.env` (lines 227–238 of the script today) and injects each KEY=VALUE into the launchd plist's `EnvironmentVariables` via `PlistBuddy`.
3. Installer reloads the launchd job.
4. Panel re-polls `status.sh`; card updates.

No PlistBuddy call from Swift. The script owns the plist mutation.

### TCC deep-link map

| `tcc` value | URL |
|---|---|
| `"Reminders"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders` |
| `"Calendar"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Calendar` |
| `"Contacts"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts` |
| `"Accessibility"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| `"FullDiskAccess"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles` |
| `"Automation"` | `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` |

Unrecognized `tcc` values render the button but open System Settings to the Privacy & Security root.

---

## Phase 1: Spec docs (this folder)

Already done by writing this file plus `shape.md`, `references.md`, `standards.md` in `agent-os/specs/2026-05-31-2030-integrations-panel/`. `visuals/` is empty; screenshots ride the PR.

## Phase 2: Bundle Scripts/ + examples/ as Resources

Add a single Run Script build phase to `RaptureMac.xcodeproj`'s main app target, after Compile Sources and before Code Signing. Phase script:

```sh
set -euo pipefail
SRC="${SRCROOT}/.."
DEST="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/Resources"
rsync -a --delete --exclude='._*' --exclude='.DS_Store' "${SRC}/Scripts/" "${DEST}/Scripts/"
rsync -a --delete --exclude='._*' --exclude='.DS_Store' "${SRC}/examples/" "${DEST}/examples/"
```

Add **input file paths** so Xcode invalidates the phase when the trees change:
- `$(SRCROOT)/../Scripts/`
- `$(SRCROOT)/../examples/`

Add **output file paths**:
- `$(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Resources/Scripts/`
- `$(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Resources/examples/`

Then ship a `BundledResources.swift` helper:

```swift
extension Bundle {
    var scriptsURL: URL  { resourceURL!.appendingPathComponent("Scripts",  isDirectory: true) }
    var examplesURL: URL { resourceURL!.appendingPathComponent("examples", isDirectory: true) }
}
```

Verify: `xcodebuild` produces `.app/Contents/Resources/{Scripts,examples}/` populated. `codesign --verify --deep --strict --verbose=2 <app>` passes. `Scripts/release.sh` end-to-end notarizes successfully; `xcrun stapler validate <dmg>` and `spctl --assess --type install <dmg>` both succeed.

## Phase 3: Manifest schema + 4 manifest.json files

Write `examples/manifest-schema.md` documenting the schema in the Reference contracts section above. One paragraph per field. Include a concrete `claude-code/manifest.json` excerpt.

Author the four manifests:

- **`examples/claude-code/manifest.json`** — two installs (`claude-hook`, `claude-watch`); the watcher declares `start`/`stop`/`restart`, `configFile`, the three config fields, `logs`, and `requires.{cli,tcc}`.
- **`examples/cli/manifest.json`** — `installs: []`. Just sets `displayName` to "Generic CLI" and `docs: [{label: "README", file: "README.md"}]`.
- **`examples/hermes/manifest.json`** — `installs: []`. Docs link to README and SKILL.md.
- **`examples/openclaw/manifest.json`** — `installs: []`. Docs link to README and SKILL.md.

The three informational manifests exist for explicit-display-name control. Without them, the cards would still render — discovery derives the name from the folder, the description from the README first paragraph — but writing the manifest makes the contract visible at the file level.

## Phase 4: IntegrationDiscovery.swift + tests

`RaptureMac/Integrations/IntegrationDiscovery.swift`:

```swift
struct ConsumerCard: Identifiable, Equatable {
    let id: String              // folder name
    let displayName: String
    let description: String
    let folderURL: URL
    let docs: [DocLink]
    let installs: [InstallProfile]
}

struct DocLink: Identifiable, Equatable { let id: String; let label: String; let fileURL: URL }

struct InstallProfile: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let install: URL?           // bundled-script absolute URL
    let uninstall: URL?
    let start: URL?
    let stop: URL?
    let restart: URL?
    let logs: [URL]
    let statusKey: StatusKey?   // .hook | .watcher | .unknown(String)
    let configFile: URL?        // expanded ~
    let config: [ConfigField]
    let requires: Requires
}

struct ConfigField: Identifiable, Equatable { let key: String; let label: String; let kind: Kind; let `default`: String?
    enum Kind: Equatable { case folder; case select([String]); case string }
}

struct Requires: Equatable { var cli: [String]; var brew: [String]; var tcc: [String] }

enum IntegrationDiscovery {
    nonisolated static func discover(examplesRoot: URL, scriptsRoot: URL) throws -> [ConsumerCard]
}
```

Pure function. No `@MainActor`. Sorts cards alphabetically by `id` (deterministic — keeps the panel order stable across launches).

Tests in `RaptureMacTests/IntegrationDiscoveryTests.swift` use fixture trees under `RaptureMacTests/Fixtures/examples-*/`:
- `examples-empty/` — empty folder, returns `[]`.
- `examples-no-manifest/` — single folder with only a `README.md`, derived defaults populate the card.
- `examples-full-manifest/` — claude-code-style manifest with two installs.
- `examples-malformed-manifest/` — manifest exists but doesn't parse, fall back to filesystem defaults; surface a logged warning.

## Phase 5: StatusParser.swift + tests

`RaptureMac/Integrations/StatusParser.swift`:

```swift
struct StatusReport: Equatable {
    struct Hook: Equatable {
        let scriptInstalled: Bool
        let registered: Bool
    }
    struct Watcher: Equatable {
        enum LaunchdState: Equatable { case notLoaded; case loaded(pid: Int?, lastExit: Int?, idle: Bool) }
        let workerInstalled: Bool
        let plistInstalled: Bool
        let launchdState: LaunchdState
        let fswatchPid: Int?
        let lastLogLine: String?
    }
    struct NotesFolder: Equatable {
        let path: String?
        let source: String?
        let pending: Int?
        let claudeMdPresent: Bool
    }
    let hook: Hook
    let watcher: Watcher
    let notesFolder: NotesFolder
}

extension StatusReport {
    nonisolated static func parse(_ stdout: String) -> StatusReport
}
```

Pure-function parser. Tested against captured `status.sh` outputs in `RaptureMacTests/Fixtures/status/*.txt` for at least these cases:
- `nothing-installed.txt`
- `hook-only.txt`
- `watcher-loaded-running.txt`
- `watcher-loaded-idle.txt`
- `watcher-plist-only.txt` (plist on disk, not loaded)
- `fswatch-dead.txt` (launchd up, fswatch absent)
- `pending-zero.txt`
- `pending-many.txt`
- `claudemd-missing.txt`

## Phase 6: WatcherConfigStore.swift + tests

`RaptureMac/Integrations/WatcherConfigStore.swift`:

```swift
@Observable @MainActor
final class WatcherConfigStore {
    private(set) var values: [String: String] = [:]
    init(fileURL: URL = WatcherConfigStore.defaultFileURL) { /* load if exists */ }
    func set(_ key: String, _ value: String) { /* mutate + atomic write */ }
    func remove(_ key: String) { /* mutate + atomic write */ }
    static var defaultFileURL: URL { /* ~/.config/rapture-mac/watch.env */ }
}
```

- Parses `KEY=VALUE` lines; `#` comments and blank lines skipped.
- On write, preserves keys in deterministic order (alphabetical), one per line, terminating newline.
- Creates `~/.config/rapture-mac/` if missing.
- Round-trip tested: load → set → load again returns the same dict; comments in the source file are dropped on write (documented).

## Phase 7: IntegrationRunner.swift + tests

`RaptureMac/Integrations/IntegrationRunner.swift`:

```swift
struct RunResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

actor IntegrationRunner {
    init(loginPath: String)
    func run(_ scriptURL: URL, env: [String: String] = [:]) async throws -> RunResult
}

enum LoginShellPath {
    static func capture() throws -> String   // runs /bin/zsh -ilc 'echo $PATH', returns trimmed result
}
```

Mirrors `AppleScriptSender`:
- `Process()` with `/bin/bash` as `executableURL`, `[scriptURL.path]` as `arguments`.
- `stdout` and `stderr` pipes; both read to EOF concurrently to avoid deadlock if a script writes >64 KB to either.
- Inherits `loginPath` plus the supplied `env` overlay.
- Surfaces exit code + both streams in `RunResult`. Non-zero exit is not an error — callers (e.g. install buttons) want to display the stderr.
- The single throwing path is failure to spawn (`process.run()`); everything else is captured into `RunResult`.

Tests pipe `Bundle.main.url(forResource: "echo-stdout-then-stderr", withExtension: "sh", subdirectory: "Fixtures")` through and assert capture semantics.

`LoginShellPath.capture()` is called once at app launch (from `RaptureMacApp.init` or `AppState.init`); the resulting string is passed into the `IntegrationRunner` constructor. Cached; not re-captured per script run.

## Phase 8: SettingsIntegrationsView (SwiftUI)

New `RaptureMac/UI/SettingsIntegrationsView.swift`. View hierarchy:

```
SettingsIntegrationsView
  └─ ScrollView
      └─ VStack(spacing: 16)
          └─ ForEach(cards) → ConsumerCardView
              ├─ Card header: displayName, description, prerequisite-strip, docs links, Open in Finder
              └─ ForEach(installs) → InstallSectionView (DisclosureGroup)
                  ├─ Section header: name, status pill
                  ├─ Description
                  ├─ Action row: Install… / Uninstall / Start / Stop / Restart / Open logs (conditionally visible per profile fields)
                  └─ ConfigForm (only if config[] non-empty)
                      └─ ForEach(config) → folder picker | Picker | TextField
```

Status pill colors mirror the existing app vocabulary: `green` (Installed / Running), `gray` (Not installed / Loaded-idle), `red` (Error), `?` (statusKey unknown).

Wire into `RaptureMac/UI/SettingsView.swift`:

```swift
private enum Tab: Hashable { case general, allowlist, integrations, about }
// ...
SettingsIntegrationsView()
    .tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }
    .tag(Tab.integrations)
```

Bump the `SettingsView` `.frame(width: 560, height: 440)` to `height: 520` (or larger if testing shows clipping). Verify the three existing tabs (General, Allowlist, About) render unchanged.

## Phase 9: AppState wiring + live status polling

New `RaptureMac/Integrations/IntegrationsState.swift`:

```swift
@Observable @MainActor
final class IntegrationsState {
    var cards: [ConsumerCard] = []
    var status: StatusReport?
    var pending: [String: ActionState] = [:]    // keyed by InstallProfile.id

    private let runner: IntegrationRunner
    private var pollTask: Task<Void, Never>?

    enum ActionState: Equatable { case idle; case running; case succeeded; case failed(String) }

    init(runner: IntegrationRunner, examplesRoot: URL, scriptsRoot: URL) { /* discover() */ }

    func startPolling() { /* spawn Task; await runner.run(status.sh); update status; sleep 5 s; loop */ }
    func stopPolling()  { /* pollTask?.cancel() */ }

    func run(_ action: ActionKind, for install: InstallProfile, env: [String: String] = [:]) async
}
```

`AppState` gains:

```swift
let integrations: IntegrationsState
init(...) {
    // existing init body
    let loginPath = (try? LoginShellPath.capture()) ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    self.integrations = IntegrationsState(
        runner: IntegrationRunner(loginPath: loginPath),
        examplesRoot: Bundle.main.examplesURL,
        scriptsRoot:  Bundle.main.scriptsURL
    )
}
```

`SettingsIntegrationsView` controls the poll lifecycle:

```swift
.onAppear { appState.integrations.startPolling() }
.onDisappear { appState.integrations.stopPolling() }
```

## Phase 10: Prerequisites + TCC deep-links

`RaptureMac/Integrations/Prerequisites.swift`:

```swift
struct PrerequisiteReport: Equatable {
    let missingCLIs: [String]
    let missingBrew: [String]
    let tccDeepLinks: [TCCEntry]
    var allPresent: Bool { missingCLIs.isEmpty && missingBrew.isEmpty }
}

struct TCCEntry: Identifiable, Equatable { let id: String; let name: String; let url: URL }

enum Prerequisites {
    static let installCommands: [String: String] = [
        "jq": "brew install jq",
        "fswatch": "brew install fswatch",
        "claude": "brew install --cask claude-code",
        // … keep the table small; document additions in this file
    ]
    nonisolated static func detect(_ requires: Requires) -> PrerequisiteReport
    nonisolated static func tccURL(for name: String) -> URL?
}
```

CLI detection: `/usr/bin/which <name>` (via a small synchronous `Process` call); exit-code 0 ⇒ present. Brew packages use the same check (Homebrew installs to PATH; no need to inspect `brew list`).

UI: a missing-prerequisite badge per missing item in the card header. Tap a badge → modal sheet (the existing `PermissionsView` modal pattern) showing the copy-paste command in a monospace text field with a `Copy` button.

TCC deep-link buttons render unconditionally per the manifest's `requires.tcc` list; clicking calls `NSWorkspace.shared.open(url)`.

## Phase 11: CHANGELOG + PR

Add to `CHANGELOG.md` under `[Unreleased]` → `### Added`:

```
- Integrations panel: install, configure, and monitor downstream Rapture consumers from inside Settings — no Terminal required. Surfaces every recipe in `examples/` dynamically; new recipes appear as cards without code changes.
```

Open a PR against `main`. Description includes:
- Screenshots of the panel with at least three consumer cards visible (claude-code expanded, cli/hermes/openclaw collapsed or shown as info-only cards).
- `xcrun stapler validate` output on the built DMG.
- Scripts-bundled checklist: which files in `Scripts/` and `examples/` ship inside the `.app`, and which (e.g. `Scripts/release.sh`, `Scripts/set_git_version.sh`) deliberately don't.
- New TCC prompts the user might see and when (each `Grant permission…` click opens System Settings; no new permission dialogs are triggered by the app itself).
- Links to the four spec docs in this folder.

## Verification (end-to-end)

1. **Existing tests stay green.** `xcodebuild test` runs the 73 existing tests plus the new Integrations tests; all pass.
2. **Build artifact integrity.** After `xcodebuild`, `find <built>.app/Contents/Resources/{Scripts,examples} -type f | wc -l` matches the source tree's file count (modulo `.DS_Store` / `._*`). `codesign --verify --deep --strict --verbose=2 <built>.app` succeeds.
3. **Notarization round-trip.** `Scripts/release.sh` produces a notarized DMG. `xcrun stapler validate Build/RaptureMac.dmg` and `spctl --assess --type install Build/RaptureMac.dmg` both succeed.
4. **Discovery scales.** Drop a dummy `examples/test-consumer/` (one `README.md` with H1 + paragraph). Rebuild. The panel shows a `Test Consumer` informational card with the README paragraph as its description and no install buttons. Remove the folder; rebuild; the card disappears.
5. **Manifest override.** Add `examples/test-consumer/manifest.json` overriding `displayName` to `Override Demo`. Rebuild; the card title becomes `Override Demo`.
6. **Claude Code hook install cycle.** From a clean account, click `Install` on the SessionStart hook section. Card status flips to `Installed`. `cat ~/.claude/settings.json` shows the hook entry. Click `Uninstall`. Card flips back; the check script is gone.
7. **Claude Code watcher install cycle.** Pick a workdir via the folder picker. Set `RAPTURE_MEDIA_MODEL=sonnet`. Click `Install`. `~/.config/rapture-mac/watch.env` contains the chosen values. `defaults read ~/Library/LaunchAgents/com.user.rapture-notes-watch.plist EnvironmentVariables` shows the workdir + models. Watcher card shows `Running` with a PID.
8. **Watcher live status.** Dictate a Siri test note. Within 10 s the watcher card's last-activity line updates with a new timestamp; `Pending` count rises then falls.
9. **Start / Stop / Restart cycle.** `Stop` → `Loaded (stopped)` or `Not loaded`. `Start` → `Running` again. `Restart` → PID changes.
10. **Capture pipeline still works.** Throughout (1)–(9), Siri-dictated notes continue to land as `.txt` files and `✓ Saved` replies continue to arrive in iMessage. The Integrations panel has not broken any capture path.
11. **Prerequisite missing.** Temporarily `mv /opt/homebrew/bin/jq /opt/homebrew/bin/jq.bak`. Reload the panel. The hook section shows a missing-`jq` badge. Tap → sheet shows `brew install jq` as copy-paste. Restore `jq`; badge disappears.
12. **TCC deep-link.** Click `Grant permission… (Reminders)` on the watcher card. System Settings opens to Privacy & Security → Reminders. No new prompts triggered by the app itself.
13. **Vendor neutrality.** Claude Code / CLI / Hermes / OpenClaw cards render with the same visual weight: same card width, same header layout, no badge or visual cue privileging any one consumer.

## Critical files

**New:**
- `RaptureMac/Integrations/IntegrationDiscovery.swift`
- `RaptureMac/Integrations/StatusParser.swift`
- `RaptureMac/Integrations/WatcherConfigStore.swift`
- `RaptureMac/Integrations/IntegrationRunner.swift`
- `RaptureMac/Integrations/Prerequisites.swift`
- `RaptureMac/Integrations/IntegrationsState.swift`
- `RaptureMac/Integrations/BundledResources.swift`
- `RaptureMac/UI/SettingsIntegrationsView.swift` (with `ConsumerCardView`, `InstallSectionView` either inline or in same file)
- `RaptureMacTests/IntegrationDiscoveryTests.swift`
- `RaptureMacTests/StatusParserTests.swift`
- `RaptureMacTests/WatcherConfigStoreTests.swift`
- `RaptureMacTests/IntegrationRunnerTests.swift`
- `RaptureMacTests/Fixtures/examples-*/` (fixture trees)
- `RaptureMacTests/Fixtures/status/*.txt` (captured `status.sh` outputs)
- `examples/manifest-schema.md`
- `examples/{claude-code,cli,hermes,openclaw}/manifest.json`
- `agent-os/specs/2026-05-31-2030-integrations-panel/{plan,shape,references,standards}.md` (already written)

**Modified:**
- `RaptureMac/RaptureMac.xcodeproj/project.pbxproj` — add Resources-copy Run Script phase; register new Swift files in the app target and tests in the test target.
- `RaptureMac/UI/SettingsView.swift` — add `.integrations` tab case; bump frame height.
- `RaptureMac/App/AppState.swift` — own `IntegrationsState`.
- `CHANGELOG.md` — `[Unreleased]` entry.

**Reused (existing patterns mirrored, not modified):**
- `RaptureMac/Reply/AppleScriptSender.swift` — subprocess pattern for `IntegrationRunner`.
- `RaptureMac/UI/PermissionsView.swift` — modal-sheet + `x-apple.systempreferences:` deep-link pattern.
- `RaptureMac/UI/SettingsGeneralView.swift` — folder picker, `Form`/`Section` layout, `binding(for:)` pattern.
- `RaptureMac/Persistence/AtomicFile.swift` (canonical helper location TBC at implementation time) — atomic write for `watch.env`.
- `Scripts/status.sh` — the parser contract.

**Explicitly NOT touched (must keep working):**
- `RaptureMac/Watcher/{ChatDBWatcher, AttributedBodyDecoder, MessageRow}.swift`
- `RaptureMac/Filter/{MessageFilter, SelfHandleResolver, EchoGuard}.swift`
- `RaptureMac/Writer/FileWriter.swift`
- `RaptureMac/Reply/Replier.swift`

## Out of scope for this panel

- **Log viewer in-app.** `Open logs` runs `open -t /tmp/rapture-notes-watch.out.log`; the user's `.txt` association handles display.
- **CLAUDE.md editor.** `Open in Finder` on the card lets the user open `CLAUDE.md` in their editor of choice.
- **Auto-picking a workdir.** The folder picker defaults to `$HOME` per the script's behavior; no auto-suggest of `~/Source/Repos/*` in v1 (defer to a follow-up if it adds friction).
- **Auto-installing `brew` / `jq` / `fswatch` / `claude`.** Surface the install command in the modal; the user runs it.
- **TCC grant-state detection.** Deep-link buttons render unconditionally.
- **Telemetry, analytics, update checks.** PRIVACY.md.
- **Outbound network calls.** Same.
- **Cards for `examples/<name>/` recipes that don't have install scripts (CLI, Hermes, OpenClaw today).** Informational only: `Open README` + `Open in Finder`. Future PRs add scripts to give them live install state.

## v1.1 candidates (not committed)

- Pre-populated workdir suggestions from a recent-projects scan of `~/Source/Repos/*` (or wherever the user's source root lives, configurable).
- Install scripts + manifests for CLI / Hermes / OpenClaw, once those tools' install paths are stable and worth wrapping.
- `tccutil`-based grant-state detection so deep-link buttons can render `Already granted` when appropriate.
- An optional "Pause all consumers" master toggle that stops every loaded launchd job (a thin convenience over per-card Stop).
