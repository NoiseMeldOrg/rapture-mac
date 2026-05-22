---
name: rapture-watch
description: Process newly-captured Rapture notes. Classify each .txt, take routing action, optionally send a summary via Telegram (or any configured OpenClaw channel).
---

# Rapture watcher

Runs from an OpenClaw cron job. Processes any new `.txt` files Rapture for Mac has written to your notes folder since the last run.

## Resolving the notes folder

At every invocation, resolve `$NOTES_FOLDER` in this order:

1. If `~/Library/Application Support/Rapture for Mac/output-folder.path` exists and is readable, use its contents (one absolute path, possibly with trailing newline — trim whitespace).
2. Otherwise default to `~/Documents/Rapture Notes/`.

This lets users change their notes folder in Rapture's Settings → General without re-creating the cron job or editing the skill.

## When invoked

1. List `*.txt` in `$NOTES_FOLDER` (don't recurse into `processed/`).
2. Skip any `*.tmp` files; those are Rapture's in-flight atomic writes.
3. For each remaining file, ordered by mtime ascending:
   1. Read it.
   2. Classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action.
   4. Move the source to `$NOTES_FOLDER/processed/YYYY-MM/<original-filename>`.
4. If the cron job has a delivery channel configured (Telegram, Discord, Signal, etc.), send a single summary message at the end: `📥 Processed N notes: <todo: 3, journal: 1, ...>`. Suppress when N = 0.

## Routing actions

- **todo**: append to `$NOTES_FOLDER/inbox/todos.md` as a Markdown checkbox: `- [ ] <text>  (captured <iso-ts>)`.
- **journal**: append to `$NOTES_FOLDER/inbox/journal-YYYY-MM.md` under an ISO timestamp heading.
- **idea**: append to `$NOTES_FOLDER/inbox/ideas.md`, same format as journal.
- **code-task**: leave the file in place. Surface in the summary as `🔧 code task in <filename>` so the user knows to triage it manually in a real project session.
- **reminder**: append to `$NOTES_FOLDER/inbox/reminders.md`. If the user mentioned a date, prepend it.
- **other**: append to `$NOTES_FOLDER/inbox/uncategorized.md`.

## Permissions

- Read + write within `$NOTES_FOLDER` only.
- Whatever channel send the cron job is configured for.
- No iMessage send needed. Rapture for Mac already sent the `✓ Saved` confirmation when each file landed.

## Pitfalls

- Don't process files that are still being written. Skip any `*.txt.tmp` files.
- Don't move files in `processed/`. The watermark is "file is in the root of the notes folder."
- If `$NOTES_FOLDER` doesn't exist, do nothing and exit cleanly.
- If the sidecar exists but contains an unreadable / nonexistent path, fall back to the default.
