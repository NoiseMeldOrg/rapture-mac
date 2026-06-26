#!/usr/bin/env bash
# Removes the Rapture notes SessionStart hook from Claude Code.
#
# Reverses install-claude-hook.sh: removes the hook entry from
# ~/.claude/settings.json and deletes the check script.
#
# Requirements: jq (brew install jq).

set -euo pipefail

SCRIPT_PATH="$HOME/.claude/scripts/rapture-notes-check.sh"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null || {
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
}

# 1. Strip the hook entry from settings.json (if present)
if [ -f "$SETTINGS" ] && jq empty "$SETTINGS" 2>/dev/null; then
  TMP=$(mktemp)
  jq --arg cmd "$SCRIPT_PATH" '
    if .hooks.SessionStart? then
      .hooks.SessionStart |= map(
        . as $entry
        | $entry
        | .hooks //= []
        | .hooks |= map(select(.command != $cmd))
        | if .hooks == [] then empty else . end
      )
      | if .hooks.SessionStart == [] then del(.hooks.SessionStart) else . end
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$TMP"

  jq empty "$TMP" 2>/dev/null || {
    echo "Error: cleanup produced invalid JSON. Settings unchanged." >&2
    rm "$TMP"
    exit 1
  }
  mv "$TMP" "$SETTINGS"
  echo "✓ Removed SessionStart hook entry from $SETTINGS"
else
  echo "  No valid settings.json found — skipping hook entry removal."
fi

# 2. Remove the check script
if [ -f "$SCRIPT_PATH" ]; then
  rm "$SCRIPT_PATH"
  echo "✓ Deleted $SCRIPT_PATH"
else
  echo "  Check script not found — already gone."
fi

echo
echo "Done. The notes folder and its CLAUDE.md routing rules are untouched."
