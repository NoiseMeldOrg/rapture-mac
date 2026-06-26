# Privacy

Rapture for Mac is built so this section can be honestly short.

## What stays on your Mac

**Everything.** Captured messages, their attachments, the app's settings, the app's runtime state. None of it leaves your computer.

- Captured `.txt` files go into the folder *you* picked (default `~/Documents/Rapture Notes/`). They're plain text. You own them. You can move, delete, encrypt, or sync them wherever you want.
- `~/Library/Application Support/Rapture for Mac/settings.json`: your preferences (output folder, allowlist, reply mode, etc.).
- `~/Library/Application Support/Rapture for Mac/state.json`: runtime bookkeeping (the chat.db ROWID watermark, recent self-handle cache, last-error string).

Both files are plain JSON. You can `cat` them and see exactly what's in there.

## What we collect about you

**Nothing.** No telemetry. No analytics. No crash reporter. No usage pings. No "anonymous" data collection. There is no backend, and nothing for us to receive even if we wanted it.

The **one** outbound connection the app can make is the optional **auto-update** check, and it collects nothing about you either — it only *reads* public files from GitHub and sends no identifiers, no system profile, and no usage data. It is on by default but fully opt-out; turn it off and the app makes no network connections at all. Details in "Auto-update" below.

You can confirm the no-collection posture:

1. **Grep the source.** Outside the Sparkle updater there is no networking — `grep -RnE "URLSession|URLRequest|NWConnection|NWListener" RaptureMac/RaptureMac/` returns zero results. The only network access in the whole app is Sparkle's update check.
2. **Look for an endpoint.** The single address the app ever contacts is the public update feed (and the GitHub `.dmg` you choose to install). There is no analytics or tracking endpoint anywhere to find, signed-entitlements or otherwise.

## Auto-update

Rapture can keep itself current using [Sparkle](https://sparkle-project.org), the standard open-source macOS updater. This is the only part of the app that uses the network.

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

If any of these become uncomfortable, revoke them in **System Settings → Privacy & Security**. The app will surface a permission-needed prompt and stop capturing until you re-grant.

## What we read from `chat.db`

Just the fields needed to filter and decode each message: `ROWID`, `guid`, `text`, `attributedBody`, `date`, `is_from_me`, `cache_has_attachments`, `service`, `handle.id` (the sender's phone or email), `chat.guid`, `chat.style`. For attachments: `filename`, `mime_type`, `transfer_name`.

We do **not** read your contacts, your phone's name, your other databases (HealthKit, Photos, etc.), your keychain, your browser history, your iCloud Drive, or anything outside the chat.db file. The Full Disk Access grant gives us the *capability* to do so; the code does not.

## Third-party dependencies

Two:

- **[GRDB.swift](https://github.com/groue/GRDB.swift)**: a Swift wrapper around SQLite, pinned in `Package.resolved`. Used read-only against `chat.db`. GRDB itself has zero network code.
- **[Sparkle](https://github.com/sparkle-project/Sparkle)**: the standard open-source macOS updater. It is the only networked component, and only for the auto-update feature described above (fetch the appcast, download a release you choose to install, verify its signature). It sends no usage data; its anonymous system-profiling is disabled.

That's the entire third-party surface. No analytics SDK, no crash reporter, no logger that phones home, no AI/LLM SDK.

## What the `✓ Saved` reply looks like to your iMessage thread

When the app sends `✓ Saved: 2026-05-19T14-32-08Z.txt` to confirm a capture, that message goes through Apple's iMessage infrastructure exactly the way any other iMessage would. Apple handles the transport; we have no visibility into it. The reply lands in your own iMessage thread on your phone, in the same chat as the conversation history.

If you'd rather not send replies, switch to **Settings → General → Reply mode → Never reply** and the app falls back to a `UNUserNotification` for catch-up summaries (still local).

## Reporting concerns

Email `michael@noisemeld.com`. See [SECURITY.md](./SECURITY.md) for the full disclosure flow.

## Changes to this policy

If this changes in a future release, the change is recorded in [CHANGELOG.md](./CHANGELOG.md) and called out in the release notes. We won't change the privacy posture quietly.
