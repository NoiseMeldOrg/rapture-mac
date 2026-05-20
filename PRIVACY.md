# Privacy

Rapture for Mac is built so this section can be honestly short.

## What stays on your Mac

**Everything.** Captured messages, their attachments, the app's settings, the app's runtime state. None of it leaves your computer.

- Captured `.txt` files go into the folder *you* picked (default `~/Documents/Rapture Notes/`). They're plain text. You own them. You can move, delete, encrypt, or sync them wherever you want.
- `~/Library/Application Support/Rapture for Mac/settings.json`: your preferences (output folder, allowlist, reply mode, etc.).
- `~/Library/Application Support/Rapture for Mac/state.json`: runtime bookkeeping (the chat.db ROWID watermark, recent self-handle cache, last-error string).

Both files are plain JSON. You can `cat` them and see exactly what's in there.

## What we collect about you

**Nothing.** No telemetry. No analytics. No crash reporter. No usage pings. No update checks. No "anonymous" data collection. There is no backend, and nothing for us to receive even if we wanted it.

You can confirm this two ways:

1. **Grep the source.** `grep -RnE "URLSession|URLRequest|NWConnection|NWListener" RaptureMac/RaptureMac/` returns zero results. There is no networking code in the app.
2. **Check the signed entitlements.** Run `codesign -d --entitlements - /Applications/RaptureMac.app`. You'll see exactly two: `app-sandbox = false` and `automation.apple-events = true`. There are no `com.apple.security.network.*` entitlements, which means macOS itself would block any network attempt the app made, even one snuck in by a malicious dependency.

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

One:

- **[GRDB.swift](https://github.com/groue/GRDB.swift)**: a Swift wrapper around SQLite, pinned at version 6.29.3 in `Package.resolved`. Used read-only against `chat.db`. GRDB itself has zero network code.

That's the entire third-party surface. No analytics SDK, no crash reporter, no logger that phones home, no AI/LLM SDK.

## What the `✓ Saved` reply looks like to your iMessage thread

When the app sends `✓ Saved: 2026-05-19T14-32-08Z.txt` to confirm a capture, that message goes through Apple's iMessage infrastructure exactly the way any other iMessage would. Apple handles the transport; we have no visibility into it. The reply lands in your own iMessage thread on your phone, in the same chat as the conversation history.

If you'd rather not send replies, switch to **Settings → General → Reply mode → Never reply** and the app falls back to a `UNUserNotification` for catch-up summaries (still local).

## Reporting concerns

Email `michael@noisemeld.com`. See [SECURITY.md](./SECURITY.md) for the full disclosure flow.

## Changes to this policy

If this changes in a future release, the change is recorded in [CHANGELOG.md](./CHANGELOG.md) and called out in the release notes. We won't change the privacy posture quietly.
