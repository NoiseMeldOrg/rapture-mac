---
name: rapture-watch
description: Process newly-captured Rapture notes. Classify each .txt, take routing action, optionally send a summary via Telegram.
---

# Rapture watcher

Runs from an OpenClaw cron job. Processes any new `.txt` files Rapture for Mac has written to your notes folder since the last run.

## When invoked

1. List `*.txt` in `~/Documents/Rapture Notes/` (don't recurse into `processed/`).
2. Skip any `*.tmp` files; those are Rapture's in-flight atomic writes.
3. For each remaining file, ordered by mtime ascending:
   1. Read it.
   2. Classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action.
   4. Move the source to `processed/YYYY-MM/<original-filename>`.
4. If a Telegram channel is configured, send a single summary message at the end: `📥 Processed N notes: <todo: 3, journal: 1, ...>`. Suppress when N = 0.

## Routing actions

- **todo**: append to `~/Documents/Rapture Notes/inbox/todos.md` as a Markdown checkbox: `- [ ] <text>  (captured <iso-ts>)`.
- **journal**: append to `~/Documents/Rapture Notes/inbox/journal-YYYY-MM.md` under an ISO timestamp heading.
- **idea**: append to `~/Documents/Rapture Notes/inbox/ideas.md`, same format as journal.
- **code-task**: leave the file in place. Surface in the Telegram summary as `🔧 code task in <filename>` so the user knows to triage it manually in a real project session.
- **reminder**: append to `~/Documents/Rapture Notes/inbox/reminders.md`. If the user mentioned a date, prepend it.
- **other**: append to `~/Documents/Rapture Notes/inbox/uncategorized.md`.

## Permissions

- Read + write within `~/Documents/Rapture Notes/` only.
- Telegram send (if your OpenClaw is configured with a Telegram gateway).
- No iMessage send needed. Rapture for Mac already sent the `✓ Saved` confirmation when each file landed.

## Pitfalls

- Don't process files that are still being written. Skip any `*.txt.tmp` files.
- Don't move files in `processed/`. The watermark is "file is in the root of the notes folder."
- If `~/Documents/Rapture Notes/` doesn't exist, do nothing and exit cleanly.
