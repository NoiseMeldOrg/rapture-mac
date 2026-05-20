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

1. List `*.txt` in the folder root. Don't recurse into `processed/`.
2. Skip any `*.tmp` files; those are Rapture's in-flight atomic writes.
3. For each remaining file in ascending mtime order:
   1. Read it.
   2. Classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action below.
   4. Move the source file to `processed/YYYY-MM/<original-filename>`.
4. Print a one-line summary per file: `→ <category>: <action taken>`.

## Routing actions

- **todo**: append a line to `inbox/todos.md`. Format: `- [ ] <text>  (captured <iso-ts>)`.
- **journal**: append the text to `inbox/journal-YYYY-MM.md` under an ISO timestamp heading.
- **idea**: append to `inbox/ideas.md`, same format as journal.
- **code-task**: don't act and don't move the file. Print the text verbatim under a `### Code task` heading so the user can copy it into a real project session.
- **reminder**: append to `inbox/reminders.md`. If the user mentioned a date, prepend it.
- **other**: append to `inbox/uncategorized.md` and note in the summary that classification was unclear.

## Catch-up rule

If there are more than 20 unprocessed files (the Mac slept for a long weekend, for example), summarize in chunks of 10 to keep output readable. Still process each file individually.

## Don't

- Don't touch files in `processed/`. They've already been handled.
- Don't generate iMessage replies. Rapture itself sent the `✓ Saved` confirmation when each file landed.
- Don't write outside this folder unless a captured note explicitly tells you to.
