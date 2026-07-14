# Claude Code consumer

A SessionStart hook that surfaces recently triaged Rapture notes whenever you next open Claude Code, plus a manual fallback for when you'd rather drive it yourself.

Rapture for Mac already classifies every capture into a Markdown note and files it under `Notes/`, `Links/`, `Tasks/`, `Ideas/`, or `Journal/` in your output folder. So this consumer doesn't classify anything. It points Claude at the new notes and lets it act on them: file tasks, summarize links, review journal entries, per the rules in your notes folder's `CLAUDE.md`.

## SessionStart hook (opportunistic)

A small hook fires whenever you start a new Claude Code session. If your notes folder has recent `.md` notes in the triaged subfolders, the hook surfaces the count as session context, and Claude offers to work through them per your notes folder's `CLAUDE.md`. If there's nothing recent, the hook is silent.

Why this shape:
- **No cost.** Interactive sessions stay on your regular Pro / Max subscription pool. No `claude -p`, no Agent SDK credits.
- **No always-on daemon.** No launchd, no plist, no background process.
- **Composes with your normal Claude usage.** You open Claude Code several times a day for unrelated work; note processing happens opportunistically alongside.
- **Pauseable.** Run the uninstall to stop it. Re-run install to bring it back.

Trade-off: latency is "the next time you open Claude" rather than seconds. Since the app itself already triaged and filed each capture the moment it landed, nothing is waiting on Claude to be findable — only the follow-up actions wait. If you need those actions to run while you're away from your Mac, this isn't the right shape — write your own watcher consumer that reads the folder directly.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/scripts/install-claude-hook.sh | bash
```

The script (idempotent, safe to re-run) does two things:

1. Writes `~/.claude/scripts/rapture-notes-check.sh`, a few lines of bash that resolve the current notes-folder path and report recent `.md` notes across the triaged subfolders (a `find <folder> -name '*.md' -mtime -1` style check).
2. Adds a `SessionStart` hook to `~/.claude/settings.json` that runs the script on every new session.

Requires `jq` (`brew install jq`).

### How the folder path is resolved

The check script reads the current notes-folder path in this order:

1. **Rapture's sidecar file** at `~/Library/Application Support/Rapture for Mac/output-folder.path` (written by the menu-bar app when the user picks or changes the output folder). This means changing your folder in **Settings → General** is picked up automatically — no script edit, no reinstall.
2. **`RAPTURE_NOTES_FOLDER`** environment variable, for users who set it explicitly at install time.
3. **`~/Documents/Rapture Notes/`**, the default.

### Action rules — copy `CLAUDE.md` into your notes folder

The included `CLAUDE.md` is a starter set of rules for acting on triaged notes (what to do with a `task` note, when to extract a link, what to leave alone). Copy it once:

```sh
cp CLAUDE.md ~/Documents/Rapture\ Notes/CLAUDE.md
```

Then edit it to match your own workflow. Most users tune the actions within a week — typical adds are pushing `Tasks/` notes into a real task manager, or project-specific handling for code-task dictations.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/scripts/uninstall-claude-hook.sh | bash
```

Removes the hook entry and the check script. Your notes folder and its `CLAUDE.md` are left untouched.

### Editing

Both pieces are independent and meant to be edited:

| What | File | Edit reason |
|---|---|---|
| The check logic (message wording, recency window, etc.) | `~/.claude/scripts/rapture-notes-check.sh` | Plain bash; reinstaller will overwrite, so heavy customizers should fork |
| Whether the hook fires at all | `~/.claude/settings.json` → `.hooks.SessionStart` | Run the uninstall to remove cleanly |

## Alternative: manual `claude` in the folder

When you specifically want to process notes and don't want a hook involved:

```sh
cd ~/Documents/Rapture\ Notes
claude
```

Then type `process new notes` (or anything that fits). The `CLAUDE.md` in the folder is auto-loaded into context.

## Raw mode

If you've flipped **Settings → Triage → Filing** to **"Raw text files, no triage"**, captures stay as `<ISO-timestamp>.txt` files at the folder root and are never converted. The included `CLAUDE.md` has a raw-mode section covering that case: Claude classifies each root `.txt` itself and moves it to `processed/YYYY-MM/` after acting — the pre-triage behavior of this example. Those instructions apply only in raw mode.
