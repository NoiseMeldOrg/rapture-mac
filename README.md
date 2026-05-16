# Rapture for Mac

A tiny menu-bar companion to the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app. Turns Siri-dictated iMessages into timestamped `.txt` files on disk, so voice-captured thoughts land in a folder you (and a personal AI assistant) can read later.

## Motivating flow

Your phone is across the room, locked, untouched. You say:

> *"Hey Siri, send a text to me saying rent is due on the 5th."*

Siri transcribes and sends — no unlock, no app open, no taps. Rapture for Mac sees the message arrive, writes `2026-05-16T14-32-08Z.txt` to a folder you picked (local, Dropbox, Drive — all just paths), and replies in the chat:

> *✓ Saved: 2026-05-16T14-32-08Z.txt*

That's the whole transaction. The defining property: **the iPhone side is fully hands-free from a locked device.**

## v1 scope

- **Local mode only.** Polls `~/Library/Messages/chat.db` once per second, decodes message text (including the binary `attributedBody` blob), filters to your self-chat plus a user-managed allowlist, writes one `.txt` per message (with attachments in a sibling folder), and replies via AppleScript through Messages.app.
- **No cloud mode in v1.** A future v1.1 adds a Sendblue path via VPS relay — not via an on-Mac webhook listener, which would die whenever the Mac sleeps.

## Status

In active development. See [`agent-os/specs/`](./agent-os/specs/) for the current spec and roadmap.

## Project layout

```
rapture-mac/
├── RaptureMac/              # Xcode project (Phase 2+)
├── agent-os/                # Product docs + specs
│   ├── product/             # mission, tech-stack, roadmap
│   └── specs/               # Per-feature specs
├── CLAUDE.md                # Claude Code project instructions
└── README.md                # This file
```

## Sibling repos

- [`rapture-ios`](https://github.com/NoiseMeldOrg/rapture-ios) — iOS app (the voice-capture-and-cloud-sync product)
- [`rapture-android`](https://github.com/NoiseMeldOrg/rapture-android) — Android app
- [`rapture-api-gateway`](https://github.com/NoiseMeldOrg/rapture-api-gateway) — Backend (Render.com)

## License

Private — internal NoiseMeld project.
