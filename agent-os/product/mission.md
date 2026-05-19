# Product Mission

> Last Updated: 2026-05-16
> Version: 1.0.0

## Pitch

Three lengths. Pick the one that fits the context.

### 30-second pitch

Your iPhone is across the room, locked. You say *"Hey Siri, text me — rent is due on the 5th."* Two seconds later, that note is a `.txt` file in a folder on your Mac, waiting for whatever AI assistant you use to pick it up.

The trick: iMessage-to-self is the one Siri flow Apple permits from a locked iPhone. Shortcuts don't work locked. The Action Button needs the phone in hand. Notes needs unlock. We hijack the one path that works.

And the folder is the interface — Claude, ChatGPT, Gemini, anything that reads files can consume your captures. No SDK, no vendor lock-in. Speak from across the room, hand the note to whatever AI you want.

### One-line tagline

> Speak from a locked iPhone, get a file on your Mac, hand it to any AI.

### Two-sentence shop-window version

> Rapture for Mac turns Siri-dictated iMessages into timestamped `.txt` files in a folder your AI assistant can watch. It's the only voice-capture flow Apple permits from a locked iPhone, packaged as a polished menu-bar app.

## Target user

The same Rapture user, on a Mac signed into the same iCloud account as their iPhone. The Mac is the home base where notes accumulate; the iPhone is the always-available input device.

### Hero persona

**Voice-first thinker.** Lives at a desk. Phone usually within Siri earshot but rarely in hand. Wants ideas captured the instant they happen — including from a locked phone across the room — and wants those captures available as files for a downstream AI assistant to act on.

## Problems

### Voice notes are locked inside iMessages

Siri-driven dictation to iMessages already works beautifully from a locked iPhone. But the text sits in a chat thread — not in a folder, not searchable by tools, not pipeable into anything.

### Capture has to be trustworthy

A capture system that drops messages — even occasionally — is worse than no system at all, because users stop trusting it and stop dictating. Catch-up after the Mac was asleep or quit must be silent, correct, and auditable.

### Confirmation matters when you can't see the screen

If you dictated a note from across the room, you have no way to know it was captured until you walk back to the Mac. That breaks trust.

## Differentiators

- **True hands-free from a locked phone — structurally, not just by quality.** Siri's "send a text to me" is the only Apple-permitted path for voice capture from a locked iPhone. Shortcuts can't do it from the lock screen (validated 2026-05-16); the Action Button requires the phone in hand; the Notes app requires unlock. We hijack the one stock primitive Apple deliberately ships at the lock screen, and the Mac does all the background work. See `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md` for the architectural reasoning.
- **The folder is the integration surface.** `.txt` files in a folder you choose (local, Dropbox, Drive). Anything that reads files can consume them — Claude, ChatGPT, Gemini, a local Llama, a personal AI assistant watching the folder. The folder is the cross-LLM compatibility layer.
- **Catch-up is first-class.** Every missed message replays on launch with an audit summary so the user always knows the state.
- **In-thread confirmation.** `✓ Saved: <filename>` replies in the iMessage thread so the iPhone's standard message-received sound is the "it landed" signal.

## Integration model — folder as the universal interface

The output is intentionally trivial: one `.txt` file per captured message in a folder the user chose. No SDK, no protocol, no API, no Claude lock-in.

This means **any** LLM agentic system can consume the captures: Claude (Code or API), ChatGPT, Gemini, a local Llama, a Python script, a shell pipeline, an iOS Shortcut watching the iCloud sync of that folder. If it can read a file, it works. The folder is the cross-LLM compatibility layer.

This is a hard product commitment, not an aspiration. Any future feature that would couple captures to a specific AI vendor or transport protocol is out of scope.

## Distribution

**Apache-2.0 open source on GitHub at [`NoiseMeldOrg/rapture-mac`](https://github.com/NoiseMeldOrg/rapture-mac).** Anyone can read, build, fork, or contribute. End users install a pre-built Developer ID-signed + notarized DMG from GitHub Releases — drag-and-drop, no terminal, no Homebrew, no developer tooling required.

## Out of scope for v1

- Cloud mode (Sendblue) — deferred to v1.1 with a VPS-relay architecture, never an on-Mac webhook
- Group chats
- Contacts framework name resolution
- Edit / unsend tracking
- Mac App Store distribution (structurally impossible — see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`)
- Auto-update
- Analytics
- **Routing Rapture iOS dictations into the same folder.** A sibling-repo concern, not rapture-mac scope. The cleaner architecture is to extend [`claude-channel-rapture`](https://github.com/NoiseMeldOrg/claude-channel-rapture) with a file-output mode (running as `launchd` for always-on delivery) or to add server-side iCloud/Dropbox push in `rapture-api-gateway`. Either keeps gateway-connected logic out of the Mac app, which respects the spec's "no networking" boundary.
