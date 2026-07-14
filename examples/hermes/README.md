# Hermes Agent consumer

This example sends processing summaries via Telegram, which works hands-free from a locked iPhone via standard push notifications. To use Signal, Discord, Slack, WhatsApp, or another supported channel, see <https://hermes-agent.nousresearch.com/docs/user-guide/messaging>.

Rapture for Mac triages every capture itself: each one lands as a Markdown note with YAML frontmatter, filed under `Notes/`, `Links/`, `Tasks/`, `Ideas/`, or `Journal/` in the notes folder. The skill doesn't classify anything — it reads each new note's frontmatter and acts on it, then reports a summary.

## Setup

1. **Install Hermes Agent** (skip if already installed):
   ```sh
   curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
   ```

2. **Install the skill:**
   ```sh
   mkdir -p ~/.hermes/skills/rapture-watch
   cp SKILL.md ~/.hermes/skills/rapture-watch/
   ```

3. **Configure a Telegram gateway** (skip if you already have one). Minimum: create a bot via @BotFather and add the token to your Hermes config. See <https://hermes-agent.nousresearch.com/docs/user-guide/messaging>.

4. **Schedule it** with Hermes cron. Note the explicit `--deliver telegram` — Hermes' default delivery target is `local` (the CLI), so without it your processing summary won't reach Telegram:
   ```sh
   hermes cron create "every 5m" "Run the rapture-watch skill against your Rapture notes folder." --skill rapture-watch --deliver telegram
   ```

5. **Verify** by dictating a Siri test note to yourself. Rapture files it as a `.md` note within seconds; within the next cron tick, a Telegram message summarizing the processed note should arrive.

## How the notes folder is resolved

The skill reads the current notes-folder path in this order:

1. **Rapture's sidecar file** at `~/Library/Application Support/Rapture for Mac/output-folder.path` (written by the menu-bar app when the user picks or changes the output folder in Settings → General).
2. **`~/Documents/Rapture Notes/`**, the default.

This means changing your folder in Rapture's Settings is picked up automatically without needing to edit the skill or re-create the cron job.

## Raw mode

If you prefer the old contract — plain `<ISO-timestamp>.txt` files at the folder root, no conversion — flip Rapture's **Settings → Triage → Filing** to **"Raw text files, no triage"**. The skill's raw-mode section covers that case (classify each root `.txt` yourself, move to `processed/YYYY-MM/` when done). Those root-`.txt` instructions apply only in raw mode; in the default mode the app converts root `.txt` drops within seconds.

## Reply via iMessage instead

Hermes ships a first-party iMessage skill (`skills/apple/imessage/SKILL.md`) that uses Steipete's `imsg` CLI. To send your processing summary via iMessage instead of Telegram, swap `--deliver telegram` for the appropriate iMessage delivery target (see the Hermes messaging docs) and ensure `imsg` is installed:

```sh
brew install steipete/tap/imsg
```

Both Rapture's own `✅ Saved` confirmation and Hermes' iMessage send coexist without conflict — Rapture's `is_from_me=true` filter drops Hermes' outbound, and Hermes uses its own echo handling.

## Why a separate consumer at all

Hermes' strength here is the rich skill format, the cron scheduler with multi-channel delivery, and the self-improving loop. If you'd rather keep everything in one Claude Code session via a hook, see [`../claude-code/`](../claude-code/) — that's the lowest-friction setup. Hermes is the right pick if you want processing summaries delivered to a messaging channel that isn't iMessage (or you already use Hermes for other things).
