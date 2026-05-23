<!--
  This file is a STARTER TEMPLATE for use inside your Rapture notes folder.
  Copy it to ~/Documents/Rapture Notes/CLAUDE.md (or wherever your Rapture
  notes folder lives) before invoking Claude Code in that directory.

  It is NOT intended to be loaded by Claude Code from this examples/ folder.
  If you're seeing these instructions while working on rapture-mac itself,
  ignore them — see the top-level CLAUDE.md for actual rapture-mac dev rules.
-->

# Rapture notes — Claude Code routing rules

When Claude Code is invoked from a folder containing this file, it picks up these instructions automatically.

## What you're processing

`.txt` files in this folder, one per Siri-dictated iMessage captured by Rapture for Mac. Filenames are ISO 8601 UTC timestamps. File contents are the user's spoken thought, transcribed by Siri.

## Each invocation

1. List `*.txt` in the folder root. Don't recurse into `processed/` or `code-tasks/`.
2. Skip any `*.tmp` files; those are Rapture's in-flight atomic writes.
3. For each remaining file in ascending mtime order:
   1. Read it.
   2. Classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action below. **Every action ends with moving the source file out of the folder root** so it doesn't get re-processed on the next invocation. Most go to `processed/YYYY-MM/`; code-tasks go to `code-tasks/` for manual triage.
4. Print a one-line summary per file: `→ <category>: <action taken>`.

## Routing actions

- **todo**: append a line to `inbox/todos.md` in the format `- [ ] <text>  (captured <iso-ts>)`, then move source to `processed/YYYY-MM/`.
- **journal**: append the text to `inbox/journal-YYYY-MM.md` under an ISO timestamp heading, then move source to `processed/YYYY-MM/`.
- **idea**: append to `inbox/ideas.md` (same format as journal), then move source to `processed/YYYY-MM/`.
- **code-task**: append a one-line pointer to `inbox/code-tasks.md` (format: `- [ ] <filename> — <one-sentence summary>  (captured <iso-ts>)`), then move source to `code-tasks/<original-filename>`. Don't try to execute the task here; the user will spin up a real project session when ready. The separate `code-tasks/` subfolder keeps these visible without cluttering `processed/`.
- **reminder**: append to `inbox/reminders.md` (prepend a date if the note mentions one), then move source to `processed/YYYY-MM/`.
- **other**: append to `inbox/uncategorized.md` (note in the summary that classification was unclear), then move source to `processed/YYYY-MM/`.

## Catch-up rule

If there are more than 20 unprocessed files (the Mac slept for a long weekend, for example), summarize in chunks of 10 to keep output readable. Still process each file individually.

## Don't

- Don't touch files in `processed/` or `code-tasks/`. They've already been routed.
- Don't generate iMessage replies. Rapture itself sent the `✓ Saved` confirmation when each file landed.
- Don't write outside this folder unless a captured note explicitly tells you to.
