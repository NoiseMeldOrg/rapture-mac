# Generic CLI consumer

A pure shell script that pipes each new triaged Markdown note in your Rapture notes folder through whatever LLM CLI you set. Works with anything that reads stdin and writes to stdout.

Rapture for Mac has already done the classifying: each capture lands as a `.md` note with YAML frontmatter (`captured`, `type`, optional `source` and `raw_media`) filed under `Notes/`, `Links/`, `Tasks/`, `Ideas/`, or `Journal/`. The script walks those subfolders, skips `Links/Media/` artifacts and anything already in its processed log, and hands each new note (frontmatter included, so your prompt can key off `type`) to your LLM.

## Usage

```sh
chmod +x process-notes.sh

# Claude Code
LLM_CMD="claude -p" ./process-notes.sh

# OpenAI's gpt CLI (if you have one installed)
LLM_CMD="gpt"       ./process-notes.sh

# Google Gemini CLI
LLM_CMD="gemini -p" ./process-notes.sh
```

Responses land in `responses/YYYY-MM/<note-name>.response.md` inside the notes folder. The source notes stay where the app filed them; the script records each handled note in `responses/processed.log` so it isn't processed twice.

## Override the notes folder

```sh
NOTES_DIR="$HOME/Dropbox/Rapture Notes" LLM_CMD="claude -p" ./process-notes.sh
```

## Schedule it

The script is one-shot. Wrap with launchd, cron, or the scheduler of your choice for periodic runs — a `StartInterval` launchd job whose `ProgramArguments` invoke this script, with `LLM_CMD` set via `EnvironmentVariables`, is the usual macOS shape.

## What it doesn't do

- No routing, no per-type logic. Each note gets the same generic prompt. The frontmatter is in the input, so your `LLM_CMD` prompt can branch on `type` if you want.
- No reply channel. Responses go to disk only.
- No catch-up cap. Will dutifully process 1,000 notes if 1,000 are waiting.

If you want any of that, fork the script or pair it with a richer example (`../claude-code/`, `../openclaw/`, `../hermes/`).

## Raw mode

If you've flipped **Settings → Triage → Filing** to **"Raw text files, no triage"**, there are no triaged subfolders: captures are `<ISO-timestamp>.txt` files at the folder root, never converted. This script's `.md` loop finds nothing in that mode. The old contract still works, though — change the loop to glob `"$NOTES_DIR"/*.txt` and move each processed file into `processed/YYYY-MM/` (the move is the watermark, so no log is needed). That root-`.txt` approach applies only in raw mode; in the default mode the app converts and deletes root `.txt` files within seconds, and a script racing it would lose.
