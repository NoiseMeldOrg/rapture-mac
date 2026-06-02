# References for Integrations Panel

## Primary in-repo references

### v1 capture spec (voice + structure)

- **Location:** `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/{plan,shape,references,standards}.md`
- **Relevance:** The canonical example of this repo's spec layout — Context → Decisions table → Reference contracts → numbered Phases → Verification → Critical files → Out of scope. The Integrations panel spec mirrors this structure deliberately so contributors can navigate it the same way.
- **What we mirror:** the decisions-table format, the phase-as-implementation-unit framing, the verification-as-a-numbered-list pattern, the explicit "out of scope" closer. Voice: terse, opinionated, technical, no marketing language.

### Settings window (the slot we plug into)

- **Location:** `RaptureMac/RaptureMac/UI/SettingsView.swift`
- **Relevance:** Three-tab `TabView` inside a single `Window` scene with `id: "settings"`, opened from the menu bar via `openWindow(id: "settings")`. Adding the Integrations tab is one new enum case + one new `.tabItem` modifier; the frame size needs a bump for the new content.
- **Key patterns to honor:**
  - `private enum Tab: Hashable { case general, allowlist, about }` — extend with `.integrations`.
  - `.padding(20).frame(width: 560, height: 440)` — keep the width; raise the height for the new tab and verify the existing three render unchanged.
  - Window activation: `NSApp.activate(ignoringOtherApps: true)` is needed because `LSUIElement=true`.

### General tab (folder pickers + form layout)

- **Location:** `RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`
- **Relevance:** The closest UI analog. The watcher card's workdir picker mirrors `pickFolder()` directly. The Picker-with-Settings-binding pattern (`appState.settings.binding(for: \.replyMode)`) is the model for any persistent toggle in an install profile.
- **Key patterns to port:**
  - `NSOpenPanel` with `canChooseDirectories = true`, `canCreateDirectories = true`, `prompt = "Use This Folder"`.
  - `.formStyle(.grouped)` for consistent section appearance.
  - `Binding`-with-error-state pattern (see the `launchAtLoginBinding` shape) when a set may fail.

### Permissions window (TCC deep-link pattern)

- **Location:** `RaptureMac/RaptureMac/UI/PermissionsView.swift`
- **Relevance:** The exact pattern the Integrations panel reuses for `Grant permission…` buttons (modal sheet + `x-apple.systempreferences:` URL + `NSWorkspace.shared.open`).
- **Key patterns to port:**
  - URL constant: `URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!` (swap the trailing `Privacy_*` query for the target TCC pane).
  - Modal copy structure: title → one-paragraph explainer → numbered steps (`Label("…", systemImage: "1.circle")`).
  - State observation via `@Observable` AppState property + `.onChange` for auto-dismiss when grant lands. (For Reminders/Calendar/Contacts we cannot detect grant state without private APIs, so the auto-dismiss path doesn't apply — the sheet is dismissed by the user.)

### AppleScriptSender (subprocess pattern)

- **Location:** `RaptureMac/RaptureMac/Reply/AppleScriptSender.swift`
- **Relevance:** The only other subprocess invocation in the app today. `IntegrationRunner` is a structural twin: `Process()`, pipes, `try process.run()`, `process.waitUntilExit()`, exit-code + stderr captured into a typed `Error`. Same OSLog category (`noisemeld.RaptureMac`).
- **Key patterns to port verbatim:**
  - `process.executableURL = URL(fileURLWithPath: "/bin/bash")`.
  - Pipes for stdin/stdout/stderr; close stdin explicitly after writing.
  - Concurrent reads from stdout + stderr to avoid deadlock if a script writes >64 KB to either before exit.
  - Custom `Error` struct with `exitCode: Int32` and `stderr: String`.
  - `Task.detached(priority: .userInitiated)` if the call site needs async/await.

### AppState + Stores (`@Observable @MainActor` shape)

- **Location:** `RaptureMac/RaptureMac/App/AppState.swift` + `Persistence/SettingsStore.swift` + `Persistence/StateStore.swift`
- **Relevance:** The pattern for any new state container the panel introduces. `IntegrationsState` is a third store-like type with the same lifecycle (constructed in `AppState.init`, held as a `let`, mutated on `@MainActor`).
- **Key patterns to mirror:**
  - `@Observable @MainActor final class …`
  - Atomic JSON persistence via the shared file helper (find the helper at implementation time — likely `Persistence/AtomicFile.swift` or similar). `WatcherConfigStore` reuses the same atomic-write primitive even though the file format is `KEY=VALUE`, not JSON.
  - `binding(for: \.keyPath)` extension for two-way SwiftUI binding.

### `Scripts/status.sh` (parser contract)

- **Location:** `Scripts/status.sh`
- **Relevance:** Single source of truth for live state. Output is structured ASCII; `StatusParser.parse` regexes against it. Any change to the script's output format is a contract change that must update both the script and the parser tests in lockstep.
- **Key things to honor:**
  - Section headers: `SessionStart hook (opportunistic):`, `Event-driven watcher (autonomous):`, `Notes folder:`, `Commands:` — section boundaries drive the parser's scanning state machine.
  - Fact lines: `  ✓ Label: value` or `  ✗ Label: value`. Always two-space indent + glyph + label + `: ` + value.
  - Optional lines (e.g. `fswatch running:`) are *absent* when negative, not present with a `✗`. The parser must treat absence as "not running" rather than "unknown."
  - `Loaded in launchd (PID <N>; last exit code: <N>)` vs `(idle; last exit code: <N>)` — two distinct runtime states the parser distinguishes.

### `examples/watch.env.example` (config file format)

- **Location:** `examples/watch.env.example`
- **Relevance:** Documents the `KEY=VALUE` format that `WatcherConfigStore` reads and writes. Comment-style is `#`-prefixed lines (preserved on read, dropped on write per the spec).
- **Variables documented:** `RAPTURE_MEDIA_MODEL`, `RAPTURE_TEXT_MODEL`, `RAPTURE_CLAUDE_WORKDIR`, `RAPTURE_NOTES_FOLDER`, `RAPTURE_CLAUDE_BIN`.

### `Scripts/install-claude-watch.sh` (config-to-plist injection)

- **Location:** `Scripts/install-claude-watch.sh`
- **Relevance:** The installer reads `~/.config/rapture-mac/watch.env` and injects each key into the launchd plist's `EnvironmentVariables` block via `PlistBuddy`. The panel writes the config file, then re-runs the installer — it does not touch the plist directly.
- **Why this matters for the panel:** all watcher config changes go through this script. The panel does not own the plist schema; the script does. Changes to which env vars flow through to launchd land in the script, not in Swift.

### `examples/<name>/README.md` (description-derivation source)

- **Location:** `examples/{claude-code,cli,hermes,openclaw}/README.md`
- **Relevance:** When a `manifest.json` is absent or its `description` field is empty, `IntegrationDiscovery` derives the card description by parsing the README: skip the H1, then take the first paragraph that follows.
- **Format the parser assumes:**
  - First non-empty heading is the H1 (`# Heading`).
  - First non-empty paragraph after the H1 (separated by blank lines) is the description.
  - HTML, code fences, and Markdown links are kept as-is in the extracted text. SwiftUI's `Text` doesn't render Markdown link syntax, but for the card description the visible literal is acceptable.

## External documentation

### SwiftUI `MenuBarExtra` + `Window` scenes

- **Reference:** Apple docs — `MenuBarExtra(.window)` style and multi-`Window` apps.
- **Relevance:** The Integrations tab lives inside the existing `Window` scene; no new scene needed. Confirms `openWindow(id: "settings")` is the correct activation path.

### `SMAppService.mainApp`

- **Reference:** `SMAppService` framework.
- **Relevance:** Used by `LaunchAtLoginController` in the General tab; *not* used by the Integrations panel itself (the autonomous watcher uses `~/Library/LaunchAgents/com.user.rapture-notes-watch.plist`, a *user* launchd agent, not an `SMAppService` job). Linked here so a future reviewer doesn't conflate the two launchd patterns.

### `x-apple.systempreferences:` URL scheme

- **Reference:** Used throughout this codebase already (FDA deep-link in `PermissionsView`). No public Apple documentation enumerates the valid `Privacy_*` query values; the strings are reverse-engineered from System Settings' URL handlers and verified empirically.
- **Values used by this panel:** `Privacy_AllFiles`, `Privacy_Automation`, `Privacy_Reminders`, `Privacy_Calendar`, `Privacy_Contacts`, `Privacy_Accessibility`. Manifests using a `tcc` value outside this list fall back to opening the Privacy & Security root pane.

### Hardened-runtime Resources

- **Reference:** Apple developer documentation on hardened runtime + Resources.
- **Relevance:** Bundling shell scripts inside `Contents/Resources/` is permitted under hardened runtime as long as the app does not attempt to `dlopen` or otherwise treat them as executable Mach-O code. Invoking them via `/bin/bash <path>` is a normal subprocess spawn — equivalent to how `AppleScriptSender` already invokes `/usr/bin/osascript`. No new entitlement required.

### `rsync` in Xcode Run Script phases

- **Reference:** Xcode build-phase documentation.
- **Relevance:** `rsync -a --delete` is the conventional way to mirror a source directory into a build product without leaving stale files. The `--exclude='._*'` and `--exclude='.DS_Store'` filters keep macOS metadata cruft out of the signed bundle (important: stray `._*` files can break code-signing of nested resource directories on some macOS versions).

## Patterns deliberately *not* reused

### `URLSession` / `URLRequest` / `NWConnection`

- **Reason:** PRIVACY.md commits to zero outbound network calls, verified by `grep`. The Integrations panel honors that. Install scripts ship as bundled Resources; no runtime fetch from `raw.githubusercontent.com`.

### `WatchPaths` launchd plist

- **Reference (negative):** The earlier launchd plist that shipped before `install-claude-watch.sh` adopted the long-running fswatch model (`autonomous.md:117–119`).
- **Reason:** Already superseded in the script. The panel reads `status.sh` (which knows about the current architecture), not the script internals. Future watcher rewrites stay invisible to the panel.

### `tccutil` shell-out for grant detection

- **Reason:** `tccutil` requires `sudo` for `reset` and doesn't expose a query API. Querying TCC state from a non-privileged process requires private APIs the hardened runtime would also flag. Out of scope for v1; deep-link buttons render unconditionally.
