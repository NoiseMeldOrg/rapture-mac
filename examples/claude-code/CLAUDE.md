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

## Two reliability rules (read first)

1. **Invoke skills explicitly BY NAME — never rely on a skill auto-triggering from its description.** With many skills installed, description-matching is unreliable and the right one usually won't fire on its own. When a routing action names a skill (e.g. "use the extract-transcript skill"), call it by name.
2. **Append to shared list/log files with a shell `>>` append, never by reading-and-rewriting with Edit/Write.** A weak model that rewrites a shared file regenerates it with only the current item and clobbers everything else. Use `printf '%s\n' "- entry" >> file`.

## Dedup — don't redo work already done (read first)

A note's *file* is only ever processed once (it gets moved out of the root). But the same link or request often arrives again as a brand-new capture days later. Before any action that's expensive to redo — or, worse, has an external side effect — check whether you've already handled that content and skip if so. A skip still moves the source out of the root; it just doesn't repeat the work.

This needs a greppable ledger. The **Media extraction** section below keeps one: every extraction appends a line to `processed-media.md` that includes the source URL. Before extracting, grep that file:

- **YouTube** → match the **video ID** (the slug after `v=` / `youtu.be/` / `shorts/`). Query params and the `t=` timestamp vary between captures; the ID doesn't, so match on the ID, not the whole URL.
- **Other links** → match the normalized URL (lowercase host; strip `#…`, `?utm_*`/tracking params, and any trailing `/`).

If the fingerprint is already in the ledger, skip extraction, append a `SKIPPED (already processed)` line, and move the source. The grep is a READ, so it doesn't violate reliability rule 2.

If you extend these rules with actions that have **external side effects** — sending an email, creating a calendar event — apply the same principle: keep a log of what you did and check it before acting, so a re-dictated note can never double-send or double-book. A duplicate file is cheap; a duplicate email is not.

## What you're processing

`.txt` files in this folder, one per Siri-dictated iMessage captured by Rapture for Mac. Filenames are ISO 8601 UTC timestamps. File contents are the user's spoken thought, transcribed by Siri.

## Each invocation

1. List `*.txt` in the folder root. Don't recurse into `processed/` or `code-tasks/`.
2. Skip any `*.tmp` files; those are Rapture's in-flight atomic writes.
3. For each remaining file in ascending mtime order:
   1. Read it.
   2. Classify. **Check media first:** if the note's payload is a URL or an attachment, route it via the **Media extraction** section below. Otherwise classify into one of: `todo`, `journal`, `idea`, `code-task`, `reminder`, `other`.
   3. Take the routing action below. **Every action ends with moving the source file out of the folder root** so it doesn't get re-processed on the next invocation. Most go to `processed/YYYY-MM/`; code-tasks go to `code-tasks/` for manual triage.
4. Print a one-line summary per file: `→ <category>: <action taken>`.

## Media extraction (if you have extraction skills installed)

Most captured notes are just a pasted link. If you have the relevant skills installed, extract the *content* (so it's searchable later) rather than just filing the link.

**Before extracting any link, run the Dedup check above** — grep `processed-media.md` for its fingerprint and skip if it's already there. **After a successful extraction, append one `>>` line to `processed-media.md` that includes the source URL**, e.g. `printf '%s\n' "- [youtube] <title> <url> → transcripts/<file>  (captured <iso-ts>)" >> processed-media.md`. That line is both the receipt and the thing the next run greps against — so the URL must be in it.

- **YouTube URL** → invoke the `extract-transcript` skill by name; save the markdown alongside your notes (e.g. a `transcripts/` folder); log to `processed-media.md` with the URL.
- **Other web link** → invoke `extract-webpage` (or `tool-firecrawl-scraper`); log to `processed-media.md` with the URL.
- **Document attachment** (PDF/DOCX/PPTX/XLSX) → invoke `tool-markitdown`.
- **Image attachment** → you're on a vision-capable model; read the image directly and write a description + any visible text. (markitdown returns empty on images with no EXIF.)
- **X / Facebook / Instagram** → no reliable extractor yet; log the link to a `needs-processing.md` checklist so it's never lost. Check that file first so the same link isn't queued twice.

If you don't have these skills, fall back to filing the link under `idea`/`reminder`. Either way, move the source note out of the root when done.

## Routing actions

Each routing destination is a single `.md` file at the notes-folder root, alongside `CLAUDE.md` and the raw `.txt` captures. The `*.txt` glob the worker uses only matches captured notes, so the routed `.md` files don't get re-processed.

- **todo**: append a line to `todos.md` in the format `- [ ] <text>  (captured <iso-ts>)`, then move source to `processed/YYYY-MM/`.
- **journal**: append the text to `journal-YYYY-MM.md` under an ISO timestamp heading, then move source to `processed/YYYY-MM/`.
- **idea**: append to `ideas.md` (same format as journal), then move source to `processed/YYYY-MM/`.
- **code-task**: append a one-line pointer to `code-tasks.md` (format: `- [ ] <filename> — <one-sentence summary>  (captured <iso-ts>)`), then move source to `code-tasks/<original-filename>`. Don't try to execute the task here; the user will spin up a real project session when ready. The separate `code-tasks/` subfolder keeps these visible without cluttering `processed/`.
- **reminder**: append to `reminders.md` (prepend a date if the note mentions one), then move source to `processed/YYYY-MM/`.
- **other**: append to `uncategorized.md` (note in the summary that classification was unclear), then move source to `processed/YYYY-MM/`.

## Catch-up rule

If there are more than 20 unprocessed files (the Mac slept for a long weekend, for example), summarize in chunks of 10 to keep output readable. Still process each file individually.

## Don't

- Don't touch files in `processed/` or `code-tasks/`. They've already been routed.
- Don't re-process the routed `.md` files at root (`todos.md`, `journal-*.md`, `ideas.md`, `code-tasks.md`, `reminders.md`, `uncategorized.md`, `processed-media.md`, `needs-processing.md`); they're routing destinations and dedup ledgers, not input notes.
- Don't generate iMessage replies. Rapture itself sent the `✅ Saved` confirmation when each file landed.
- Don't write outside this folder unless a captured note explicitly tells you to.
