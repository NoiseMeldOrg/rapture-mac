#!/usr/bin/env bash
# Installs the Rapture notes event-driven autonomous watcher for Claude Code.
#
# What this does:
#   1. Writes ~/.claude/scripts/rapture-notes-watch.sh — a small fswatch loop
#      that fires `claude -p --model haiku` against your project directory
#      every time a new .txt file lands in the Rapture notes folder.
#   2. Installs a launchd plist at
#      ~/Library/LaunchAgents/com.user.rapture-notes-watch.plist that keeps
#      the fswatch loop alive across reboots, sleep/wake, and crashes.
#
# Idempotent — re-running won't duplicate anything.
#
# Requirements:
#   - jq         (brew install jq)
#   - fswatch    (brew install fswatch)
#   - claude     (brew install claude-code or npm install -g @anthropic-ai/claude-code)
#
# Environment overrides (rare — defaults work for most users):
#   RAPTURE_CLAUDE_WORKDIR   project dir Claude acts on (default: $HOME)
#   RAPTURE_CLAUDE_BIN       claude binary path (default: /opt/homebrew/bin/claude)
#   RAPTURE_NOTES_FOLDER     fallback notes folder when Rapture's sidecar isn't
#                            present yet (default: ~/Documents/Rapture Notes)

set -euo pipefail

SCRIPT_DIR="$HOME/.claude/scripts"
WATCH_SCRIPT="$SCRIPT_DIR/rapture-notes-watch.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.rapture-notes-watch.plist"
LOG_OUT="/tmp/rapture-notes-watch.out.log"
LOG_ERR="/tmp/rapture-notes-watch.err.log"

WORKDIR="${RAPTURE_CLAUDE_WORKDIR:-$HOME}"
CLAUDE_BIN="${RAPTURE_CLAUDE_BIN:-/opt/homebrew/bin/claude}"
DEFAULT_NOTES="${RAPTURE_NOTES_FOLDER:-$HOME/Documents/Rapture Notes}"

# --- prerequisite checks ---
command -v jq >/dev/null || { echo "Error: jq required — brew install jq" >&2; exit 1; }
command -v fswatch >/dev/null || { echo "Error: fswatch required — brew install fswatch" >&2; exit 1; }
[ -x "$CLAUDE_BIN" ] || { echo "Error: claude binary not executable at $CLAUDE_BIN. Override with RAPTURE_CLAUDE_BIN=/path/to/claude bash install-claude-watch.sh" >&2; exit 1; }

# --- 1. write the worker script ---
mkdir -p "$SCRIPT_DIR"
cat > "$WATCH_SCRIPT" <<EOF
#!/usr/bin/env bash
# Rapture for Mac — event-driven Claude Code watcher.
# Auto-installed; safe to edit. Reinstaller will overwrite this file.

set -uo pipefail

# Resolve notes folder via sidecar → env var → default.
SIDECAR="\$HOME/Library/Application Support/Rapture for Mac/output-folder.path"
if [ -r "\$SIDECAR" ]; then
  NOTES=\$(cat "\$SIDECAR")
else
  NOTES="\${RAPTURE_NOTES_FOLDER:-$DEFAULT_NOTES}"
fi

WORKDIR="\${RAPTURE_CLAUDE_WORKDIR:-$WORKDIR}"
CLAUDE_BIN="\${RAPTURE_CLAUDE_BIN:-$CLAUDE_BIN}"

[ -d "\$NOTES" ] || { echo "Notes folder not found: \$NOTES" >&2; exit 1; }

echo "[\$(date -Iseconds)] rapture-notes-watch: watching \$NOTES → \$CLAUDE_BIN in \$WORKDIR"

# fswatch coalesces events with a 1s latency by default — typically one fire per
# new note landing. We don't filter by event type because macOS FSEvents semantics
# vary; instead we check at fire-time whether any .txt files are pending at the
# folder root and let one claude -p invocation batch-process them per the rules
# in CLAUDE.md. The routing rules move processed files into processed/, so the
# next fswatch event finds the folder empty and skips claude entirely.
fswatch -0 "\$NOTES" | while IFS= read -r -d "" _event; do
  shopt -s nullglob
  files=("\$NOTES"/*.txt)
  [ \${#files[@]} -eq 0 ] && continue
  # Skip pure in-flight .tmp writes (file count = 0 after extension filter).
  pending=()
  for f in "\${files[@]}"; do
    [[ "\$f" == *.tmp ]] && continue
    pending+=("\$f")
  done
  [ \${#pending[@]} -eq 0 ] && continue

  echo "[\$(date -Iseconds)] processing \${#pending[@]} pending note(s)"
  "\$CLAUDE_BIN" -p --model haiku --workdir "\$WORKDIR" \\
    "Process new notes in \$NOTES per the rules in \$NOTES/CLAUDE.md." \\
    || echo "[\$(date -Iseconds)] claude -p failed (exit \$?)"
done
EOF
chmod +x "$WATCH_SCRIPT"

# --- 2. write the launchd plist ---
mkdir -p "$(dirname "$PLIST_PATH")"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.rapture-notes-watch</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>$WATCH_SCRIPT</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>ThrottleInterval</key>
  <integer>10</integer>

  <key>StandardOutPath</key>
  <string>$LOG_OUT</string>

  <key>StandardErrorPath</key>
  <string>$LOG_ERR</string>
</dict>
</plist>
EOF

# Validate before loading
plutil -lint "$PLIST_PATH" >/dev/null || { echo "Error: generated plist is invalid" >&2; exit 1; }

# --- 3. load (or reload) the launchd job ---
# unload if already running (so we pick up any edits)
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo "✓ Installed Rapture notes event-driven watcher"
echo "  Worker:  $WATCH_SCRIPT"
echo "  Plist:   $PLIST_PATH"
echo "  Logs:    tail -f $LOG_OUT $LOG_ERR"
echo "  Workdir: $WORKDIR  (Claude runs from here when processing notes)"
echo "  Claude:  $CLAUDE_BIN (--model haiku)"
echo
echo "Dictate a Siri note to verify. You should see activity in the logs"
echo "within a second or two of the file landing."
echo
echo "Uninstall: bash Scripts/uninstall-claude-watch.sh"
