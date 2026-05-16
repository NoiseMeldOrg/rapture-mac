# Product Mission

> Last Updated: 2026-05-16
> Version: 1.0.0

## Pitch

Rapture for Mac is a tiny menu-bar companion to the Rapture iOS app that turns Siri-dictated iMessages into timestamped `.txt` files on disk. The motivating flow: your phone is across the room, locked, untouched — you say *"Hey Siri, send a text to me saying rent is due on the 5th"* — and the note lands in a folder on your Mac that you (and a personal AI assistant) can review later.

The whole point is to make voice-captured thoughts available **without ever touching the phone**.

## Users

### Primary Customer

The same Rapture user, but on a Mac that's awake and signed into the same iCloud account as the iPhone. The Mac is the "home base" where notes accumulate; the iPhone is the always-available input device.

### User Persona

**Michael, the Voice-First Thinker** (the user this app was shaped for)
- **Context:** Lives at a desk with a Mac. Has an iPhone usually within Siri earshot but rarely in hand. Wants ideas captured the instant they happen — including from a locked phone across the room.
- **Pain points:** Existing voice notes apps require unlock + open + tap. The Apple Notes / Reminders flow via Siri works but doesn't deposit text into a folder a personal AI assistant can watch.
- **Goals:** Speak an idea → the idea is on disk in seconds → an AI assistant decides what to do with it (route to tasks, draft a reply, file under a project).

## The Problem

### Voice notes are locked inside iMessages

iPhones already do beautiful Siri-driven message dictation — including to yourself, from a locked device. The text exists in iCloud. But it sits in a chat thread, not in a folder, not searchable by tools, not pipeable into anything.

**Our solution:** Watch the local `chat.db` (which iCloud syncs continuously when the Mac is awake), pull matching messages, and write each one to disk as a flat `.txt`. The folder becomes the integration surface.

### Capture has to be trustworthy

A capture system that drops messages — even occasionally — is worse than no system at all, because users stop trusting it and stop dictating. Catch-up after the Mac was asleep / quit must be silent, correct, and auditable.

**Our solution:** Persistent watermark of last-seen `ROWID`. On every launch, replay every message past the watermark through the same pipeline as steady-state captures. Send a single summary iMessage telling the user how many notes landed.

### Confirmation matters when you can't see the screen

If you dictated a note via Siri from across the room, you have no way to know it was captured until you walk back to the Mac. That breaks trust.

**Our solution:** Reply in the iMessage thread with `✓ Saved: <filename>` (or `✗ <one-line reason>` on failure). The phone makes the standard message-received sound — that's the audible confirmation that the note is on disk.

## Differentiators

### True hands-free from a locked phone

Unlike apps that require you to unlock + open them, this works entirely from Siri on a locked device. The Mac does all the work in the background.

### Folder is the integration surface

Unlike apps that lock notes inside their own UI / database, the output is just `.txt` files in a folder you choose. Anything that reads files can consume them — Dropbox, Google Drive, Spotlight, ripgrep, a personal AI assistant watching the folder, you.

### Catch-up is a first-class feature

Unlike polling apps that silently drop messages when offline, every missed message gets replayed on launch with an audit trail (summary reply) so the user always knows the state.

## Key Features

### Core capture

- **chat.db polling:** 1-second polling against `~/Library/Messages/chat.db` with persistent ROWID watermark.
- **AttributedBody decoding:** Falls back to the binary `attributedBody` blob when `text` is NULL (iOS 16+ messages).
- **Self-chat + allowlist:** Always captures messages to yourself. Optionally captures from a user-managed allowlist of contacts.
- **Attachments:** Photos/MMS copied into a sibling folder next to the `.txt`.

### Trust features

- **Atomic writes:** `.tmp` → `rename(2)` so cloud sync clients never pick up half-written files.
- **Catch-up after restart:** Every missed message replays through the pipeline on launch. Summary reply if 4+ messages caught up.
- **Echo guard:** Our own confirmation replies don't get re-captured as new notes.
- **Configurable reply verbosity:** All / Errors only / Off.

### Menu bar UX

- **At-a-glance status:** `Local: ✓ capturing | Today: 7 notes | Last: 2 min ago`
- **Pause / Resume:** One click to stop capturing without quitting.
- **Open notes folder:** Reveal in Finder.
- **Last error:** Most recent failure surfaces in the dropdown so you know if something's broken.

### Permissions UX

- **Full Disk Access prompt:** Clear onboarding sheet with deep-link to System Settings the first time chat.db access fails.
- **Automation → Messages prompt:** Pre-prompt explaining what's about to happen before the OS prompt fires.

## Out of scope (v1)

- Cloud mode (Sendblue / dedicated number / cloudflared / on-Mac webhook) — entirely deferred to v1.1 with a VPS-relay architecture
- Group chat support
- Contacts framework name resolution in the allowlist
- Edit / unsend tracking
- Mac App Store distribution
- Auto-update
- Two-way conversation with the personal-AI consumer of the folder (the AI runs independently against the folder)
