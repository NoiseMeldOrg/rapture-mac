# Hermes Agent consumer

Hermes has no iMessage gateway on macOS. This example uses Telegram for replies, which works hands-free from a locked iPhone via standard push notifications. To use Signal, Discord, Slack, WhatsApp, or another supported channel, see <https://hermes-agent.nousresearch.com/docs/user-guide/messaging>.

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

4. **Schedule it** with Hermes cron:
   ```sh
   hermes cron create "every 5m" "Run the rapture-watch skill against ~/Documents/Rapture Notes/" --skill rapture-watch
   ```

   The cron job's output is auto-delivered to whichever messaging target you've configured as default.

5. **Verify** by dictating a Siri test note to yourself. Within the next cron tick, a Telegram message summarizing the processed note should arrive.

## Why not iMessage

Hermes doesn't ship an iMessage gateway. You can write a custom skill that shells out to `osascript` to send via Messages.app, but at that point you're partially reinventing what Rapture for Mac already does on the send side.

If iMessage replies for processed notes matter to you, **OpenClaw is the better fit** — see [`../openclaw/`](../openclaw/).

Hermes's strength is the rich skill format and the built-in self-improving loop. If that matters more than the messaging channel, this example is a clean starting point.
