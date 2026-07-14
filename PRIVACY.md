# Privacy

Rapture for Mac is built so this section can be honestly short.

## What stays on your Mac

**Everything, with one opt-in exception you control.** Captured messages, their attachments, the app's settings, the app's runtime state. None of it leaves your computer — unless you explicitly turn on AI triage *and* it runs on your own Anthropic API key (see "AI triage" below). With that toggle off (the default), nothing about your captures ever leaves.

- Captured notes go into the folder *you* picked (default `~/Documents/Rapture Notes/`) as plain Markdown files with a small metadata header — or raw `.txt` files if you choose raw mode in **Settings → Triage**. Either way they're plain text. You own them. You can move, delete, encrypt, or sync them wherever you want. Triage (classification, titling, filing into `Notes/` and `Links/`) is deterministic string-matching that happens on your Mac by default: no AI, no network, and the verbatim transcription is never discarded.
- `~/Library/Application Support/Rapture for Mac/settings.json`: your preferences (output folder, allowlist, reply mode, etc.).
- `~/Library/Application Support/Rapture for Mac/state.json`: runtime bookkeeping (the chat.db ROWID watermark, recent self-handle cache, last-error string).

Both files are plain JSON. You can `cat` them and see exactly what's in there. Your optional Anthropic API key is in **neither** — it lives in the macOS Keychain.

## AI triage (optional, off by default)

**Settings → Triage → AI Triage** adds smart classification (Tasks/Ideas/Journal), concise titles, and light text cleanup. It is off by default and picks an engine automatically:

- **Apple Intelligence (macOS 26+, when available):** the capture is processed by Apple's on-device model. Nothing leaves your Mac. No account, no key, no network.
- **Your own Anthropic API key (only if Apple Intelligence isn't available and you pasted a key):** each voice-note capture's text is sent to Anthropic over HTTPS (`api.anthropic.com`) to classify and title it, under [Anthropic's API terms](https://www.anthropic.com/legal/commercial-terms). This is the only way capture text can ever leave your Mac, it happens only with the toggle on and your own key entered, and the Settings pane states which engine is active. Link captures are never sent — only voice notes, capped at the first 6,000 characters.

Either way: the AI never delays or blocks filing (if it's slow, offline, or erroring, the capture files deterministically and instantly), the verbatim transcription is always preserved in the note under `## Raw`, and no NoiseMeld server is ever involved. The API key is stored as a generic-password item in the macOS Keychain — never in a settings file, never synced.

## Notes from the Rapture iPhone app

If you enable the **Rapture Mac** destination in the Rapture iOS app, your iPhone hands each capture to your own iCloud, inside a relay folder in Rapture's app container. macOS syncs that folder to your Mac like any other iCloud Drive content. This app watches the synced local copy (`~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay/`), files each arrival into your notes folder, and deletes the relay copy.

In transit these captures are ordinary iCloud data moving between your devices, the same way this app's iMessage captures already transit Apple's iMessage infrastructure. Apple handles the transport; we have no visibility into it. No NoiseMeld server is involved, and the Mac app makes no network connections to do this: it reads a folder on your disk and the operating system moves the bytes. The grep check below covers this path too.

## What we collect about you

**Nothing.** No telemetry. No analytics. No crash reporter. No usage pings. No "anonymous" data collection. There is no backend, and nothing for us to receive even if we wanted it.

The app can make exactly **two** kinds of outbound connection, and neither collects anything about you:

1. The optional **auto-update** check — it only *reads* public files from GitHub and sends no identifiers, no system profile, and no usage data. On by default, fully opt-out. Details in "Auto-update" below.
2. The opt-in **BYO-key AI engine** — only if you turned on AI triage, Apple Intelligence isn't available, and you pasted your own Anthropic API key. It sends capture text to Anthropic to classify it (see "AI triage" above); NoiseMeld receives nothing.

Turn both off (auto-update off, AI triage off — the latter is already the default) and the app makes no network connections at all.

You can confirm the no-collection posture:

1. **Grep the source.** Outside the Sparkle updater, the only networking in the app is the BYO-key engine — `grep -RnE "URLSession|URLRequest|NWConnection|NWListener" RaptureMac/RaptureMac/` returns matches **only** in `TriageAI/AnthropicEngine.swift` and `TriageAI/AnthropicWire.swift` (the opt-in Anthropic call described above). Nothing else in the app touches the network.
2. **Look for an endpoint.** The only addresses the app can ever contact are the public update feed (and the GitHub `.dmg` you choose to install) and, opt-in with your own key, `api.anthropic.com`. There is no analytics or tracking endpoint anywhere to find, signed-entitlements or otherwise.

## Auto-update

Rapture can keep itself current using [Sparkle](https://sparkle-project.org), the standard open-source macOS updater. Besides the opt-in BYO-key AI engine above, this is the only part of the app that uses the network.

- **What it fetches:** the update feed at `https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/appcast.xml`, and — only if you click **Install** — the new `.dmg` from this repo's GitHub Releases. Both are public files; fetching them tells GitHub roughly what loading the release page in a browser would (your IP, around when). Nothing about your captures, settings, or usage is involved.
- **What it sends about you:** nothing. Sparkle's optional anonymous system-profiling is disabled (`SUEnableSystemProfiling = NO`) — no identifiers, no OS/hardware profile, no usage data.
- **Integrity:** every update must pass an **EdDSA signature** check against a public key baked into the app **and** Apple's notarization before it can install. A tampered, unsigned, or downgraded download is rejected.
- **Your off switch:** **Settings → About → "Automatically check for updates."** On by default. Turn it off and the app makes **no** network connections on its own — you can still check manually, or ignore updates entirely and re-download from GitHub yourself.

## Permissions the app asks for

| Permission | Why | What it can see |
|---|---|---|
| Full Disk Access | Required to read `~/Library/Messages/chat.db`, which is the only place macOS stores iMessage history. | Anything in your home folder. We use exactly one file: `chat.db` (read-only). |
| Automation → Messages | Required to send the `✓ Saved` reply in your iMessage thread via `osascript`. | We can ask Messages.app to send one specific outgoing reply per capture. |
| Output folder | The folder you picked for captures. | Just that folder. We don't write anywhere else. |
| iCloud relay folder | Watched so captures sent from the Rapture iPhone app can be filed. | Only Rapture's own iCloud container. Reading it needs no permission grant, and Full Disk Access is not involved. |
| Reminders *(optional)* | Requested only when you turn on **Settings → Triage → Reminders handoff**. Creates a Reminder when a capture clearly says "remind me to…". | Your Reminders lists (names shown in the target picker). The app only ever *creates* reminders you dictated; it doesn't read, edit, or complete existing ones. Off by default. |
| Calendars *(optional)* | Requested only when you turn on **Settings → Triage → Calendar handoff**. Creates a 1-hour event when a capture states an appointment with a date and time. | Your calendars (names shown in the target picker). The app only ever *creates* events you dictated; it doesn't read, edit, or delete existing ones. Off by default. |

If any of these become uncomfortable, revoke them in **System Settings → Privacy & Security**. The app will surface a permission-needed prompt and stop capturing until you re-grant.

## What we read from `chat.db`

Just the fields needed to filter and decode each message: `ROWID`, `guid`, `text`, `attributedBody`, `date`, `is_from_me`, `cache_has_attachments`, `service`, `handle.id` (the sender's phone or email), `chat.guid`, `chat.style`. For attachments: `filename`, `mime_type`, `transfer_name`.

We do **not** read your contacts, your phone's name, your other databases (HealthKit, Photos, etc.), your browser history, or anything outside the chat.db file. The Full Disk Access grant gives us the *capability* to do so; the code does not. From the keychain, the app reads exactly one item: its **own** stored Anthropic API key (if you saved one in Settings → Triage) — never any other keychain entry.

From your iCloud Drive we read exactly one folder: Rapture's own relay folder described above, containing only the `.txt` and `.m4a` files the Rapture iPhone app wrote for this Mac to file. Nothing else in your iCloud Drive is opened.

## Third-party dependencies

Two:

- **[GRDB.swift](https://github.com/groue/GRDB.swift)**: a Swift wrapper around SQLite, pinned in `Package.resolved`. Used read-only against `chat.db`. GRDB itself has zero network code.
- **[Sparkle](https://github.com/sparkle-project/Sparkle)**: the standard open-source macOS updater. It is the only networked component, and only for the auto-update feature described above (fetch the appcast, download a release you choose to install, verify its signature). It sends no usage data; its anonymous system-profiling is disabled.

That's the entire third-party surface. No analytics SDK, no crash reporter, no logger that phones home, no AI/LLM SDK — the optional BYO-key engine is ~200 lines of plain `URLSession` code in this repo, not a vendor SDK, and the optional Apple engine is the system FoundationModels framework.

## What the `✅ Saved` reply looks like to your iMessage thread

When the app sends `✅ Saved` to confirm a capture, that message goes through Apple's iMessage infrastructure exactly the way any other iMessage would. Apple handles the transport; we have no visibility into it. The reply lands in your own iMessage thread on your phone, in the same chat as the conversation history.

If you'd rather not send replies, switch to **Settings → General → Reply mode → Never reply** and the app falls back to a `UNUserNotification` for catch-up summaries (still local).

## Reporting concerns

Email `michael@noisemeld.com`. See [SECURITY.md](./SECURITY.md) for the full disclosure flow.

## Changes to this policy

If this changes in a future release, the change is recorded in [CHANGELOG.md](./CHANGELOG.md) and called out in the release notes. We won't change the privacy posture quietly.
