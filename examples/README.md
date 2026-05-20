# Examples

The folder is the entire integration surface. Anything that reads files can consume a Rapture notes folder. These examples are starter configs for the agents users most commonly arrive with.

| Agent | What's here | Setup time | Default reply channel |
|---|---|---|---|
| [Claude Code](./claude-code/) | `CLAUDE.md` routing rules; manual, Desktop scheduled task, or launchd | ~5 min | None (writes response files) |
| [OpenClaw](./openclaw/) | SKILL.md + setup notes | ~15 min | Telegram |
| [Hermes Agent](./hermes/) | SKILL.md + setup notes | ~15 min | Telegram |
| [Generic CLI](./cli/) | POSIX shell script | ~2 min | None (writes response files) |

None of these examples are tested against a running install. They're written from current agent documentation. If you find a discrepancy between an example and what your install actually does, please open an issue or PR.

## What every example does

The same shape:

1. Watch `~/Documents/Rapture Notes/` (or your configured Rapture output folder) for new `.txt` files.
2. Process each new note: classify it, take action, optionally reply on whatever channel you've configured.
3. Move the processed file to `processed/YYYY-MM/` so it isn't picked up again.

The interesting work is in step 2's routing logic. Each example sketches a starter rubric; tune it to your own workflow.

## Contributing a new example

Pick whatever agent or tool you're already using, drop a self-contained example in `examples/<tool-name>/`, and open a PR. The bar is low:

- a working SKILL.md / config / script
- a one-paragraph README explaining install and "where does this file go"
- a note on what reply channel (if any) it uses

The goal isn't comprehensive coverage. It's to give users one less reason to think "Rapture only works with X." The folder of `.txt` files is the contract; everything else is glue.
