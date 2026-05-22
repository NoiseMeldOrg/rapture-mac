# Claude Code consumer

Three ways to wire Claude Code up to act on your Rapture notes.

## 1. Manual (simplest)

```sh
cd ~/Documents/Rapture\ Notes
claude
```

Then type `process new notes` (or any prompt that fits). The `CLAUDE.md` in the folder is auto-loaded into context, so Claude already knows the routing rules.

Use this when you're at your desk and want to triage your inbox by hand.

## 2. Claude Code Desktop scheduled task

If you use Claude Code Desktop instead of the terminal CLI, you can create a local scheduled task that runs every N minutes without needing an open session.

In the Desktop app:

1. Click **Routines** in the sidebar.
2. Click **New routine** and choose **Local**.
3. Fill in:
   - **Name:** `rapture-processor`
   - **Folder:** `~/Documents/Rapture Notes/`
   - **Instructions:** `process new notes per ./CLAUDE.md`
   - **Schedule:** Hourly (or ask Claude in any Desktop session, e.g., "set rapture-processor to run every 10 minutes" for finer control)

The first run will trigger permission prompts for any tools the routing rules use; choose "always allow" so future runs are silent.

Docs: <https://docs.claude.com/en/desktop-scheduled-tasks>

## 3. launchd plist (event-driven, no Desktop install)

Use the headless `claude -p` mode driven by a launchd plist that fires whenever the notes folder changes. Lower latency than the polled Routines option, and no Desktop dependency.

```sh
# Copy and edit
cp com.user.rapture-processor.plist ~/Library/LaunchAgents/

# Replace YOUR_USERNAME with your actual short username
sed -i '' "s|YOUR_USERNAME|$USER|" ~/Library/LaunchAgents/com.user.rapture-processor.plist

# Adjust the claude binary path inside the plist if needed
which claude
# Edit the plist to match (e.g., /opt/homebrew/bin/claude on Apple Silicon)

# Validate
plutil -lint ~/Library/LaunchAgents/com.user.rapture-processor.plist

# Load
launchctl load ~/Library/LaunchAgents/com.user.rapture-processor.plist

# Watch
tail -f /tmp/rapture-processor.out.log /tmp/rapture-processor.err.log
```

To stop: `launchctl unload ~/Library/LaunchAgents/com.user.rapture-processor.plist`.

The job fires whenever the contents of `~/Documents/Rapture Notes/` change — file added, removed, or renamed. `ThrottleInterval = 10` keeps launchd from re-running more than once every 10 seconds. The bash `ls *.txt` guard skips firings when no `.txt` files are pending; necessary because moving processed files into `processed/` also triggers `WatchPaths`.

If you'd rather poll than react to changes (every N seconds regardless of folder activity), swap the `WatchPaths` key for `StartInterval` and set the integer to your desired seconds.

### Model choice

The example pins `--model haiku` because note classification is a lightweight task and Haiku is fast + cheap. `claude -p` uses whatever auth your interactive `claude` is using — subscription, API key, whatever's in `~/.claude/`; the `-p` flag does *not* force API-key billing. If you'd rather use Sonnet or Opus, edit the `ProgramArguments` line in the plist.

## CLAUDE.md routing rules

The included `CLAUDE.md` is a starter. Copy it to `~/Documents/Rapture Notes/CLAUDE.md` and tune the classification rubric to your workflow. Most users add `meeting-prep`, `shopping-list`, or domain-specific categories within a week.
