# Product Mission

> Last Updated: 2026-07-13
> Version: 2.0.0
> v2.0.0 records the triage-engine reversal: the app now processes captures in-app (deterministic triage by default, opt-in AI tier), and the neutrality commitment moved from "no processing" to "neutral output." See "Integration model" below and `agent-os/specs/2026-07-13-2230-triage-engine/shape.md`.

## Pitch

Three lengths. Pick the one that fits the context.

### 30-second pitch

Your iPhone is across the room, locked. You say *"Hey Siri, text me — rent is due on the 5th."* Two seconds later, that thought is a titled, dated Markdown note filed in the right folder on your Mac, waiting for you — or whatever AI assistant you use.

The trick: iMessage-to-self is the one Siri flow Apple permits from a locked iPhone. Shortcuts don't work locked. The Action Button needs the phone in hand. Notes needs unlock. We hijack the one path that works.

And the folder is the interface — Claude, ChatGPT, Gemini, anything that reads files can consume your notes. No SDK, no vendor lock-in. Speak from across the room; the note is already triaged when you get there.

### One-line tagline

> Speak from a locked iPhone, get a filed note on your Mac, hand it to any AI.

### Two-sentence shop-window version

> Rapture for Mac turns Siri-dictated iMessages into titled, classified Markdown notes in a folder you — or your AI assistant — can watch. It's the only voice-capture flow Apple permits from a locked iPhone, packaged as a polished menu-bar app that does the first-pass triage itself.

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
- **Built-in triage, neutral output.** Every capture becomes a titled, classified Markdown note the moment it lands — deterministic by default, refined by an opt-in AI tier (Apple Intelligence on-device, or the user's own Anthropic key). No scripts, no external automation, no account. The output stays plain files in a folder you choose (local, Dropbox, Drive, an Obsidian vault on an external SSD) — anything that reads files can consume them. The folder is the cross-LLM compatibility layer.
- **Catch-up is first-class.** Every missed message replays on launch with an audit summary so the user always knows the state. The destination can vanish (unplugged drive) without losing a capture.
- **In-thread confirmation.** `✅ Saved` replies in the iMessage thread so the iPhone's standard message-received sound is the "it landed" signal.

## Integration model — output neutrality

> **Documented reversal (2026-07-13).** v1.0.0 of this file committed to "no built-in AI/LLM integration" and "no in-app editing, tagging, or categorizing of captures" — the app was to be a dumb capture layer and downstream AI the whole brain. The triage engine deliberately reversed both: the app now does the first-pass processing itself (classification, titling, filing, optional AI refinement, optional link enrichment), because a capture tool that requires the user to wire up external automation before their notes are usable serves nobody. What replaced processing neutrality is **output neutrality**, defined below. Rationale and scope: `agent-os/specs/2026-07-13-2230-triage-engine/shape.md`.

The output is intentionally plain: one Markdown file per capture (YAML header, text body — or raw `.txt` in the escape-hatch mode), filed into ordinary folders. No SDK, no protocol, no API, no vendor lock-in on the way out.

This means **any** LLM agentic system can consume the notes: Claude (Code or API), ChatGPT, Gemini, a local Llama, a Python script, a shell pipeline, an iOS Shortcut watching the iCloud sync of that folder. If it can read a file, it works.

The hard commitment now: **processing may be smart, output must stay neutral.** The app may use opt-in AI to classify and title a capture on the way in; it must never produce output only a specific vendor's tool can read, and it must never *require* AI — with every toggle off, every capture still files deterministically as plain Markdown.

## Distribution

**Apache-2.0 open source on GitHub at [`NoiseMeldOrg/rapture-mac`](https://github.com/NoiseMeldOrg/rapture-mac).** Anyone can read, build, fork, or contribute. End users install a pre-built Developer ID-signed + notarized DMG from GitHub Releases — drag-and-drop, no terminal, no Homebrew, no developer tooling required.

## Out of scope

Shipped since v1.0.0 of this file (no longer out of scope): auto-update (Sparkle, v1.0.80), routing Rapture iOS dictations into the same folder (the iCloud relay source, v1.0.88), and in-app categorizing + built-in AI (the triage engine, 2026-07 — the documented reversal above).

Still out of scope:

- Cloud mode (Sendblue) — deferred to v1.1 with a VPS-relay architecture, never an on-Mac webhook
- Group chats
- Contacts framework name resolution
- Edit / unsend tracking
- Mac App Store distribution (structurally impossible — see `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`)
- Analytics
- **In-app browsing / search / preview of captured notes.** The folder *is* the UI. Consumption is via Finder, Spotlight, ripgrep, or the user's AI assistant — not via a built-in note browser.
- **Built-in AI *consumption* of notes.** The app classifies and titles captures on the way in; it never becomes the assistant that reads, answers from, or acts on the filed notes. That side stays vendor-neutral.
- **User-editable rules engine / custom taxonomies.** The deterministic tier's behavior is fixed; the classes are `Notes`/`Links`/`Tasks`/`Ideas`/`Journal`.
- **Bulk re-triage.** Triage happens once, at arrival; there is no "re-run triage on old notes" button.
- **Audio capture of Siri dictations.** Text only from iMessage. (Captures from the Rapture iPhone app can carry their audio file when enabled there.)
- **Multi-folder destinations.** One output folder per install. Source-splitting is a downstream concern for whatever AI consumes the folder.
- **Mac Notification Center pings on each capture.** The iMessage reply is the confirmation; a Mac notification would be redundant noise.
- **Encryption / password protection of captures.** Plain files only. Users who need encryption point the output folder at an encrypted volume (Cryptomator vault, FileVault home folder, etc.).
