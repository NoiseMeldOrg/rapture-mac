#!/usr/bin/env bash
# Restart the Rapture notes watcher.
# Use this after editing the worker script or the launchd plist — the running
# process holds the old copy in memory until it's restarted.
set -euo pipefail

LABEL="com.user.rapture-notes-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -f "$PLIST" ] || { echo "✗ Not installed: $PLIST is missing. Run Scripts/install-claude-watch.sh first." >&2; exit 1; }

# kickstart -k kills the running instance and relaunches in one step (macOS 10.11+).
if launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null; then
  echo "✓ Restarted $LABEL"
else
  # Fallback: full unload/load cycle.
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  echo "✓ Restarted $LABEL (via unload/load)"
fi
echo "  Inspect: bash Scripts/status.sh"
