# Event-driven autonomous mode

The opposite trade-off from the [SessionStart hook](./README.md): instead of waiting for you to next open Claude Code, this fires a new `claude -p` invocation within ~1 second of each Siri-dictated note landing in your folder. Sub-second from "Hey Siri, text me…" to Claude actually doing something in your project directory.

The cost is that this uses `claude -p`, which on **June 15, 2026** moves to a separate "Agent SDK credit" pool: Pro $20/month, Max 5x $100/month, Max 20x $200/month, billed at API rates, no rollover. With `--model haiku` the workload runs at roughly $0.005 per invocation — the Pro credit covers around 4,000 notes a month, which is well past any plausible personal Siri output. But if you specifically picked Rapture because you wanted *zero* per-message cost, use the SessionStart hook instead.

## Who this is for

- You want immediate, autonomous action when a note lands (no "next time you open Claude" delay).
- You're comfortable with the Agent SDK credit budget at Haiku rates.
- You have a default project directory you want Claude to act in.
- You accept the security posture below.

## Security — read this before installing

The watcher runs `claude -p --permission-mode bypassPermissions`, which auto-approves every tool call without prompting. **Anyone who can write a `.txt` file to your notes folder can effectively run anything your user account can run** — `Bash`, `Read`, `Write`, `Edit`, `WebFetch`, and every MCP tool loaded by the project.

In practice the only writer is Rapture (driven by your Siri dictations), so the practical blast radius equals "whoever has momentary access to your unlocked iPhone." A prompt injection in the *content* of a note (or in a webpage the agent later fetches) could also chain Claude into destructive tool calls without you ever asking it to.

For personal use on a Mac you control with self-captured Siri notes, this is defensible. For anything else, it isn't. If you don't want this exposure, use the SessionStart hook in the main [README](./README.md) instead — it lets you approve actions in a live session before they run.

### Hardening you can do today

- Keep the notes folder on your internal disk (not on a shared cloud drive a co-worker could write to)
- Don't enable `IMESSAGE_ALLOW_SMS` in Rapture — SMS sender IDs are spoofable
- Watch `tail -f /tmp/rapture-notes-watch.err.log` for unexpected failures
- `bash Scripts/uninstall-claude-watch.sh` immediately if you suspect anything

## Install

```sh
brew install fswatch jq
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/install-claude-watch.sh | bash
```

The script installs three things:

1. `~/.claude/scripts/rapture-notes-watch.sh` — a small `fswatch` loop that fires `claude -p --model haiku` against your project directory for each new `.txt` file.
2. `~/Library/LaunchAgents/com.user.rapture-notes-watch.plist` — a launchd job that keeps the loop running across reboots, sleep/wake, and crashes (launchd's `KeepAlive`).
3. Loads the launchd job immediately so it's live without a reboot.

Defaults: Claude runs from `$HOME`, calls `/opt/homebrew/bin/claude` with `--model haiku`, reads your notes folder via Rapture's sidecar (with fallback to `~/Documents/Rapture Notes/`).

### Project directory

By default Claude runs from your home directory, which is rarely what you want for "Siri tells Claude to refactor the auth middleware." Override at install time:

```sh
RAPTURE_CLAUDE_WORKDIR=~/Source/Repos/your-project \
  curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/install-claude-watch.sh | bash
```

…or edit `~/.claude/scripts/rapture-notes-watch.sh` after install and change the `WORKDIR=` line, then `launchctl unload` + `launchctl load` the plist to pick up the change.

### Different model

Edit the `--model` flag in the worker script. Sonnet is plausible for richer routing; Opus burns Agent SDK credit fast for this workload — usually overkill for classification.

## Verify

After install, dictate a Siri test note to yourself. Within a second or two you should see activity in:

```sh
tail -f /tmp/rapture-notes-watch.{out,err}.log
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/Scripts/uninstall-claude-watch.sh | bash
```

Removes the launchd plist and the worker script. Logs at `/tmp/rapture-notes-watch.{out,err}.log` are left in place.

## How it differs from the SessionStart hook

| | SessionStart hook | Event-driven watcher (this file) |
|---|---|---|
| Latency | Whenever you next open Claude Code | <1 sec after the file lands |
| Cost | $0 (subscription pool) | ~$0.005/note at Haiku (Agent SDK credit pool) |
| Initiator | You opening Claude Code | The Mac, autonomously |
| Always-on | No | Yes (launchd supervises fswatch) |
| Setup | One install command | One install command + a project workdir choice |
| Best for | Power users who already use Claude Code many times a day for unrelated work | Users who want Siri-dictated thoughts to immediately become action |

Run one or the other, not both — they'd race on the same files.

## How it differs from the launchd plist that used to ship

Earlier versions of this repo shipped a launchd plist with `WatchPaths` that fired a fresh bash per folder change. This setup is structurally cleaner: launchd supervises a single long-running `fswatch` process, which is `fswatch`'s job to do well. `claude -p` fires per detected event, not per `WatchPaths` re-evaluation. Same behavior, fewer moving parts.
