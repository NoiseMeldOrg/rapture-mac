#!/usr/bin/env bash
# Installs the Rapture notes SessionStart hook for Claude Code.
#
# What this does:
#   1. Writes a small check script to ~/.claude/scripts/rapture-notes-check.sh.
#      The script reports the count of unprocessed .txt files at session start
#      so Claude can offer to triage them per ~/Documents/Rapture Notes/CLAUDE.md.
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

command -v jq >/dev/null || {
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
}

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

COUNT=\$(ls "\$NOTES"/*.txt 2>/dev/null | wc -l | tr -d ' ')
if [ "\$COUNT" -gt 0 ]; then
  echo "Rapture notes pending: \$COUNT unprocessed .txt files in \$NOTES. If the user's current task allows, offer to triage them per the rules at \$NOTES/CLAUDE.md."
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
echo
echo "Start a new Claude Code session to verify — if you have unprocessed .txt"
echo "files in your notes folder, the count will surface as session context."
echo
echo "Uninstall: bash scripts/uninstall-claude-hook.sh"
