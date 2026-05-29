#!/usr/bin/env bash
# Start (load) the Rapture notes event-driven watcher.
# Safe to run if already loaded — it just reports and exits.
set -euo pipefail

LABEL="com.user.rapture-notes-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -f "$PLIST" ] || { echo "✗ Not installed: $PLIST is missing. Run Scripts/install-claude-watch.sh first." >&2; exit 1; }

if launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$LABEL"; then
  echo "Already running. Use Scripts/restart-watch.sh to restart, or Scripts/status.sh to inspect."
  exit 0
fi

# Modern API first (macOS 11+), fall back to legacy load.
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
echo "✓ Started $LABEL"
echo "  Inspect: bash Scripts/status.sh"
