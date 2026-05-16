# References for Rapture for Mac v1

## Primary v1 reference

### imessage plugin (local-mode source of truth)

- **Location:** `/Volumes/Dock SSD/Source/Repos/anthropics/claude-plugins-official/external_plugins/imessage/server.ts`
- **Relevance:** Direct port target. The Swift implementation of `ChatDBWatcher`, `AttributedBodyDecoder`, `SelfHandleResolver`, `MessageFilter`, `AppleScriptSender`, and `EchoGuard` is a structural port of this file.
- **Key patterns to port verbatim:**
  - **Polling SQL** (lines 120–129): joins `message ← chat_message_join ← chat`, left-joins `handle`. Watermark column = `m.ROWID`. Order ASC.
  - **DB open mode** (line 64): `{ readonly: true }`. GRDB equivalent: open `DatabasePool` with read-only configuration.
  - **`attributedBody` decoder** (lines 82–102): byte-scan for `NSString\0` marker → skip to `0x2B` → read length prefix (1 byte direct, or `0x81/0x82/0x83` escape codes for 1/2/3-byte LE lengths) → UTF-8 decode. Bounds-check every step; return `nil` on any failure.
  - **Self-handle SQL** (lines 177–185): `SELECT DISTINCT account FROM message WHERE is_from_me=1 AND account IS NOT NULL AND account != '' LIMIT 50`. Strip `^[A-Za-z]:` prefix. Lowercase.
  - **Filter drops** (lines 777–798): order matters. `chat_style==null` first, then group/DM split, then SMS gate, then `is_from_me`, then `handle_id==NULL`, then empty-content tapback drop.
  - **Attachment SQL** (lines 166–171): join via `message_attachment_join`. Expand `~/` paths via `homeDirectoryForCurrentUser`.
  - **Apple epoch** (line 77): `978_307_200` seconds offset. `message.date` is nanoseconds — divide by `1_000_000_000` for seconds.
  - **AppleScript send** (lines 418–424, 459–467): script `on run argv \n tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv) \n end run`. Invoke `/usr/bin/osascript -`, pipe script via stdin, pass `[text, chatGuid]` as argv.
  - **Echo guard** (lines 431–457): 15-second window. Key = `chatGuid + 0x00 + normalize(text)`. Normalize = strip `' Sent by Claude'` suffix, strip ZWJ + variation selectors, smart quotes → ASCII, trim, collapse whitespace, cap at 120 chars.

## Deferred references (v1.1 cloud mode only — DO NOT USE in v1)

### boop-agent Sendblue webhook handler

- **Location:** `/Volumes/Dock SSD/Source/Repos/NoiseMeld/boop-agent/server/index.ts` + `/Volumes/Dock SSD/Source/Repos/NoiseMeld/boop-agent/server/sendblue.ts`
- **Relevance:** v1.1 cloud mode. The VPS-relay design will replicate this webhook handler on the user's hetzner VPS (not on the Mac). The Mac side will only consume push notifications from the relay.
- **Corrections caught during shaping** (the original plan had bugs here):
  - Outbound endpoint is `https://api.sendblue.com/api/send-message` (`.com`, NOT `.co`).
  - Auth headers are `sb-api-key-id` + **`sb-api-secret-key`** (NOT `sb-api-secret-id`).
  - Dedup field is `message_handle` (NOT `message_uuid`).
  - Webhook handler reads only: `content`, `from_number`, `is_outbound`, `message_handle`. Skips `is_outbound==true` and empty `content`.
  - HMAC signature verification is **absent** in boop-agent. Either Sendblue doesn't sign, or boop-agent has a security gap. v1.1 should check current Sendblue docs before assuming either way.
  - MMS / `media_url` handling is **absent** in boop-agent's webhook handler. v1.1 needs to verify the current inbound schema directly with Sendblue.

### boop-agent dedup

- **Location:** `/Volumes/Dock SSD/Source/Repos/NoiseMeld/boop-agent/convex/sendblueDedup.ts`
- **Relevance:** v1.1 idempotency pattern. The VPS relay will need this — `INSERT ... ON CONFLICT` keyed on `message_handle`, returning `claimed: false` for duplicate webhook retries.

### Full original design

- **Location:** `~/.claude/plans/can-you-help-me-goofy-clover.md`
- **Relevance:** The complete pre-shaping design that included both modes. v1.1 starts from the cloud-mode sections of this file, with the corrections above applied and the architecture moved off the Mac.
