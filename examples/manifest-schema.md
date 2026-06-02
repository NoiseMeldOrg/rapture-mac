# `examples/<name>/manifest.json` schema

The Integrations panel in Rapture for Mac discovers downstream consumers by walking the bundled `examples/` folder at runtime. Each subfolder = one card. If the folder contains a `manifest.json`, it overrides the panel's defaults; otherwise everything is derived from the filesystem.

This document is the schema reference. The panel's discovery code (`RaptureMac/RaptureMac/Integrations/IntegrationDiscovery.swift`) is the authoritative parser; this doc tracks it.

## File format

UTF-8 JSON, top-level object. All fields are optional. Trailing commas are not allowed (standard JSON).

## Top-level fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `displayName` | string | prettified folder name (`claude-code` → `Claude Code`) | Shown in the card header. |
| `description` | string | first paragraph after the `README.md` H1 | Shown under the display name. One paragraph. No Markdown rendering in v1. |
| `docs` | array of `DocLink` | `[{label: "README", file: "README.md"}]` if `README.md` exists, else `[]` | Each entry renders as a link button in the card header. |
| `installs` | array of `Install` | `[]` | Each entry renders as a stacked disclosure section inside the card. Empty array = informational card with no install buttons. |

### `DocLink`

| Field | Type | Required | Notes |
|---|---|---|---|
| `label` | string | yes | Button text. |
| `file` | string | yes | Path relative to the example folder. Opened via the user's default `.md` association. |

### `Install`

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | Stable identifier. Used as a SwiftUI `Identifiable` key and to address pending-action state. Convention: kebab-case (`claude-hook`, `claude-watch`). |
| `name` | string | yes | Section title inside the card. |
| `description` | string | no | Section body text. One paragraph. |
| `install` | string | yes for installable | Path (relative to `Scripts/` or to the example folder) to the install script. Invoked as `/bin/bash <path>`. |
| `uninstall` | string | recommended | Path to the uninstall script. Without it, the panel can install but not cleanly remove. |
| `start` | string | no | Path to a start script (loads a launchd job, etc.). Renders a `Start` button when present. |
| `stop` | string | no | Path to a stop script. Renders a `Stop` button. |
| `restart` | string | no | Path to a restart script. Renders a `Restart` button. |
| `logs` | array of string | no | Absolute paths to log files. Each renders an `Open logs` button that runs `open -t <path>`. |
| `statusKey` | string | no | Key the panel uses to look up this install's live state in the parsed `status.sh` output. v1 values: `"hook"`, `"watcher"`. Unknown keys render a `?` pill. Absent = no live status; the card shows install/uninstall state only. |
| `configFile` | string | no | Path to a `KEY=VALUE` config file the panel reads/writes when the user edits `config` fields. Typically `~/.config/rapture-mac/watch.env`. Tilde is expanded. |
| `config` | array of `ConfigField` | no | Form fields rendered inside the install section. Required if `configFile` is set. |
| `requires` | `Requires` | no | Declared prerequisites. The panel detects missing items and surfaces install commands or TCC deep-links. |

### `ConfigField`

| Field | Type | Required | Notes |
|---|---|---|---|
| `key` | string | yes | The `KEY=VALUE` key written to `configFile`. |
| `label` | string | yes | Form-field label. |
| `type` | `"folder"` \| `"select"` \| `"string"` | yes | UI control: folder picker / picker / text field. |
| `options` | array of string | yes for `type: "select"` | The picker's options. |
| `default` | string | no | Default value if the config file doesn't have a value for this key. Literal `$HOME` is expanded to the user's home directory. |

### `Requires`

| Field | Type | Notes |
|---|---|---|
| `cli` | array of string | Each CLI name is checked via `/usr/bin/which <name>`. Missing → "Install `name`" badge with copy-paste command. |
| `brew` | array of string | Same detection as `cli` (Homebrew installs to PATH). Reserved for clarity when the install command is brew-specific. |
| `tcc` | array of string | Each entry renders a `Grant permission… (<name>)` button that opens System Settings to the right Privacy & Security pane. Recognized values: `"Reminders"`, `"Calendar"`, `"Contacts"`, `"Accessibility"`, `"FullDiskAccess"`, `"Automation"`. Unknown values open the Privacy & Security root. |

## Path resolution

Script and doc paths are interpreted in this order:
1. **Absolute** — used as-is.
2. **Relative starting with `Scripts/`** — resolved against the bundled `Scripts/` root (`Bundle.main.scriptsURL`).
3. **Other relative** — resolved against the example folder (`Bundle.main.examplesURL/<name>/`).

This lets a manifest reference shared scripts (`Scripts/install-claude-watch.sh`) or example-local files (`SKILL.md`) consistently.

## Defaults derived from the filesystem

When `manifest.json` is absent or any field is missing, the panel falls back to:

- `displayName`: the folder name with `-` replaced by space and each word capitalized (`generic-cli` → `Generic Cli`; tune via manifest if needed).
- `description`: parse the example folder's `README.md`. Skip everything up to and including the first `# Heading` line. Take the first non-blank paragraph after that (blank-line-separated). If `README.md` is missing or empty, use `""`.
- `docs`: `[{label: "README", file: "README.md"}]` if `README.md` exists, else `[]`. The manifest can replace or augment this list.

## Example: Claude Code (two install profiles)

```json
{
  "displayName": "Claude Code",
  "description": "Watch the notes folder and triage each note inside a Claude Code session — either opportunistically when you next open Claude, or autonomously the moment a note lands.",
  "docs": [
    { "label": "Overview", "file": "README.md" },
    { "label": "Autonomous mode", "file": "autonomous.md" }
  ],
  "installs": [
    {
      "id": "claude-hook",
      "name": "SessionStart hook",
      "description": "Opportunistic. Fires when you next open Claude Code. No daemon, no per-message cost.",
      "install": "Scripts/install-claude-hook.sh",
      "uninstall": "Scripts/uninstall-claude-hook.sh",
      "statusKey": "hook",
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
        { "key": "RAPTURE_MEDIA_MODEL",    "label": "Media model",   "type": "select",
          "options": ["haiku", "sonnet", "opus"], "default": "sonnet" },
        { "key": "RAPTURE_TEXT_MODEL",     "label": "Text model",    "type": "select",
          "options": ["haiku", "sonnet", "opus"], "default": "haiku" }
      ],
      "requires": {
        "cli": ["claude", "jq", "fswatch"],
        "tcc": ["Reminders"]
      }
    }
  ]
}
```

## Example: informational card (no install scripts yet)

```json
{
  "displayName": "Generic CLI",
  "description": "A pure shell script that processes each new .txt file through whatever LLM CLI you set. Works with anything that reads stdin and writes to stdout.",
  "docs": [
    { "label": "README", "file": "README.md" },
    { "label": "Script", "file": "process-notes.sh" }
  ],
  "installs": []
}
```

The card renders `Open README`, `Open in Finder`, and the script link — no install/uninstall buttons. The user follows the README to install manually. A future PR that adds `Scripts/install-cli-*.sh` can give this card live install state by adding an `installs[]` entry.

## Versioning

The schema is versioned implicitly by the app version. A field unknown to an older app is ignored (forward-compatible). A field this doc no longer mentions has been removed in a subsequent app version; older manifests may still set it without breaking anything.

When the schema changes in a way that's not forward-compatible (rare, would require a `"schemaVersion": 2` top-level field), this doc gets an explicit migration section. Until that happens, all manifests are schema version 1 by default.
