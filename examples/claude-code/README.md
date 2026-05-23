# Claude Code consumer

One recommended way to wire Claude Code up to act on your Rapture notes, plus a manual fallback for when you'd rather drive it yourself. If you specifically want **sub-second event-driven autonomous action** (Siri → new Claude Code session immediately, no waiting until you next open Claude), see [autonomous.md](./autonomous.md) — that's the right shape for you and it has a different cost trade-off worth reading about up front.

## Recommended: SessionStart hook (opportunistic)

A small hook fires whenever you start a new Claude Code session. If your notes folder has unprocessed `.txt` files, the hook surfaces the count as session context, and Claude offers to triage them per the rules in your notes folder's `CLAUDE.md`. If there's nothing pending, the hook is silent.

Why this shape:
- **No cost.** Interactive sessions stay on your regular Pro / Max subscription pool. No `claude -p`, no Agent SDK credits.
- **No always-on daemon.** No launchd, no plist, no background process.
- **Composes with your normal Claude usage.** You open Claude Code several times a day for unrelated work; triage happens opportunistically alongside.
- **Pauseable.** Run the uninstall to stop it. Re-run install to bring it back.

Trade-off: latency is "the next time you open Claude" rather than seconds. For triage / classification work that's the right trade. If you need notes acted on while you're away from your Mac, this isn't the right shape — write your own watcher.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/scripts/install-claude-hook.sh | bash
```

The script (idempotent, safe to re-run) does two things:

1. Writes `~/.claude/scripts/rapture-notes-check.sh`, a few lines of bash that resolve the current notes-folder path and report the count of pending `.txt` files.
2. Adds a `SessionStart` hook to `~/.claude/settings.json` that runs the script on every new session.

Requires `jq` (`brew install jq`).

### How the folder path is resolved

The check script reads the current notes-folder path in this order:

1. **Rapture's sidecar file** at `~/Library/Application Support/Rapture for Mac/output-folder.path` (written by the menu-bar app when the user picks or changes the output folder). This means changing your folder in **Settings → General** is picked up automatically — no script edit, no reinstall.
2. **`RAPTURE_NOTES_FOLDER`** environment variable, for users who set it explicitly at install time.
3. **`~/Documents/Rapture Notes/`**, the default.

### Routing rules — copy `CLAUDE.md` into your notes folder

The included `CLAUDE.md` is a starter classification rubric. Copy it once:

```sh
cp CLAUDE.md ~/Documents/Rapture\ Notes/CLAUDE.md
```

Then edit it to match your own workflow. Most users tune the categories within a week — typical adds are `meeting-prep`, `shopping-list`, or project-specific code-task routing.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/scripts/uninstall-claude-hook.sh | bash
```

Removes the hook entry and the check script. Your notes folder and its `CLAUDE.md` are left untouched.

### Editing

Both pieces are independent and meant to be edited:

| What | File | Edit reason |
|---|---|---|
| The check logic (message wording, filters, etc.) | `~/.claude/scripts/rapture-notes-check.sh` | Plain bash; reinstaller will overwrite, so heavy customizers should fork |
| Whether the hook fires at all | `~/.claude/settings.json` → `.hooks.SessionStart` | Run the uninstall to remove cleanly |

## Alternative: manual `claude` in the folder

When you specifically want to triage and don't want a hook involved:

```sh
cd ~/Documents/Rapture\ Notes
claude
```

Then type `process new notes` (or anything that fits). The `CLAUDE.md` in the folder is auto-loaded into context.
