# OpenClaw consumer

**You don't need `imsg` (unless you want OpenClaw to reply via iMessage).** Rapture for Mac already owns the iMessage capture layer (it reads inbound and sends the `✅ Saved` reply). OpenClaw consumes the notes folder as a file source.

Rapture also owns the classifying: every capture lands as a Markdown note with YAML frontmatter, filed under `Notes/`, `Links/`, `Tasks/`, `Ideas/`, or `Journal/`. The skill reads each new note's frontmatter and acts on it, then reports a summary.

This example sends processing summaries via Telegram, which works hands-free from a locked iPhone via standard push notifications. For other channels (Discord, Signal, Slack, etc.), swap the `--channel` and `--to` arguments below.

## Setup

1. **Install OpenClaw** (skip if already installed):
   ```sh
   curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install.sh | bash
   ```

2. **Install the skill:**
   ```sh
   mkdir -p ~/.openclaw/skills/rapture-watch
   cp SKILL.md ~/.openclaw/skills/rapture-watch/
   ```

3. **Configure a Telegram channel** (skip if you already have one). Minimum: create a bot via @BotFather and add the token to your OpenClaw config. See <https://docs.openclaw.ai/channels/telegram>.

4. **Schedule it** with OpenClaw's cron. Note the explicit `--announce --channel --to` — isolated cron jobs default to `announce` delivery, but without an explicit channel and target the route resolves from main/current session (probably not what you want for an unattended job):
   ```sh
   openclaw cron add \
     --name "rapture-watch" \
     --every "5m" \
     --session isolated \
     --message "Run the rapture-watch skill against your Rapture notes folder." \
     --announce --channel telegram --to "$YOUR_TELEGRAM_CHAT_ID"
   ```

5. **Verify:**
   ```sh
   openclaw cron list
   openclaw cron run <job-id> --wait
   ```

   The forced run should report any triaged `.md` notes not yet in the skill's processed log. If you have none, dictate a Siri test note to yourself and re-run — Rapture files it as a `.md` note within seconds.

## How the notes folder is resolved

The skill reads the current notes-folder path in this order:

1. **Rapture's sidecar file** at `~/Library/Application Support/Rapture for Mac/output-folder.path` (written by the menu-bar app when the user picks or changes the output folder in Settings → General).
2. **`~/Documents/Rapture Notes/`**, the default.

This means changing your folder in Rapture's Settings is picked up automatically without needing to edit the skill or re-create the cron job.

## Raw mode

If you prefer the old contract — plain `<ISO-timestamp>.txt` files at the folder root, no conversion — flip Rapture's **Settings → Triage → Filing** to **"Raw text files, no triage"**. The skill's raw-mode section covers that case (classify each root `.txt` yourself, move to `processed/YYYY-MM/` when done). Those root-`.txt` instructions apply only in raw mode; in the default mode the app converts root `.txt` drops within seconds.

## Reply via iMessage instead (advanced)

OpenClaw has a native iMessage channel (`docs/channels/imessage.md`). It uses Steipete's `imsg` CLI:

```sh
brew install steipete/tap/imsg
```

Then configure `channels.imessage` in your OpenClaw config and swap `--channel telegram` for `--channel imessage --to "imessage:+15551234567"` in the cron command above. OpenClaw's `is_from_me=true` filter and Rapture's own echo guard coexist without conflict — both apps' outbound sends are dropped by the other side's filters.

OpenClaw's iMessage channel also supports opt-in catch-up replay (`channels.imessage.catchup.enabled: true`), which replays inbound messages that landed in `chat.db` while the gateway was offline. Off by default; enable in your OpenClaw config if you want that behavior.
