# Rapture for Mac

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/NoiseMeldOrg/rapture-mac?display_name=tag&sort=semver)](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest)
[![Network: opt-in only](https://img.shields.io/badge/network-opt--in%20only-success)](./PRIVACY.md)

A tiny menu-bar companion to the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app. Files your voice captures as Markdown notes — titled, dated, and sorted into `Notes/` and `Links/` — in a folder of your choice, so voice-captured thoughts land where any AI assistant (Claude, ChatGPT, Gemini, a local Llama) can read them. Notes arrive two ways: Siri-dictated iMessages, and captures the Rapture iPhone app sends through your own iCloud. (Prefer raw timestamped `.txt` files? Flip **Settings → Triage** to raw mode.)

**Apache-2.0. Local-only. Vendor-neutral. The folder is the only integration surface.**

## Motivating flow

Your phone is across the room, locked, untouched. You say:

> *"Hey Siri, send a text to me saying rent is due on the 5th."*

Siri transcribes and sends. No unlock, no app open, no taps. Rapture for Mac sees the message arrive, writes `Notes/2026-05-16 Rent is due on the 5th.md` to a folder you picked (local, Dropbox, Drive, all just paths), and replies in the chat:

> *✅ Saved*

That's the whole transaction. The defining property: **the iPhone side is fully hands-free from a locked device.** It's the one Apple-permitted voice path that works without unlock. Shortcuts can't do it from the lock screen. The Action Button needs the phone in hand. The Notes app needs unlock.

The second path starts in the Rapture iPhone app. Turn on the **Rapture Mac** destination there and every capture you make in the app is handed to your own iCloud. Your Mac files it into the same folder the next time it is awake and syncing. No pairing, no server, no manual steps. See [Capture from the Rapture iPhone app](#capture-from-the-rapture-iphone-app).

## Install

1. Download the latest DMG from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest).
2. Open the DMG, drag **Rapture.app** into `/Applications`.
3. Launch the app. There's no Dock icon. Look for the Rapture glyph in the menu bar at the top of the screen.

Once installed, Rapture keeps itself up to date — it checks for new releases and prompts you to install them in place (verified against an EdDSA signature and Apple's notarization first). Turn it off in **Settings → About**, or update on demand via **Check for Updates…** in the menu. It's the app's only network use unless you opt into BYO-key AI triage; see [PRIVACY.md](./PRIVACY.md).

### First-run walkthrough

The app will guide you through two macOS permissions. Both are needed for iMessage capture; captures from the Rapture iPhone app work without either, so relayed notes file even while this walkthrough is still pending.

1. **Full Disk Access**: needed to read `~/Library/Messages/chat.db`. The app opens a sheet with an **Open System Settings** button that deep-links to the right pane. Toggle Rapture for Mac on. (If you don't see it in the list, click `+` and add it manually.) The sheet closes automatically once access is granted.
2. **Automation → Messages**: needed for the `✅ Saved` reply. The first time the app tries to reply, you'll see a one-time pre-prompt explaining what's about to happen, then macOS shows its own permission dialog. Click **OK**.
3. Send yourself an iMessage from another device on the same iCloud account: *"Hey Siri, text me, this is a test."*
4. Within about a second, a Markdown note appears under `~/Documents/Rapture Notes/Notes/` (the default folder; you can change it under **Settings → General**).
5. Within another second, you see `✅ Saved` in your iMessages thread on your phone. That's the audible-on-iPhone confirmation that the capture landed.

That's the whole product. Everything else (allowlist, reply modes, pause/resume) is in the menu-bar popover and the Settings window.

## Capture from the Rapture iPhone app

If you use the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app, your Mac can file those captures too:

1. In the iPhone app, open **Settings → Destinations → Rapture Mac** and turn it on.
2. Make sure both devices are signed into the same Apple account with iCloud Drive enabled.
3. Capture a note. It is handed to your iCloud and lands in your Rapture Notes folder the next time this Mac is awake and syncing.

How it works: the iPhone writes each capture into a hidden relay folder inside Rapture's own iCloud container (on the Mac, `~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay/`). macOS syncs that folder down; this app watches the synced copy, files each arrival, and deletes the relay copy. An empty relay means everything has been delivered. The app adds no network code for any of this. It reads a local folder; the operating system moves the bytes. Relay captures transit your own iCloud, the same way iMessage captures already transit Apple's iMessage infrastructure. See [PRIVACY.md](./PRIVACY.md).

Worth knowing:

- **No Full Disk Access needed** for this source. FDA is only for reading your Messages history.
- **Note text arrives by default.** The audio recording rides along when you turn on the **Audio File** toggle in the iPhone app's Rapture Mac settings.
- **No "Saved" reply** for these captures; there is no chat thread to reply into. The menu-bar today count is the arrival confirmation.
- **The Mac-side toggle** lives in **Settings → General → iPhone App**, on by default. It's a no-op until the relay folder first appears.
- **One watching Mac per iCloud account.** Several Macs on the same account would race to file the same arrivals. Documented limitation, not supported in v1.

## Using your captures

The folder is the entire integration surface. The captures are plain Markdown files with a small YAML header (`captured`, `source`, `type`, `raw_media`) — or raw `.txt` files if you choose raw mode in **Settings → Triage**. The folder can live on an external drive (an Obsidian vault on an SSD, say): while the drive is unplugged, new captures queue inside the app and the menu bar shows "Destination offline — N queued"; plug it back in and they file automatically, in order, with their original capture times. You can:

- **Use them manually** when you're back at your computer. Open the folder, triage by hand, file what matters.
- **Hand them off to an AI agent or assistant** to read and process automatically, according to your own rules.

Starter configs for the automated path live in [`examples/`](./examples):

- [`examples/claude-code/`](./examples/claude-code) — `CLAUDE.md` routing rules plus a one-line installer for a `SessionStart` hook that surfaces pending notes whenever you next open Claude Code
- [`examples/openclaw/`](./examples/openclaw) — OpenClaw skill that watches the folder; default reply via Telegram (Rapture already owns the iMessage layer)
- [`examples/hermes/`](./examples/hermes) — Hermes Agent skill, schedules via built-in cron, default reply via Telegram
- [`examples/cli/`](./examples/cli) — vendor-neutral shell script that pipes each note into any LLM CLI

Pick whichever agent you already use. Rapture doesn't care.

## v1 scope

- **Two capture sources, no server.** The iMessage source polls `~/Library/Messages/chat.db` once per second, decodes message text (including the binary `attributedBody` blob that iOS 16+ uses for Siri-dictated messages), filters to your self-chat plus a user-managed allowlist, writes one Markdown note per message (with attachments in a sibling folder), and replies via AppleScript through Messages.app. The relay source watches the synced iCloud relay folder and files whatever the Rapture iPhone app sent. The built-in triage engine also converts any `.txt` dropped at the folder root — including notes captured before triage existed. Classification is deterministic by default (no AI, no network): bare links file into `Links/`, everything else into `Notes/`. An optional **AI triage** toggle (off by default, **Settings → Triage**) refines voice notes into `Tasks/`, `Ideas/`, and `Journal/` with smart titles — using Apple Intelligence on-device when available, or your own Anthropic API key otherwise; the verbatim dictation is always kept in the note, and captures file instantly without AI whenever it's off or unavailable.
- **No cloud mode in v1.** A future v1.1 adds a Sendblue path via VPS relay. An on-Mac webhook listener would die whenever the Mac sleeps, so we won't ship one.

### Out of scope

A short list of things you might expect but don't get; for the full rationale see [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md):

- Group chat capture
- In-app browsing / search / preview (the folder *is* the UI; use Finder, Spotlight, ripgrep, or your AI assistant)
- Built-in AI *consumption* of your notes (the folder stays vendor-neutral by design — the optional AI triage toggle only classifies and titles captures on the way in; any LLM can still read the output)
- Audio capture of Siri-dictated iMessages (text only; that audio stays on your iPhone). Captures sent from the Rapture iPhone app *can* include the audio file when you turn that on in the iOS app.
- Mac App Store distribution (structurally impossible; see [shape.md](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md))
- Analytics or telemetry (the only outbound network calls are the optional, opt-out auto-update check and the opt-in BYO-key AI engine — see [PRIVACY.md](./PRIVACY.md))

## Why the app isn't sandboxed

The app asks for **Full Disk Access** and **Automation → Messages**, which are unusual permissions on macOS. That's not a corner being cut. It's the only way the product can work:

- **Reading `~/Library/Messages/chat.db` requires Full Disk Access**, period. No entitlement gets a sandboxed app into that file; this is an Apple privacy guarantee, not a configuration option. Without that read, the app has nothing to capture.
- **Sending the `✅ Saved` reply requires spawning `osascript` and controlling Messages.app**, both of which the Mac App Store sandbox forbids for arbitrary apps.

So the app ships outside the sandbox by structural necessity, which is also why it isn't (and can't be) on the Mac App Store. In exchange, the code carries no telemetry and no network calls beyond the two opt-in/opt-out features above (auto-update, BYO-key AI). See [PRIVACY.md](./PRIVACY.md) for the full posture and how to verify it yourself with two shell commands.

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
