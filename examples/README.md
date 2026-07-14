# Examples

The folder is the entire integration surface. Rapture for Mac triages every capture the moment it lands: each one becomes a Markdown note with YAML frontmatter, auto-titled `YYYY-MM-DD <Title>.md`, and filed into a subfolder of your output folder — `Notes/` for voice notes, `Links/` for YouTube and article links, and (with the opt-in AI tier on) `Tasks/`, `Ideas/`, and `Journal/`. Two ways to consume the result:

- **Manually**, when you're back at your computer. Open the folder, read the notes, act on what matters.
- **Automatically**, by setting up an AI agent or assistant to watch the folder and act on each triaged note according to your own rules.

These examples are starter configs for the automated path, for the agents users most commonly arrive with.

| Agent | What's here | Setup time | Default reply channel |
|---|---|---|---|
| [Claude Code](./claude-code/) | One-line install of a `SessionStart` hook + `CLAUDE.md` rules for acting on triaged notes. Opportunistic — fires when you next open Claude Code. | ~2 min | None (in-session) |
| [OpenClaw](./openclaw/) | SKILL.md + setup notes | ~15 min | Telegram |
| [Hermes Agent](./hermes/) | SKILL.md + setup notes | ~15 min | Telegram |
| [Generic CLI](./cli/) | POSIX shell script | ~2 min | None (writes response files) |

None of these examples are tested against a running install. They're written from current agent documentation. If you find a discrepancy between an example and what your install actually does, please open an issue or PR.

## What every example does

The same shape:

1. Find the output folder via Rapture's sidecar file (`~/Library/Application Support/Rapture for Mac/output-folder.path`), falling back to `~/Documents/Rapture Notes/`.
2. Watch the triaged subfolders (`Notes/`, `Links/`, `Tasks/`, `Ideas/`, `Journal/`) for new `.md` files. Skip `Links/Media/` — those are fetched transcript/article artifacts, not notes.
3. For each new note, read the YAML frontmatter (`captured`, `type`, and the optional `source` and `raw_media` fields) and act on the note: file a task, summarize a link, review a journal entry, whatever your rules say.
4. Record the note as handled (a log file, not a move) so it isn't acted on twice.

The app already did the classifying, so the interesting work moves up a level: not "what is this note?" but "what should happen because of it?" Each example sketches starter actions per `type`; tune them to your own workflow.

### Anatomy of a triaged note

```markdown
---
captured: 2026-07-13T14:32:08Z
source: rapture-mac
type: voice-note
---

Rent is due on the 5th.
```

`type` is one of `voice-note`, `youtube-link`, `article-link`, `task`, `idea`, `journal` (the last three appear only with the AI tier on). When formatting changed the body, the verbatim dictation is preserved under a `## Raw` section. Attachments live in a sibling folder named after the note, linked from an `Attachments:` footer. With the opt-in Link enrichment toggle, link notes also carry a `Media:` link to a fetched transcript or readable-text file in `Links/Media/`, and the note is renamed to the real video or page title.

### The root is an inbox

Raw `.txt` files no longer accumulate at the folder root. Any `.txt` dropped there (hand-drops, sync deliveries) is converted to a Markdown note within seconds and then deleted. Don't build consumers that race the app for root `.txt` files.

### Raw mode

If you prefer the old contract — `.txt` files at the root, named `<ISO-timestamp>.txt`, never converted — flip **Settings → Triage → Filing** to **"Raw text files, no triage"**. Each example notes where its old root-`.txt` instructions still apply; they apply only in that mode.

## Contributing a new example

Pick whatever agent or tool you're already using, drop a self-contained example in `examples/<tool-name>/`, and open a PR. The bar is low:

- a working SKILL.md / config / script
- a one-paragraph README explaining install and "where does this file go"
- a note on what reply channel (if any) it uses

The goal isn't complete coverage. It's to give users one less reason to think "Rapture only works with X." The folder of triaged Markdown is the contract; everything else is glue.
