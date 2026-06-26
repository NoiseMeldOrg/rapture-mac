#!/usr/bin/env bash
# Single-command overview of Rapture for Mac's Claude Code integration.
# Reports what's installed where.

set -uo pipefail

HOOK_SCRIPT="$HOME/.claude/scripts/rapture-notes-check.sh"
SETTINGS="$HOME/.claude/settings.json"
SIDECAR="$HOME/Library/Application Support/Rapture for Mac/output-folder.path"

mark() { [ "$1" = "ok" ] && printf "  \033[32m✓\033[0m " || printf "  \033[31m✗\033[0m "; }

echo "Rapture for Mac — Claude Code integration status"
echo "================================================="

# --- SessionStart hook ---
echo
echo "SessionStart hook (opportunistic triage):"

if [ -f "$HOOK_SCRIPT" ]; then
  mark ok; echo "Check script: $HOOK_SCRIPT"
else
  mark no; echo "Check script not installed"
fi

if command -v jq >/dev/null && [ -f "$SETTINGS" ] && jq empty "$SETTINGS" 2>/dev/null; then
  HOOK_COUNT=$(jq '[.hooks.SessionStart[]?.hooks[]? | select(.command? | type == "string" and contains("rapture-notes-check.sh"))] | length' "$SETTINGS" 2>/dev/null || echo 0)
  if [ "$HOOK_COUNT" -gt 0 ]; then
    mark ok; echo "Registered in $SETTINGS"
  else
    mark no; echo "Not registered in $SETTINGS"
  fi
else
  mark no; echo "Not registered (settings.json missing or invalid)"
fi

# --- Notes folder ---
echo
echo "Notes folder:"

if [ -r "$SIDECAR" ]; then
  NOTES=$(cat "$SIDECAR")
  RESOLUTION="from Rapture's sidecar"
else
  NOTES="${RAPTURE_NOTES_FOLDER:-$HOME/Documents/Rapture Notes}"
  RESOLUTION="default (sidecar not present)"
fi
echo "  Path:        $NOTES"
echo "  Source:      $RESOLUTION"

if [ -d "$NOTES" ]; then
  PENDING=$(ls "$NOTES"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  echo "  Pending:     $PENDING .txt file(s) in root"
  if [ -f "$NOTES/CLAUDE.md" ]; then
    mark ok; echo "CLAUDE.md routing rules present"
  else
    mark no; echo "CLAUDE.md routing rules missing — install script will fetch on next run"
  fi
else
  mark no; echo "Folder does not exist — launch Rapture once to auto-create"
fi

# --- Commands ---
echo
echo "Commands:"
echo "  Install hook:        curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/install-claude-hook.sh | bash"
echo "  Uninstall hook:      curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/uninstall-claude-hook.sh | bash"
echo "  Edit routing rules:  ${EDITOR:-vi} \"$NOTES/CLAUDE.md\""
