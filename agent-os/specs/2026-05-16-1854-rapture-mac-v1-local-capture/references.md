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

### imsg (production-grade CLI reference)

- **Location:** https://github.com/openclaw/imsg (MIT-licensed; brew install `steipete/tap/imsg`)
- **Relevance:** The closest existing tool to what we're building. CLI rather than a Mac app, but the data-plane behavior is exactly what we want to match.
  - `imsg watch --json` is the closest functional equivalent to our planned `ChatDBWatcher.events` stream.
  - Already solved every macOS-26 / Tahoe chat.db edge case we'd otherwise rediscover.
  - Implements file-system events on chat.db with polling fallback (matches our Phase 5 design).
  - Independently implements an `attributedBody` decoder — useful for cross-checking ours.
  - Uses Messages.app AppleScript automation for sending (same shape as Anthropic's `server.ts`).
- **What we copy:** behavior contracts (decoder edge cases, polling cadence, AppleScript invocation shape).
- **What we don't copy:** CLI distribution shape, general-purpose framing, no per-message file output, no auto-ACK reply — those gaps are our value-add.
- **Verification idea for Phase 5:** install imsg via brew, run `imsg watch --json` in parallel against the same chat.db. Diff our `MessageEvent` stream against imsg's JSON output line-by-line. Any divergence is either a bug in our port or a documented intentional difference.

## Data plane decision (2026-05-16)

**Decision:** rapture-mac is a **Swift port** of the data-plane logic, with `imsg` and Anthropic's `server.ts` as **reference implementations** — NOT a runtime dependency.

### Rejected: shell out to `imsg watch --json` from the menu-bar app

- Pro: ~80% of the data plane is already battle-tested.
- Con: Requires `brew install steipete/tap/imsg` before our app works, which violates the "easily installable for any user" mission requirement. Most target users (non-technical) do not have Homebrew.
- Con (with mitigation): Bundling imsg inside `RaptureMac.app/Contents/Resources/` is technically possible but (a) we'd ship a frozen copy that drifts from upstream, (b) the embedded binary itself must be re-signed and re-notarized as part of our build, (c) we'd inherit imsg's release cadence for any security fix we'd want to ship urgently.
- Con: Subprocess JSON-parse boundary on every message — minor per-message latency, but more importantly, subprocess lifecycle, log capture, and crash-restart all become problems we own.

### Accepted: Swift port

- Pro: Single signed + notarized `.app` bundle. Drag-and-drop install for any user. Mission-aligned.
- Pro: Async/await native; pipeline composes cleanly with `@Observable` state.
- Pro: We own the release cadence — a security fix or a Tahoe-day-1 schema change can ship without waiting on upstream.
- Pro: The data plane is small (projected ~400 lines for watcher + decoder + filter combined). Shelling out wouldn't materially shrink the codebase.
- Con: We re-encounter chat.db schema changes Apple ships. *Mitigation:* cross-check against imsg in CI when imsg cuts a release; if imsg drifts, we know to update.

### Implementation guidance for Phases 4–7

- Read **imsg's source** as a second spec alongside Anthropic's `server.ts` when porting.
- Where the two references disagree on edge-case behavior, **prefer imsg's** — it's been tested on macOS 26 (Tahoe), whereas Anthropic's plugin updates less frequently and the version checked into `external_plugins/` is a point-in-time snapshot.
- Phase 5 verification step: install imsg, run `imsg watch --json` against the same chat.db, diff the streams.
- Anything imsg handles that we don't (e.g., a future macOS change to `attributedBody` format) is a known TODO, not a surprise. Track imsg's CHANGELOG.

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
