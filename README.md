# Rapture for Mac

[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)
[![Release](https://img.shields.io/github/v/release/NoiseMeldOrg/rapture-mac?display_name=tag&sort=semver)](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest)
[![Network: opt-in only](https://img.shields.io/badge/network-opt--in%20only-success)](./PRIVACY.md)

A tiny menu-bar companion to the [Rapture iOS](https://github.com/NoiseMeldOrg/rapture-ios) app. Files your voice captures as Markdown notes — titled, dated, and sorted into `Notes/` and `Links/` (plus `Tasks/`, `Ideas/`, and `Journal/` with the optional AI tier, and `Meetings/` for meetings recorded in the iPhone app) — in a folder of your choice, so voice-captured thoughts land where any AI assistant (Claude, ChatGPT, Gemini, a local Llama) can read them. Notes arrive two ways: Siri-dictated iMessages, and captures the Rapture iPhone app sends through your own iCloud. (Prefer raw timestamped `.txt` files? Flip **Settings → Triage** to raw mode.)

**Apache-2.0. Local by default — every network feature is opt-in (or opt-out) and listed in [PRIVACY.md](./PRIVACY.md). Vendor-neutral output: the folder is the only integration surface.**

## Motivating flow

Your phone is across the room, locked, untouched. You say:

> *"Hey Siri, text me rent is due on the 5th."*

Siri transcribes and sends. No unlock, no app open, no taps. Rapture for Mac sees the message arrive, writes `Notes/2026-05-16 Rent is due on the 5th.md` to a folder you picked (local, Dropbox, Drive, all just paths), and replies in the chat:

> *✅ Saved*

That's the whole transaction. The defining property: **the iPhone side is fully hands-free from a locked device.** It's the one Apple-permitted voice path that works without unlock. Shortcuts can't do it from the lock screen. The Action Button needs the phone in hand. The Notes app needs unlock.

The second path starts in the Rapture iPhone app. Turn on the **Rapture Mac** destination there and every capture you make in the app is handed to your own iCloud. Your Mac files it into the same folder the next time it is awake and syncing. No pairing, no server, no manual steps. See [Capture from the Rapture iPhone app](#capture-from-the-rapture-iphone-app).

## Install

Wiring Rapture into an agentic setup? [docs/END-TO-END.md](./docs/END-TO-END.md) is the fast path: both capture paths from zero to a first note landing, then the folder contract your tooling reads.

**You'll need:** an Apple silicon Mac running macOS 14 (Sonoma) or later, signed into Messages with the same Apple ID as your iPhone. (The prebuilt DMG is Apple-silicon-only; Intel users can [build from source](#build-from-source).)

1. Download the latest DMG from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest).
2. Open the DMG and drag **Rapture.app** into `/Applications`, then eject the DMG.
3. Launch the app from `/Applications`. macOS asks once to confirm opening an app you downloaded — click **Open**. (The app is Developer ID-signed and notarized by Apple, so there's no warning to work around.)
4. There's no Dock icon. Look for the Rapture glyph in the menu bar at the top of the screen.

**Updating:** the app updates itself in place — it checks for new releases and prompts you to install (verified against an EdDSA signature and Apple's notarization first). Let it: an in-place update **keeps your permissions**. Manually drag-replacing the app bundle makes macOS forget its Full Disk Access grant, so you'd redo that permission step. Turn auto-check off in **Settings → About**, or update on demand via **Check for Updates…** in the menu. Update checks are the app's only network use unless you opt into BYO-key AI triage or link enrichment; see [PRIVACY.md](./PRIVACY.md).

### First-run walkthrough

The app will guide you through two macOS permissions. Both are needed for iMessage capture; captures from the Rapture iPhone app work without either, so relayed notes file even while this walkthrough is still pending.

1. **Full Disk Access**: needed to read `~/Library/Messages/chat.db`. The app opens a window with an **Open System Settings** button that goes straight to the right pane. Find **Rapture** in the list and turn it on. (Not in the list? Click `+` and add Rapture from your Applications folder.) macOS may then offer **Quit & Reopen**. Click it. If macOS doesn't ask, a **Reopen Rapture** button appears in the app's window a few seconds after you open System Settings. Either way the app has to restart, because a running app never sees a new grant. You do this once: the built-in updater keeps the grant from then on.
2. **Choose where notes go.** Once Full Disk Access is on, Rapture asks where your notes should go. It lists the Obsidian vaults it finds on your Mac and your synced folders (iCloud Drive, Dropbox, Google Drive, OneDrive). Pick one, pick any other folder, or keep the default (`~/Documents/Rapture Notes/`). If the place you pick already has your own files, Rapture offers to keep its folders together in one subfolder, **Rapture Inbox** by default, so they never mix with yours. Notes that arrive before you answer land in the default folder and move with the rest.
3. **Set up your iPhone.** "Text me" only works when Siri knows who you are. Open **Settings → Siri** (on newer iOS, **Settings → Apple Intelligence & Siri**), tap **My Information**, and choose your own contact card. On the same screen, turn on **Allow Siri When Locked** so the flow works with the phone locked. One more thing: a Focus mode can silence the `✅ Saved` reply on your phone. The note still saves.
4. **Send a test note.** Say to your iPhone: *"Hey Siri, text me this is a test."*
5. Within about a second, a Markdown note appears under `Notes/` in the folder you chose.
6. **Allow replies.** On that first capture, a Mac alert explains the `✅ Saved` replies. Click **Continue**, then click **OK** when macOS asks to let Rapture control Messages. (Rather not get replies? Click **Don't Send Replies** and the app switches reply mode to **Never reply**.)
7. `✅ Saved` arrives in your Messages thread on the phone. That's the audible confirmation that the capture landed.

That's the whole product. Rapture starts itself when you log in, so capture keeps running after a restart; turn that off with **Start Rapture when I log in** in **Settings → General**. Everything else (allowlist, reply modes, pause/resume) is in the menu-bar popover and the Settings window.

### Nothing happened?

| What you see | What to do |
|---|---|
| No note after you texted yourself | Open **Activity…** from the menu to see whether the note filed, queued, or failed. If the menu shows a warning, start there. Rapture files only messages in your own thread and messages from senders on the **Allowlist** (phone numbers work in any format), and ignores everything else. If Siri sent the text to someone else, set **My Information** on the iPhone to your own contact card (step 3). |
| Capture stopped after you reinstalled the app by hand | Dragging a new copy into Applications makes macOS forget the Full Disk Access grant. Choose **Show permissions help…** from the menu, turn Rapture back on, and reopen the app. In-app updates keep the grant. |
| No `✅ Saved` reply | The menu shows **Automation access needed**. Choose **Show permissions help…** and turn on Messages under Rapture, or click **Never Reply** if you don't want replies. Also check the iPhone's Focus mode, which can silence the reply. |
| Notes from the iPhone app don't arrive | Both devices need the same Apple account with iCloud Drive on, and the Mac needs to be awake. **Settings → General → iPhone App** shows the relay status. If a note waits on iCloud for more than 10 minutes, the menu says so: open the Rapture app on your iPhone while it's on Wi-Fi. |
| `✅ Saved · 1 attachment missing` | The photo hadn't reached the Mac yet. Rapture keeps trying for about 30 minutes and adds it to the note when it arrives. |
| A `✗` reply, or an error in the menu | The note couldn't be saved (often a full disk or an unwritable folder). Rapture retries every minute and sends the `✗` reply only once. After 24 hours of failing it saves the note's text to `~/Library/Application Support/Rapture for Mac/Failed captures/`, and the error says so. |

When something is wrong, the menu-bar icon turns into a warning triangle and the menu shows the newest error with its age and a **Dismiss** button. The **Activity** window (menu → **Activity…**) lists every open error at the top, with a **Dismiss All** button.

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

The folder is the entire integration surface. What you'll find there:

- **One Markdown note per capture**, with a small YAML header (`captured`, `source`, `type`, `raw_media`). Prefer raw `.txt` files? Choose raw mode in **Settings → Triage**.
- **Link details, if you want them.** Turn on **link enrichment** in **Settings → Triage** (off by default) and a captured YouTube or article link also gets its transcript or readable text saved into `Links/Media/`, with the note renamed to the real title.
- **Meetings** recorded in the Rapture iPhone app, in `Meetings/`, one note per meeting. When you make a summary on the iPhone, it replaces the note's text and renames the note. If you had edited the note first, your version is kept in the note's attachment folder as `Your edits before the summary.md`. Meetings skip AI triage and Reminders/Calendar handoff.

To check what the app did, choose **Show Last Note** in the menu to reveal the newest note in Finder, or open **Activity…** for the full history: notes filed and where they came from, queued captures, failures and retries, missing attachments, reminders and events created, link details saved, and meetings filed or updated. That history stays on your Mac and never includes note text (see [PRIVACY.md](./PRIVACY.md)).

**Changing the folder.** **Settings → General → Change…** lists your Obsidian vaults by name (a vault on an unplugged drive shows as "drive not connected"), your synced folders, the default, and **Choose Another Folder…**. Before any notes move, Rapture shows how many will move, from where to where, and how many get a number added because a file with that name is already there. Then you choose **Move Them**, **Leave Them Behind** (switch folders and let Rapture forget the old notes), or **Cancel**. If you are still on the default folder and have a vault, the menu offers once to move there; dismiss it and it stays dismissed. If Rapture's folders ended up loose in the top of a vault, the menu offers to gather them into **Rapture Inbox**, moving only Rapture's own folders and never your notes.

Two more things the folder can do:

- **Live on an external drive** (an Obsidian vault on an SSD, say). While the drive is unplugged, new captures queue inside the app and the menu bar shows "Destination offline" with the number of queued captures. Plug it back in and they file automatically, in order, with their original capture times.
- **Warn you when its git backup falls behind.** If the folder is a git repository backed up by something else (obsidian-git, a scheduled `git push`, hand-commits), turn on **"Warn me when the notes folder isn't backed up"** in **Settings → General**. The menu bar then flags uncommitted or unpushed work older than a day. Rapture only reads local git state. It never commits, pushes, or touches the network; the backing up stays with whatever tool you already use.

Once notes are landing, you can:

- **Use them manually** when you're back at your computer. Open the folder, triage by hand, file what matters.
- **Hand them off to an AI agent or assistant** to read and process automatically, according to your own rules.

Starter configs for the automated path live in [`examples/`](./examples) — all of them consume the triaged Markdown tree (act on `Tasks/`, read `Links/` and their `Links/Media/` artifacts, review `Journal/`):

- [`examples/claude-code/`](./examples/claude-code) — `CLAUDE.md` rules for acting on triaged notes, plus a one-line installer for a `SessionStart` hook that surfaces recent notes whenever you next open Claude Code
- [`examples/openclaw/`](./examples/openclaw) — OpenClaw skill that watches the folder; default reply via Telegram (Rapture already owns the iMessage layer)
- [`examples/hermes/`](./examples/hermes) — Hermes Agent skill, schedules via built-in cron, default reply via Telegram
- [`examples/cli/`](./examples/cli) — vendor-neutral shell script that pipes each note into any LLM CLI

Pick whichever agent you already use. Rapture doesn't care.

## Why the app isn't sandboxed

The app asks for **Full Disk Access** and **Automation → Messages**, which are unusual permissions on macOS. That's not a corner being cut. It's the only way the product can work:

- **Reading `~/Library/Messages/chat.db` requires Full Disk Access**, period. No entitlement gets a sandboxed app into that file; this is an Apple privacy guarantee, not a configuration option. Without that read, the app has nothing to capture.
- **Sending the `✅ Saved` reply requires spawning `osascript` and controlling Messages.app**, both of which the Mac App Store sandbox forbids for arbitrary apps.

So the app ships outside the sandbox by structural necessity, which is also why it isn't (and can't be) on the Mac App Store. In exchange, the code carries no telemetry and no network calls beyond three features you control: auto-update (on by default, opt-out), BYO-key AI, and link enrichment (both opt-in). See [PRIVACY.md](./PRIVACY.md) for the full posture and how to verify it yourself with two shell commands.

## Verify the download

Before opening the DMG:

```sh
xcrun stapler validate ~/Downloads/Rapture-*.dmg
spctl --assess --type install ~/Downloads/Rapture-*.dmg
```

Both should succeed. The DMG is Developer ID signed (team `P8PLTH44DF`) and Apple-notarized. See [SECURITY.md](./SECURITY.md) for full details and how to report issues.

## v1 scope

- **Two capture sources, no server.** The iMessage source polls `~/Library/Messages/chat.db` once per second, decodes message text (including the binary `attributedBody` blob that iOS 16+ uses for Siri-dictated messages), filters to your self-chat plus a user-managed allowlist, writes one Markdown note per message (with attachments in a sibling folder), and replies via AppleScript through Messages.app. The relay source watches the synced iCloud relay folder and files whatever the Rapture iPhone app sent. The built-in triage engine also converts any `.txt` dropped at the folder root — including notes captured before triage existed. Classification is deterministic by default (no AI, no network): bare links file into `Links/`, everything else into `Notes/`. An optional **AI triage** toggle (off by default, **Settings → Triage**) refines voice notes into `Tasks/`, `Ideas/`, and `Journal/` with smart titles — using Apple Intelligence on-device when available, or your own Anthropic API key otherwise; the verbatim dictation is always kept in the note, and captures file instantly without AI whenever it's off or unavailable. A separate **link enrichment** toggle (also off by default) fetches YouTube transcripts and article text into `Links/Media/` and renames link notes to their real titles — best-effort, and the note is complete without it.
- **No cloud mode in v1.** A future v1.1 adds a Sendblue path via VPS relay. An on-Mac webhook listener would die whenever the Mac sleeps, so we won't ship one.

### Out of scope

A short list of things you might expect but don't get; for the full rationale see [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md):

- Group chat capture
- In-app browsing / search / preview (the folder *is* the UI; use Finder, Spotlight, ripgrep, or your AI assistant)
- Built-in AI *consumption* of your notes (the folder stays vendor-neutral by design — the optional AI triage toggle only classifies and titles captures on the way in; any LLM can still read the output)
- Audio capture of Siri-dictated iMessages (text only; that audio stays on your iPhone). Captures sent from the Rapture iPhone app *can* include the audio file when you turn that on in the iOS app.
- Mac App Store distribution (structurally impossible; see [shape.md](./agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md))
- Analytics or telemetry (the only outbound network calls are the optional, opt-out auto-update check, the opt-in BYO-key AI engine, and the opt-in link-enrichment fetches — see [PRIVACY.md](./PRIVACY.md))

## Build from source

```sh
xcodebuild \
  -derivedDataPath /tmp/RaptureMacDerived \
  -project RaptureMac/RaptureMac.xcodeproj \
  -scheme RaptureMac \
  -configuration Debug \
  build test
```

This builds a Debug build and runs the test suite; all tests should pass. The app lands at `/tmp/RaptureMacDerived/Build/Products/Debug/Rapture.app`. A Debug build keeps its own settings in `~/Library/Application Support/Rapture for Mac (Debug)/` and files notes into `~/Documents/Rapture Notes (Debug)/`, so it never touches an installed copy's settings or notes. If you only want to use Rapture on an Apple silicon Mac, install the signed DMG from [Releases](https://github.com/NoiseMeldOrg/rapture-mac/releases/latest) instead.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the longer walkthrough, the `_build_plan/` directory for the milestone-by-milestone build log, and `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/` for the canonical technical spec.

## Sibling repos

- [`rapture-ios`](https://github.com/NoiseMeldOrg/rapture-ios): iOS app (the voice-capture-and-cloud-sync product)
- [`rapture-android`](https://github.com/NoiseMeldOrg/rapture-android): Android app
- [`rapture-api-gateway`](https://github.com/NoiseMeldOrg/rapture-api-gateway): Backend (Render.com)
- [`claude-channel-rapture`](https://github.com/NoiseMeldOrg/claude-channel-rapture): Claude Code plugin that pairs with Rapture iOS over a real-time channel

## License

Apache-2.0. See [LICENSE](./LICENSE).
