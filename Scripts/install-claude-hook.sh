#!/usr/bin/env bash
# Installs the Rapture notes SessionStart hook for Claude Code.
#
# What this does:
#   1. Writes a small check script to ~/.claude/scripts/rapture-notes-check.sh.
#      The script reports recent triaged Markdown notes at session start so
#      Claude can offer to act on them per the folder's CLAUDE.md rules.
#   2. Adds a SessionStart hook entry to ~/.claude/settings.json (idempotent —
#      re-running won't duplicate the entry).
#
# Requirements: jq (brew install jq).
#
# Override the notes folder (rare — the script reads Rapture's sidecar at
# runtime when present, so this only matters until that ships or as a
# fallback): RAPTURE_NOTES_FOLDER=/path bash install-claude-hook.sh

set -euo pipefail

SCRIPT_DIR="$HOME/.claude/scripts"
SCRIPT_PATH="$SCRIPT_DIR/rapture-notes-check.sh"
SETTINGS="$HOME/.claude/settings.json"
DEFAULT_NOTES="${RAPTURE_NOTES_FOLDER:-$HOME/Documents/Rapture Notes}"

if ! command -v jq >/dev/null; then
  if command -v brew >/dev/null; then
    echo "→ jq is required and not installed. Running: brew install jq"
    brew install jq || { echo "Error: brew install jq failed. Install manually and re-run." >&2; exit 1; }
  else
    echo "Error: jq is required and Homebrew is not installed." >&2
    echo "Install jq manually (https://jqlang.github.io/jq/) or install Homebrew first." >&2
    exit 1
  fi
fi

# 0. Ensure CLAUDE.md routing rules exist in the notes folder.
# The hook reports pending notes and points Claude at $NOTES/CLAUDE.md for
# routing. If that file is missing, Claude has nothing to follow. We download
# it from the repo on first install; we never overwrite an existing one (users
# may have customized it).
NOTES_RULES="$DEFAULT_NOTES/CLAUDE.md"
RULES_INSTALLED=false
if [ -d "$DEFAULT_NOTES" ] && [ ! -f "$NOTES_RULES" ]; then
  echo "→ Installing starter CLAUDE.md routing rules to $NOTES_RULES"
  if curl -fsSL "https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/examples/claude-code/CLAUDE.md" -o "$NOTES_RULES"; then
    RULES_INSTALLED=true
  else
    echo "  Warning: failed to download CLAUDE.md. The hook will report pending" >&2
    echo "  notes but Claude will have no routing rules. Create $NOTES_RULES" >&2
    echo "  manually or re-run the installer when you have network." >&2
  fi
elif [ ! -d "$DEFAULT_NOTES" ]; then
  echo "Note: notes folder $DEFAULT_NOTES does not exist yet. Launch Rapture"
  echo "once to auto-create it, then the hook will start reporting pending notes."
fi

# 1. Write the check script
mkdir -p "$SCRIPT_DIR"
cat > "$SCRIPT_PATH" <<EOF
#!/usr/bin/env bash
# Rapture for Mac — Claude Code SessionStart check.
# Auto-installed; safe to edit. Reinstaller will overwrite this file.

# Resolution order for the notes folder:
#   1. Rapture's sidecar file (written by the menu-bar app when the user
#      picks or changes the output folder in Settings → General).
#   2. RAPTURE_NOTES_FOLDER environment variable.
#   3. The default ~/Documents/Rapture Notes/.
SIDECAR="\$HOME/Library/Application Support/Rapture for Mac/output-folder.path"
if [ -r "\$SIDECAR" ]; then
  NOTES=\$(cat "\$SIDECAR")
else
  NOTES="\${RAPTURE_NOTES_FOLDER:-$DEFAULT_NOTES}"
fi

# The app files captures as Markdown notes in these subfolders; report the
# recent ones. In raw mode, .txt files at the root are the pending work instead.
COUNT=\$(find "\$NOTES/Notes" "\$NOTES/Links" "\$NOTES/Tasks" "\$NOTES/Ideas" "\$NOTES/Journal" -maxdepth 1 -name '*.md' -mtime -1 2>/dev/null | wc -l | tr -d ' ')
RAW_COUNT=\$(ls "\$NOTES"/*.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "\$COUNT" -gt 0 ]; then
  echo "Rapture notes: \$COUNT new Markdown note(s) in the last day under \$NOTES. If the user's current task allows, offer to act on them per the rules at \$NOTES/CLAUDE.md."
elif [ "\$RAW_COUNT" -gt 0 ]; then
  echo "Rapture notes pending: \$RAW_COUNT unprocessed .txt files in \$NOTES (raw mode). If the user's current task allows, offer to triage them per the rules at \$NOTES/CLAUDE.md."
fi
EOF
chmod +x "$SCRIPT_PATH"

# 2. Ensure settings.json exists and is valid JSON before touching it
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi
jq empty "$SETTINGS" 2>/dev/null || {
  echo "Error: $SETTINGS is not valid JSON. Aborting." >&2
  exit 1
}

# 3. Merge the SessionStart hook (idempotent — checks for existing entry first)
TMP=$(mktemp)
jq --arg cmd "$SCRIPT_PATH" '
  .hooks //= {} |
  .hooks.SessionStart //= [] |
  if any(.hooks.SessionStart[]?; .matcher == "startup" and ((.hooks // []) | any(.command == $cmd)))
  then .
  else .hooks.SessionStart += [{
    "matcher": "startup",
    "hooks": [{"type": "command", "command": $cmd}]
  }]
  end
' "$SETTINGS" > "$TMP"

# Validate before overwriting
jq empty "$TMP" 2>/dev/null || {
  echo "Error: merge produced invalid JSON. Settings unchanged." >&2
  rm "$TMP"
  exit 1
}
mv "$TMP" "$SETTINGS"

echo "✓ Installed Rapture notes SessionStart hook"
echo "  Check script: $SCRIPT_PATH"
echo "  Hook entry:   $SETTINGS"
if [ "$RULES_INSTALLED" = true ]; then
  echo "  Routing:      $NOTES_RULES (starter — customize to your workflow)"
  echo
  echo "→ Customize the routing rules:"
  echo "    \$EDITOR \"$NOTES_RULES\""
elif [ -f "$NOTES_RULES" ]; then
  echo "  Routing:      $NOTES_RULES (already present, not modified)"
fi
echo
echo "→ Verify by starting a new Claude Code session. If pending notes exist,"
echo "  the count will appear in session context. If not, dictate a Siri note"
echo "  and open Claude after."
echo
echo "Status:    bash Scripts/status.sh"
echo "Uninstall: bash Scripts/uninstall-claude-hook.sh"
