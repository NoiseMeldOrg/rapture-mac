#!/usr/bin/env bash
# Stop (unload) the Rapture notes watcher.
# Leaves the plist + worker script on disk, so Scripts/start-watch.sh can bring
# it straight back. To remove it entirely, use Scripts/uninstall-claude-watch.sh.
set -euo pipefail

LABEL="com.user.rapture-notes-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if ! launchctl list 2>/dev/null | awk '{print $3}' | grep -qx "$LABEL"; then
  echo "Not running — nothing to stop."
  exit 0
fi

# Modern API first, fall back to legacy unload.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
echo "✓ Stopped $LABEL (plist kept; Scripts/start-watch.sh re-enables it)"
