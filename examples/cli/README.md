# Generic CLI consumer

A pure shell script that processes each new `.txt` file in your Rapture notes folder through whatever LLM CLI you set. Works with anything that reads stdin and writes to stdout.

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

Responses land next to the source as `<original-name>.response.md` inside `processed/YYYY-MM/`. The source `.txt` moves into the same folder.

## Override the notes folder

```sh
NOTES_DIR="$HOME/Dropbox/Rapture Notes" LLM_CMD="claude -p" ./process-notes.sh
```

## Schedule it

The script is one-shot. Wrap with launchd, cron, or the scheduler of your choice for periodic runs. See [`../claude-code/com.user.rapture-processor.plist`](../claude-code/com.user.rapture-processor.plist) for a launchd example that's easy to adapt: change `ProgramArguments` to invoke this script instead of `claude -p`, and set `LLM_CMD` via `EnvironmentVariables`.

## What it doesn't do

- No classification, no routing, no per-category logic. Each note gets the same generic prompt.
- No reply channel. Responses go to disk only.
- No catch-up cap. Will dutifully process 1,000 notes if 1,000 are waiting.

If you want any of that, fork the script or pair it with a richer example (`../claude-code/`, `../openclaw/`, `../hermes/`).
