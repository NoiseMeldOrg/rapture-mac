---
name: rapture-watch
description: Process newly-captured Rapture notes. Classify each .txt, take routing action, optionally send a summary via Telegram.
version: 0.1.0
author: Rapture for Mac contributors
license: Apache-2.0
platforms: [macos]
metadata:
  hermes:
    tags: [Productivity, Capture]
---

# Rapture watcher

Runs from a Hermes cron job. Processes any new `.txt` files Rapture for Mac has written to your notes folder since the last run.

## Resolving the notes folder

At every invocation, resolve `$NOTES_FOLDER` in this order:

1. If `~/Library/Application Support/Rapture for Mac/output-folder.path` exists and is readable, use its contents (one absolute path, possibly with trailing newline — trim whitespace).
2. Otherwise default to `~/Documents/Rapture Notes/`.

This lets users change their notes folder in Rapture's Settings → General without re-creating the cron job or editing the skill.

## When to use

When a Hermes cron job invokes this skill against the resolved `$NOTES_FOLDER`.

## Procedure

1. List `*.txt` in the notes folder root. Don't recurse into `processed/`.
2. Skip any `*.tmp` files. Those are Rapture's in-flight atomic writes.
3. For each remaining file, ordered by mtime ascending:
   1. Read it.
   2. Classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action below.
   4. Move the source to `$NOTES_FOLDER/processed/YYYY-MM/<original-filename>`.
4. Send a single summary message via the cron job's configured delivery channel: `📥 Processed N notes: <todo: 3, journal: 1, ...>`. Suppress when N = 0. (Hermes' delivery default is `local` / CLI; the cron job must pass `--deliver telegram` or similar for the summary to reach a messaging channel.)

## Routing actions

- **todo**: append to `$NOTES_FOLDER/inbox/todos.md` as a Markdown checkbox: `- [ ] <text>  (captured <iso-ts>)`.
- **journal**: append to `$NOTES_FOLDER/inbox/journal-YYYY-MM.md` under an ISO timestamp heading.
- **idea**: append to `$NOTES_FOLDER/inbox/ideas.md`, same format as journal.
- **code-task**: leave the file in place. Surface in the summary as `🔧 code task in <filename>`.
- **reminder**: append to `$NOTES_FOLDER/inbox/reminders.md`. If the user mentioned a date, prepend it.
- **other**: append to `$NOTES_FOLDER/inbox/uncategorized.md`.

## Pitfalls

- Don't process `*.tmp` files. Skip them.
- Don't touch files in `processed/`. They've already been handled.
- If `$NOTES_FOLDER` doesn't exist, exit cleanly with a message in the summary.
- If the sidecar exists but contains an unreadable / nonexistent path, fall back to the default.
- Rapture for Mac already sends the `✓ Saved` confirmation in the iMessage thread when each file lands, so this skill's delivery channel is for the *processing* summary, not the per-capture acknowledgement.

## Verification

After install + cron setup, dictate a Siri test note to yourself. Within the next cron tick (5 minutes by default), you should see a Telegram message summarizing one processed note, and the corresponding `.txt` should have moved from the notes folder root into `processed/YYYY-MM/`.
