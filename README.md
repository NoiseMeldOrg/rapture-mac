# Rapture for Mac

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/NoiseMeldOrg/rapture-mac?display_name=tag&sort=semver)](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest)
[![Network: zero outbound](https://img.shields.io/badge/network-zero%20outbound-success)](./PRIVACY.md)

A tiny menu-bar companion to the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app. Turns Siri-dictated iMessages into timestamped `.txt` files in a folder of your choice, so voice-captured thoughts land where any AI assistant (Claude, ChatGPT, Gemini, a local Llama) can read them.

**Apache-2.0. Local-only. Vendor-neutral. The folder is the only integration surface.**

## Motivating flow

Your phone is across the room, locked, untouched. You say:

> *"Hey Siri, send a text to me saying rent is due on the 5th."*

Siri transcribes and sends. No unlock, no app open, no taps. Rapture for Mac sees the message arrive, writes `2026-05-16T14-32-08Z.txt` to a folder you picked (local, Dropbox, Drive, all just paths), and replies in the chat:

> *✓ Saved: 2026-05-16T14-32-08Z.txt*

That's the whole transaction. The defining property: **the iPhone side is fully hands-free from a locked device.** It's the one Apple-permitted voice path that works without unlock. Shortcuts can't do it from the lock screen. The Action Button needs the phone in hand. The Notes app needs unlock.

## Install

1. Download the latest DMG from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest).
2. Open the DMG, drag **Rapture.app** into `/Applications`.
3. Launch the app. There's no Dock icon. Look for the `text.bubble` glyph in the menu bar at the top of the screen.

### First-run walkthrough

The app will guide you through two macOS permissions. Both are required.

1. **Full Disk Access**: needed to read `~/Library/Messages/chat.db`. The app opens a sheet with an **Open System Settings** button that deep-links to the right pane. Toggle Rapture for Mac on. (If you don't see it in the list, click `+` and add it manually.) The sheet closes automatically once access is granted.
2. **Automation → Messages**: needed for the `✓ Saved` reply. The first time the app tries to reply, you'll see a one-time pre-prompt explaining what's about to happen, then macOS shows its own permission dialog. Click **OK**.
3. Send yourself an iMessage from another device on the same iCloud account: *"Hey Siri, text me, this is a test."*
4. Within about a second, a `.txt` file appears in `~/Documents/Rapture Notes/` (the default folder; you can change it under **Settings → General**).
5. Within another second, you see `✓ Saved: <filename>.txt` in your iMessages thread on your phone. That's the audible-on-iPhone confirmation that the capture landed.

That's the whole product. Everything else (allowlist, reply modes, pause/resume) is in the menu-bar popover and the Settings window.

## Using your captures

The folder is the entire integration surface. The captures are plain `.txt` files. You can:

- **Use them manually** when you're back at your computer. Open the folder, triage by hand, file what matters.
- **Hand them off to an AI agent or assistant** to read and process automatically, according to your own rules.

Starter configs for the automated path live in [`examples/`](./examples):

- [`examples/claude-code/`](./examples/claude-code) — `CLAUDE.md` routing rules, with three trigger options: manual `cd && claude`, Claude Code Desktop scheduled task, or a launchd plist for headless `claude -p`
- [`examples/openclaw/`](./examples/openclaw) — OpenClaw skill that watches the folder; default reply via Telegram (Rapture already owns the iMessage layer)
- [`examples/hermes/`](./examples/hermes) — Hermes Agent skill, schedules via built-in cron, default reply via Telegram
- [`examples/cli/`](./examples/cli) — vendor-neutral shell script that pipes each note into any LLM CLI

Pick whichever agent you already use. Rapture doesn't care.

## v1 scope

- **Local mode only.** Polls `~/Library/Messages/chat.db` once per second, decodes message text (including the binary `attributedBody` blob that iOS 16+ uses for Siri-dictated messages), filters to your self-chat plus a user-managed allowlist, writes one `.txt` per message (with attachments in a sibling folder), and replies via AppleScript through Messages.app.
- **No cloud mode in v1.** A future v1.1 adds a Sendblue path via VPS relay. An on-Mac webhook listener would die whenever the Mac sleeps, so we won't ship one.

### Out of scope

A short list of things you might expect but don't get; for the full rationale see [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md):

- Group chat capture
- In-app browsing / search / preview (the folder *is* the UI; use Finder, Spotlight, ripgrep, or your AI assistant)
- Built-in AI integration (vendor-neutral by design)
- Audio capture of the original dictation (text only; the audio stays on your iPhone)
- Mac App Store distribution (structurally impossible; see [shape.md](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md))
- Auto-update
- Analytics or telemetry (zero outbound network calls in v1)

## Why the app isn't sandboxed

The app asks for **Full Disk Access** and **Automation → Messages**, which are unusual permissions on macOS. That's not a corner being cut. It's the only way the product can work:

- **Reading `~/Library/Messages/chat.db` requires Full Disk Access**, period. No entitlement gets a sandboxed app into that file; this is an Apple privacy guarantee, not a configuration option. Without that read, the app has nothing to capture.
- **Sending the `✓ Saved` reply requires spawning `osascript` and controlling Messages.app**, both of which the Mac App Store sandbox forbids for arbitrary apps.

So the app ships outside the sandbox by structural necessity, which is also why it isn't (and can't be) on the Mac App Store. In exchange, the code carries no network calls, no telemetry, and only one third-party dependency. See [PRIVACY.md](./PRIVACY.md) for the full posture and how to verify it yourself with two shell commands.

## Verify the download

Before opening the DMG:

```sh
xcrun stapler validate ~/Downloads/Rapture-*.dmg
spctl --assess --type install ~/Downloads/Rapture-*.dmg
```

Both should succeed. The DMG is Developer ID signed (team `P8PLTH44DF`) and Apple-notarized. See [SECURITY.md](./SECURITY.md) for full details and how to report issues.

## Build from source

```sh
xcodebuild \
  -derivedDataPath /tmp/RaptureMacDerived \
  -project RaptureMac/RaptureMac.xcodeproj \
  -scheme RaptureMac \
  -configuration Debug \
  build test
```

All tests should pass. See [CONTRIBUTING.md](./CONTRIBUTING.md) for the longer walkthrough, the `_build_plan/` directory for the milestone-by-milestone build log, and `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/` for the canonical technical spec.

## Sibling repos

- [`rapture-ios`](https://github.com/NoiseMeldOrg/rapture-ios): iOS app (the voice-capture-and-cloud-sync product)
- [`rapture-android`](https://github.com/NoiseMeldOrg/rapture-android): Android app
- [`rapture-api-gateway`](https://github.com/NoiseMeldOrg/rapture-api-gateway): Backend (Render.com)
- [`claude-channel-rapture`](https://github.com/NoiseMeldOrg/claude-channel-rapture): Claude Code plugin that pairs with Rapture iOS over a real-time channel

## License

Apache-2.0. See [LICENSE](./LICENSE).
