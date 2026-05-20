# OpenClaw consumer

**You don't need `imsg`.** Rapture for Mac already owns the iMessage layer (captures inbound, sends the `✓ Saved` reply). OpenClaw consumes the notes folder as a file source, no Messages.app integration needed.

Default reply channel for this example is Telegram, which works hands-free from a locked iPhone via standard push notifications. The "phone is across the room" property that motivated Rapture is preserved end-to-end.

## Setup

1. **Install OpenClaw** (skip if already installed):
   ```sh
   curl -fsSL https://openclaw.ai/install.sh | bash
   ```

2. **Install the skill:**
   ```sh
   mkdir -p ~/.openclaw/skills/rapture-watch
   cp SKILL.md ~/.openclaw/skills/rapture-watch/
   ```

3. **Configure a Telegram gateway** (skip if you already have one). See <https://docs.openclaw.ai/channels/telegram>. The minimum is creating a bot via @BotFather and pasting the token into your OpenClaw config.

4. **Schedule it** with OpenClaw's cron:
   ```sh
   openclaw cron add \
     --name "rapture-watch" \
     --every "5m" \
     --session isolated \
     --message "Run the rapture-watch skill against ~/Documents/Rapture Notes/"
   ```

5. **Verify:**
   ```sh
   # List jobs to get the job ID (last column).
   openclaw cron list

   # Force a run synchronously.
   openclaw cron run <job-id> --wait
   ```

   The run should report any unprocessed `.txt` files. If you have none, dictate a Siri test note to yourself and re-run.

## Reply via iMessage instead (advanced)

If you specifically want OpenClaw to reply via iMessage rather than Telegram, two paths exist:

- **`imsg`** (OpenClaw's official iMessage gateway). Install per <https://docs.openclaw.ai/channels/imessage>. Uses helper-injection / private APIs; SIP-disable required for advanced features (reactions, edits, threading) but not for basic send.
- **Shell out to `osascript`** from a custom OpenClaw skill. Same mechanism Rapture itself uses for its `✓ Saved` confirmations. No Homebrew dependency:
  ```sh
  /usr/bin/osascript -e 'tell application "Messages" to send "your reply" to chat id "your-chat-guid"'
  ```

Either option works alongside Rapture without conflict: both Rapture's and OpenClaw's outbound sends show up in `chat.db` with `is_from_me=true`, which Rapture's filter drops. No echo cascade.
