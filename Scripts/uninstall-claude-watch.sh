#!/usr/bin/env bash
# Removes the Rapture notes event-driven autonomous watcher.
#
# Reverses install-claude-watch.sh: unloads + deletes the launchd plist,
# deletes the worker script, leaves your notes folder and CLAUDE.md
# routing rules untouched.

set -euo pipefail

WATCH_SCRIPT="$HOME/.claude/scripts/rapture-notes-watch.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.rapture-notes-watch.plist"

# 1. Unload and remove the launchd plist
if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm "$PLIST_PATH"
  echo "✓ Removed $PLIST_PATH"
else
  echo "  No launchd plist found — already gone."
fi

# 2. Remove the worker script
if [ -f "$WATCH_SCRIPT" ]; then
  rm "$WATCH_SCRIPT"
  echo "✓ Deleted $WATCH_SCRIPT"
else
  echo "  Worker script not found — already gone."
fi

# 3. Note about logs (don't auto-delete; user may want to read them)
echo
echo "Logs at /tmp/rapture-notes-watch.{out,err}.log are left in place."
echo "Remove manually if you want: rm /tmp/rapture-notes-watch.*.log"
