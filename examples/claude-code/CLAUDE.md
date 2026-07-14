<!--
  This file is a STARTER TEMPLATE for use inside your Rapture notes folder.
  Copy it to ~/Documents/Rapture Notes/CLAUDE.md (or wherever your Rapture
  notes folder lives) before invoking Claude Code in that directory.

  It is NOT intended to be loaded by Claude Code from this examples/ folder.
  If you're seeing these instructions while working on rapture-mac itself,
  ignore them — see the top-level CLAUDE.md for actual rapture-mac dev rules.
-->

# Rapture notes — Claude Code rules

When Claude Code is invoked from a folder containing this file, it picks up these instructions automatically.

## Two reliability rules (read first)

1. **Invoke skills explicitly BY NAME — never rely on a skill auto-triggering from its description.** With many skills installed, description-matching is unreliable and the right one usually won't fire on its own. When an action names a skill (e.g. "use the extract-transcript skill"), call it by name.
2. **Append to shared list/log files with a shell `>>` append, never by reading-and-rewriting with Edit/Write.** A weak model that rewrites a shared file regenerates it with only the current item and clobbers everything else. Use `printf '%s\n' "- entry" >> file`.

## What you're processing

Rapture for Mac has already triaged every capture into a Markdown note. Each note has YAML frontmatter:

```markdown
---
captured: 2026-07-13T14:32:08Z
source: rapture-mac
type: voice-note
---
```

- `captured` — UTC instant of the dictation.
- `type` — one of `voice-note`, `youtube-link`, `article-link`, `task`, `idea`, `journal`. This is the app's classification; trust it as the starting point.
- `source` (optional) — `rapture-mac`, `rapture-ios`, or `rapture-android`.
- `raw_media` (optional) — path to the original audio for relay captures.

Notes are filed by type into subfolders: `Notes/`, `Links/`, `Tasks/`, `Ideas/`, `Journal/` (the last three exist only when the user's AI triage tier is on). Filenames are `YYYY-MM-DD <Title>.md`. When formatting changed the body, the verbatim dictation is preserved under a `## Raw` section — quote from `## Raw` when exact wording matters. Attachments live in a sibling folder named after the note, linked from an `Attachments:` footer.

`Links/Media/` holds fetched transcript/readable-text artifacts (written by the app's opt-in Link enrichment). They are inputs, not notes — never process them as pending work.

Your job is NOT to classify or convert anything. The app did that. Your job is to **act** on triaged notes: file tasks, extract or summarize link content, surface ideas, review journal entries.

## Each invocation

1. Find pending notes: `.md` files in `Notes/`, `Links/`, `Tasks/`, `Ideas/`, `Journal/` (top level of each; don't recurse into `Links/Media/`) whose folder-relative path is not yet in `processed-log.md` at the folder root. Grep that file per note (a READ, so rule 2 doesn't apply).
2. Ignore any `.tmp` files (Rapture's in-flight atomic writes) and any `.txt` at the folder root — the app converts those to Markdown within seconds; don't race it.
3. For each pending note in ascending mtime order:
   1. Read it, frontmatter first.
   2. Take the action for its `type` (below).
   3. Append its relative path to the log: `printf '%s\n' "Notes/2026-07-13 Rent due.md" >> processed-log.md`.
4. Print a one-line summary per note: `→ <type>: <action taken>`.

Notes stay where the app filed them. The log, not a move, is what marks a note handled.

## Dedup — don't redo work already done (read first)

A note is only ever acted on once (the log guarantees that). But the same link or request often arrives again as a brand-new capture days later. Before any action that's expensive to redo — or, worse, has an external side effect — check whether you've already handled that content and skip if so. A skip still logs the note as processed; it just doesn't repeat the work.

This needs a greppable ledger. The **Link content** section below keeps one: every extraction appends a line to `processed-media.md` that includes the source URL. Before extracting, grep that file:

- **YouTube** → match the **video ID** (the slug after `v=` / `youtu.be/` / `shorts/`). Query params and the `t=` timestamp vary between captures; the ID doesn't, so match on the ID, not the whole URL.
- **Other links** → match the normalized URL (lowercase host; strip `#…`, `?utm_*`/tracking params, and any trailing `/`).

If the fingerprint is already in the ledger, skip extraction, append a `SKIPPED (already processed)` line, and log the note.

If you extend these rules with actions that have **external side effects** — sending an email, creating a calendar event — apply the same principle: keep a log of what you did and check it before acting, so a re-dictated note can never double-send or double-book. A duplicate file is cheap; a duplicate email is not.

## Actions by type

- **task** (`Tasks/`): append a line to `todos.md` at the folder root in the format `- [ ] <text>  (captured <iso-ts>)`. If the note names a date or time, prepend it. (If the user has already wired Rapture's own Reminders handoff, `todos.md` is a belt-and-suspenders index — keep appending unless they've told you otherwise.)
- **idea** (`Ideas/`): append a one-line pointer to `ideas.md`: `- <filename> — <one-sentence gist>  (captured <iso-ts>)`.
- **journal** (`Journal/`): nothing per-note by default. When asked to "review my journal", read the recent entries and summarize.
- **youtube-link / article-link** (`Links/`): see **Link content** below.
- **voice-note** (`Notes/`): read it and decide. If it's actionable ("email Sarah about the deck"), treat it like a task. If it's a request you can complete in-session and the note explicitly asks for it, do it. Otherwise just log it — the note is already filed and searchable.

If a note looks misfiled (the app's classifier is good, not perfect), act on what the content actually is; don't re-file it.

## Link content (if you have extraction skills installed)

Link notes in `Links/` may or may not already have their content fetched:

- **Enrichment already ran**: the note body has a `Media:` link pointing into `Links/Media/`, and the title is the real video/page title. Don't re-fetch. If the user wants a summary, read the artifact in `Links/Media/` and work from that.
- **No `Media:` link** (enrichment off, or the fetch failed): extract the content yourself so it's searchable later.

**Before extracting any link, run the Dedup check above** — grep `processed-media.md` for its fingerprint and skip if it's already there. **After a successful extraction, append one `>>` line to `processed-media.md` that includes the source URL**, e.g. `printf '%s\n' "- [youtube] <title> <url> → Links/Media/<file>  (captured <iso-ts>)" >> processed-media.md`. That line is both the receipt and the thing the next run greps against — so the URL must be in it.

- **YouTube URL** → invoke the `extract-transcript` skill by name; save the markdown into `Links/Media/`; log to `processed-media.md` with the URL.
- **Other web link** → invoke `extract-webpage` (or `tool-firecrawl-scraper`); save into `Links/Media/`; log with the URL.
- **Document attachment** (PDF/DOCX/PPTX/XLSX, in the note's sibling attachment folder) → invoke `tool-markitdown`.
- **Image attachment** → you're on a vision-capable model; read the image directly and write a description + any visible text. (markitdown returns empty on images with no EXIF.)
- **X / Facebook / Instagram** → no reliable extractor yet; log the link to a `needs-processing.md` checklist so it's never lost. Check that file first so the same link isn't queued twice.

If you don't have these skills, just log the note as processed — the app already filed the link where it's findable.

## Catch-up rule

If there are more than 20 pending notes (the Mac slept for a long weekend, for example), summarize in chunks of 10 to keep output readable. Still process each note individually.

## Don't

- Don't edit, rename, move, or delete the triaged `.md` notes. The tree is the user's notes; you consume it.
- Don't touch `Links/Media/` contents except to read them.
- Don't process root `.txt` files or `.tmp` files. The app converts root `.txt` drops itself.
- Don't re-process the ledger/destination files at root (`todos.md`, `ideas.md`, `processed-log.md`, `processed-media.md`, `needs-processing.md`); they're outputs and dedup ledgers, not input notes.
- Don't generate iMessage replies. Rapture itself sent the `✅ Saved` confirmation when each capture landed.
- Don't write outside this folder unless a note explicitly tells you to.

## Raw mode (the old contract)

If the user has flipped **Settings → Triage → Filing** to **"Raw text files, no triage"**, none of the above tree exists: captures are plain `.txt` files at the folder root named `<ISO-timestamp>.txt`, never converted, and classification is entirely your job. In that mode, classify each root `.txt` yourself (todo / journal / idea / link / other), take the equivalent action, and move the source to `processed/YYYY-MM/` so it isn't picked up again. These raw-mode instructions apply **only** in that mode.
