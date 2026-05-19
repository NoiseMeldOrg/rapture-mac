# Security Policy

## Reporting a vulnerability

If you find a security issue in Rapture for Mac, **please do not open a public GitHub issue**. Email **michael@noisemeld.com** with the details. We'll respond within 5 business days and aim to ship a fix (or a documented mitigation) within 90 days.

If you're reporting something time-sensitive, putting `[security]` in the subject line helps it get triaged faster.

## Supported versions

Only the latest v1.x release on the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases) is supported. There are no backports for pre-1.0 builds.

## In scope

Anything in **this** codebase:

- The capture pipeline (`chat.db` reads, message filtering, file writes, attachment copying)
- The reply pipeline (`osascript` subprocess, argv construction, echo guard)
- Permission handling (Full Disk Access, Automation → Messages)
- Settings and state persistence (`~/Library/Application Support/Rapture for Mac/`)
- Code signing, hardened-runtime, and notarization configuration

## Out of scope

- Vulnerabilities in **macOS itself**, **`Messages.app`**, **AppleScript / Apple Events**, or **GRDB.swift** — please report those to their respective maintainers.
- The contents of the user's iMessage history, output folder, or attachments. We don't transmit any of it (see below); whoever can read the user's `~/Library/Messages/chat.db` or the chosen output folder can read those files directly.
- Social-engineering attacks that involve tricking a user into approving Full Disk Access or Automation prompts for a malicious actor's app pretending to be Rapture. We can't defend against impersonation of an unsigned download — only verify our signing chain (`spctl --assess --type install`).

## Supply chain

The shipped app has a deliberately small attack surface:

- **One third-party dependency**: GRDB.swift, pinned in `Package.resolved`. Built read-only against `chat.db`.
- **One subprocess invocation**: `/usr/bin/osascript` for in-thread `✓ Saved` replies. Text and chat GUID are passed as separate argv entries (not interpolated into shell), so command injection through message bodies is not possible by construction.
- **Zero outbound network calls in v1**. The app does not embed a networking SDK, does not check for updates, and does not phone home. You can verify with `codesign -d --entitlements - <app>` — there are no `com.apple.security.network.*` entitlements.

The build is reproducible from `main` at any commit: `xcodebuild -derivedDataPath /tmp/RaptureMacDerived -scheme RaptureMac -configuration Release build`. The signed DMG attached to each Release is produced by `Scripts/release.sh` from the corresponding tag.

## Trust verification for end users

After downloading a DMG from the [Releases page](https://github.com/NoiseMeldOrg/rapture-mac/releases) and before opening it:

```
xcrun stapler validate ~/Downloads/Rapture-for-Mac-*.dmg
spctl --assess --type install ~/Downloads/Rapture-for-Mac-*.dmg
```

Both should succeed. If either fails, the DMG was either tampered with or notarization was revoked — don't open it; report to `michael@noisemeld.com` with the SHA-256 of the file you have.
