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
MISSING=()
command -v jq >/dev/null || MISSING+=(jq)
command -v fswatch >/dev/null || MISSING+=(fswatch)
if [ ${#MISSING[@]} -gt 0 ]; then
  if command -v brew >/dev/null; then
    echo "→ Required tools not installed: ${MISSING[*]}. Running: brew install ${MISSING[*]}"
    brew install "${MISSING[@]}" || { echo "Error: brew install failed. Install manually and re-run." >&2; exit 1; }
  else
    echo "Error: missing required tools: ${MISSING[*]}. Homebrew is not installed." >&2
    echo "Install Homebrew (https://brew.sh) then re-run, or install the tools manually." >&2
    exit 1
  fi
fi
[ -x "$CLAUDE_BIN" ] || { echo "Error: claude binary not executable at $CLAUDE_BIN. Override with RAPTURE_CLAUDE_BIN=/path/to/claude bash install-claude-watch.sh" >&2; exit 1; }

# --- 0. ensure CLAUDE.md routing rules exist in the notes folder ---
# The worker hands claude the prompt "Process new notes ... per CLAUDE.md".
# If that file doesn't exist, claude has no rules to follow. We download it
# from the repo on first install; we never overwrite an existing one (users
# may have customized it).
NOTES_DIR="${RAPTURE_NOTES_FOLDER:-$HOME/Documents/Rapture Notes}"
NOTES_RULES="$NOTES_DIR/CLAUDE.md"
RULES_INSTALLED=false
if [ -d "$NOTES_DIR" ] && [ ! -f "$NOTES_RULES" ]; then
  echo "→ Installing starter CLAUDE.md routing rules to $NOTES_RULES"
  if curl -fsSL "https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/examples/claude-code/CLAUDE.md" -o "$NOTES_RULES"; then
    RULES_INSTALLED=true
  else
    echo "  Warning: failed to download CLAUDE.md. The watcher will run but claude" >&2
    echo "  will have no routing rules. Manually create $NOTES_RULES or re-run" >&2
    echo "  the installer when you have network." >&2
  fi
elif [ ! -d "$NOTES_DIR" ]; then
  echo "Warning: notes folder $NOTES_DIR does not exist yet. The watcher" >&2
  echo "will fail at startup. Launch Rapture once to auto-create the default" >&2
  echo "folder, then re-run this installer." >&2
fi

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

# Clean up the fswatch child process on exit. Process substitution children
# don't always get reaped automatically when bash exits via SIGTERM (which is
# how 'launchctl unload' and KeepAlive restart land), so leftover fswatch
# processes can linger. This trap kills them deterministically.
trap 'pkill -P \$\$ 2>/dev/null; true' EXIT

# Watch the App Support folder too, so we can self-restart when the user picks a
# new output folder in Rapture's Settings → General (Rapture writes the new path
# to the sidecar file on every folder change). Other writes in App Support
# (state.json watermark advances, settings.json edits) are filtered out below
# via the mtime check on the sidecar specifically.
APP_SUPPORT="\$HOME/Library/Application Support/Rapture for Mac"
LAST_SIDECAR_MTIME=\$(stat -f %m "\$SIDECAR" 2>/dev/null || echo "0")

echo "[\$(date -Iseconds)] rapture-notes-watch: watching \$NOTES → \$CLAUDE_BIN in \$WORKDIR"

# fswatch coalesces events with a 1s latency by default — typically one fire per
# new note landing. We don't filter by event type because macOS FSEvents semantics
# vary; instead we check at fire-time whether any .txt files are pending at the
# folder root and let one claude -p invocation batch-process them per the rules
# in CLAUDE.md. The routing rules move processed files into processed/, so the
# next fswatch event finds the folder empty and skips claude entirely.
#
# Process substitution (< <(fswatch ...)) keeps the while loop in the main shell
# so 'exit 0' actually exits the script (and launchd's KeepAlive restarts us).
# A piped 'fswatch | while ...' would put the loop in a subshell where exit
# only kills the subshell, leaving fswatch orphaned and the bash hung.
while IFS= read -r -d "" path; do
  # Self-restart on output-folder change: if the sidecar's mtime advanced since
  # startup, the user picked a different notes folder. Exit so launchd's
  # KeepAlive restarts the worker, which re-resolves \$NOTES from the sidecar.
  CURRENT_SIDECAR_MTIME=\$(stat -f %m "\$SIDECAR" 2>/dev/null || echo "0")
  if [ "\$CURRENT_SIDECAR_MTIME" != "\$LAST_SIDECAR_MTIME" ]; then
    echo "[\$(date -Iseconds)] sidecar changed, exiting for launchd restart"
    exit 0
  fi

  # Ignore App Support events that didn't change the sidecar (state.json
  # watermark writes, etc.).
  case "\$path" in
    "\$APP_SUPPORT"*) continue ;;
  esac

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

  echo "[\$(date -Iseconds)] processing \${#pending[@]} pending note(s) one at a time"
  # Process each note in its own claude invocation. Batch prompts confused
  # smaller models (Haiku would move all files to processed/ but skip the
  # routing step for some — known context-fragmentation failure mode).
  # Per-file gives claude full attention on one decision. Same total cost.
  #
  # --permission-mode bypassPermissions: the watcher is autonomous — there's
  #   no user to approve tool calls per-invocation. See autonomous.md for
  #   the blast-radius discussion before installing this.
  # < /dev/null: skip claude's 3s "waiting for stdin" timeout.
  for note in "\${pending[@]}"; do
    echo "[\$(date -Iseconds)] processing: \$note"
    # Per-note model split: media notes (a URL or an attachment) need a model
    # strong enough to drive an extraction skill end-to-end; Haiku can't. Plain
    # text/reminder notes stay on cheap Haiku. Detection is a deterministic grep,
    # so the model choice never itself depends on a model. Override either with
    # RAPTURE_MEDIA_MODEL / RAPTURE_TEXT_MODEL.
    if grep -qiE 'https?://|^Attachments?:' "\$note"; then
      MODEL="\${RAPTURE_MEDIA_MODEL:-sonnet}"
    else
      MODEL="\${RAPTURE_TEXT_MODEL:-haiku}"
    fi
    echo "[\$(date -Iseconds)] model: \$MODEL"
    if ! (cd "\$WORKDIR" && "\$CLAUDE_BIN" -p --model "\$MODEL" \\
         --permission-mode bypassPermissions \\
         "Process the single Rapture note at \$note per the rules in \$NOTES/CLAUDE.md. Required sequence: (1) read the note, (2) classify it per the hints, checking any Media extraction section FIRST, (3) execute the routing action; for media notes invoke the named extraction skill (e.g. extract-transcript / extract-webpage / tool-markitdown) EXPLICITLY by name rather than relying on auto-trigger, and append any list entries with a shell '>>' append rather than a rewrite; then ONLY (4) move the source file. Never move a file to processed/ without first writing its routing destination. Print one summary line: '→ <category>[/client:<name>]: <destination>'." < /dev/null); then
      echo "[\$(date -Iseconds)] claude -p failed (exit \$?) on \$note"
    fi
  done
done < <(fswatch -0 "\$NOTES" "\$APP_SUPPORT")
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

# --- 2b. inject persistent config (optional) ---
# A KEY=VALUE config file lets you pin the models, notes folder, workdir, or
# claude binary without hand-editing the generated plist (which a reinstall
# regenerates). Each line becomes a launchd EnvironmentVariable the worker reads,
# so the settings survive reboots and reinstalls. Supported keys:
# RAPTURE_MEDIA_MODEL, RAPTURE_TEXT_MODEL, RAPTURE_NOTES_FOLDER,
# RAPTURE_CLAUDE_WORKDIR, RAPTURE_CLAUDE_BIN. See examples/watch.env.example.
CONFIG_FILE="${RAPTURE_CONFIG:-$HOME/.config/rapture-mac/watch.env}"
if [ -f "$CONFIG_FILE" ]; then
  echo "→ Applying config from $CONFIG_FILE"
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$PLIST_PATH" 2>/dev/null || true
  while IFS='=' read -r _k _v; do
    case "$_k" in ''|\#*) continue ;; esac
    _k="$(printf '%s' "$_k" | xargs)"; _v="$(printf '%s' "$_v" | xargs)"
    [ -n "$_k" ] || continue
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:$_k string $_v" "$PLIST_PATH" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:$_k $_v" "$PLIST_PATH"
  done < "$CONFIG_FILE"
fi

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
echo "  Models:  media → ${RAPTURE_MEDIA_MODEL:-sonnet}, text → ${RAPTURE_TEXT_MODEL:-haiku}  (claude: $CLAUDE_BIN)"
echo "  Config:  $CONFIG_FILE  (optional KEY=VALUE — see examples/watch.env.example)"
if [ "$RULES_INSTALLED" = true ]; then
  echo "  Routing: $NOTES_RULES (starter — customize to your workflow)"
  echo
  echo "→ Customize the routing rules:"
  echo "    \$EDITOR \"$NOTES_RULES\""
elif [ -f "$NOTES_RULES" ]; then
  echo "  Routing: $NOTES_RULES (already present, not modified)"
fi
echo
echo "→ Verify: dictate a Siri note. Activity should appear in $LOG_OUT"
echo "  within ~1 second of the file landing."
echo
echo "Status:    bash Scripts/status.sh"
echo "Uninstall: bash Scripts/uninstall-claude-watch.sh"
