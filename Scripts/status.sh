#!/usr/bin/env bash
# Single-command overview of Rapture for Mac's Claude Code integrations.
# Reports what's installed where, what's running, and where to find logs.

set -uo pipefail

HOOK_SCRIPT="$HOME/.claude/scripts/rapture-notes-check.sh"
WATCH_SCRIPT="$HOME/.claude/scripts/rapture-notes-watch.sh"
WATCH_PLIST="$HOME/Library/LaunchAgents/com.user.rapture-notes-watch.plist"
SETTINGS="$HOME/.claude/settings.json"
WATCH_LOG_OUT="/tmp/rapture-notes-watch.out.log"
WATCH_LOG_ERR="/tmp/rapture-notes-watch.err.log"
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

# --- Autonomous watcher ---
echo
echo "Event-driven watcher (autonomous):"

if [ -f "$WATCH_SCRIPT" ]; then
  mark ok; echo "Worker script: $WATCH_SCRIPT"
else
  mark no; echo "Worker script not installed"
fi

if [ -f "$WATCH_PLIST" ]; then
  mark ok; echo "Plist: $WATCH_PLIST"
else
  mark no; echo "Plist not installed"
fi

LAUNCHD_LINE=$(launchctl list 2>/dev/null | awk '$3 == "com.user.rapture-notes-watch"' || true)
if [ -n "$LAUNCHD_LINE" ]; then
  PID=$(echo "$LAUNCHD_LINE" | awk '{print $1}')
  LASTRC=$(echo "$LAUNCHD_LINE" | awk '{print $2}')
  if [ "$PID" = "-" ]; then
    mark ok; echo "Loaded in launchd (idle; last exit code: $LASTRC)"
  else
    mark ok; echo "Loaded in launchd (PID $PID; last exit code: $LASTRC)"
  fi
else
  mark no; echo "Not loaded in launchd"
fi

FSWATCH_PID=$(pgrep -f "fswatch -0.*Rapture Notes" 2>/dev/null | head -1)
if [ -n "$FSWATCH_PID" ]; then
  mark ok; echo "fswatch running: PID $FSWATCH_PID"
else
  mark no; echo "fswatch not running"
fi

if [ -f "$WATCH_LOG_OUT" ]; then
  LAST_OUT=$(tail -1 "$WATCH_LOG_OUT" 2>/dev/null)
  [ -n "$LAST_OUT" ] && echo "  Last log line: $LAST_OUT"
fi

if [ -s "$WATCH_LOG_ERR" ]; then
  LAST_ERR=$(tail -1 "$WATCH_LOG_ERR" 2>/dev/null)
  [ -n "$LAST_ERR" ] && echo "  Last err line: $LAST_ERR"
fi

# --- Notes folder ---
echo
echo "Notes folder:"

if [ -r "$SIDECAR" ]; then
  NOTES=$(cat "$SIDECAR")
  RESOLUTION="from Rapture's sidecar"
else
  NOTES="${RAPTURE_NOTES_FOLDER:-$HOME/Documents/Rapture Notes}"
  RESOLUTION="default (sidecar not present — Rapture v1.0.30 will write it)"
fi
echo "  Path:        $NOTES"
echo "  Source:      $RESOLUTION"

if [ -d "$NOTES" ]; then
  PENDING=$(ls "$NOTES"/*.txt 2>/dev/null | wc -l | tr -d ' ')
  echo "  Pending:     $PENDING .txt file(s) in root"
  if [ -f "$NOTES/CLAUDE.md" ]; then
    mark ok; echo "CLAUDE.md routing rules present"
  else
    mark no; echo "CLAUDE.md routing rules missing — install scripts will fetch on next run"
  fi
else
  mark no; echo "Folder does not exist — launch Rapture once to auto-create"
fi

# --- Commands ---
echo
echo "Commands:"
echo "  Install hook:        curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/install-claude-hook.sh | bash"
echo "  Install watcher:     curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/install-claude-watch.sh | bash"
echo "  Start watcher:       bash Scripts/start-watch.sh"
echo "  Stop watcher:        bash Scripts/stop-watch.sh"
echo "  Restart watcher:     bash Scripts/restart-watch.sh"
echo "  Uninstall hook:      curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/uninstall-claude-hook.sh | bash"
echo "  Uninstall watcher:   curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/uninstall-claude-watch.sh | bash"
echo "  Tail watcher log:    tail -f $WATCH_LOG_OUT $WATCH_LOG_ERR"
echo "  Edit routing rules:  ${EDITOR:-vi} \"$NOTES/CLAUDE.md\""
