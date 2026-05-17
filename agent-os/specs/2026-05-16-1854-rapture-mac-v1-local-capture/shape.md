# Rapture for Mac v1 — Shaping Notes

## Scope

A macOS menu-bar app that captures iMessages dictated to Siri (from a locked iPhone, fully hands-free) into timestamped `.txt` files on disk. Replies to the chat with a short confirmation so the user knows the capture worked without checking their Mac.

v1 implements **local mode only**: polls `~/Library/Messages/chat.db`, decodes message text, filters to self-chat + an allowlist, writes one `.txt` per message (plus a sibling folder for attachments), and replies via AppleScript through Messages.app.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Branding | Rapture for Mac, bundle `noisemeld.RaptureMac` | Same product line as Rapture iOS, new Mac surface. Lives under the Rapture umbrella. |
| Repo | New private repo `NoiseMeldOrg/rapture-mac` (NOT a sibling layout) | User explicitly wanted a separate private repo in the org. Sits at `/Volumes/Dock SSD/Source/Repos/NoiseMeldOrg/rapture-mac`. |
| Spec location (snapshot) | `rapture-ios/agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/` | Survives the shaping session in the current working repo. |
| Spec location (canonical) | `rapture-mac/agent-os/specs/...` once that repo exists | Source of truth follows the code. |
| v1 modes | **Local only**. Cloud mode (Sendblue + cloudflared) entirely deferred. | See "Why local-only" below. |
| Sandboxing | No | FDA + arbitrary folder writes + AppleScript control of Messages.app are all easier outside the sandbox. |
| Distribution | Developer ID signed + notarized DMG | Mac App Store would require sandboxing + tunnel rework. Out of v1 scope. |
| Data plane | Swift port; NOT a runtime dependency on `imsg` or any other CLI | See ADR in `references.md`. The "easily installable for any user" mission requirement precludes a `brew install` prerequisite. |

## Why local-only (the most important shaping decision)

The original plan at `~/.claude/plans/can-you-help-me-goofy-clover.md` describes both a local mode (chat.db polling) and a cloud mode (dedicated Sendblue number + cloudflared tunnel + on-Mac HTTP webhook listener). v1 drops the cloud half entirely.

The user pushed back on running Sendblue on their Mac during shaping, and the reasoning held up:

1. **Cloud-on-Mac undermines the product promise.** The app's value is "hands-free voice capture stays trustworthy even when the Mac is asleep." But a tunnel + webhook listener on the Mac dies when the Mac sleeps. Messages queue at Sendblue's retry window (a few hours, undocumented bounds) and silently drop. That's "trustworthy if you remember the lid was open" — not the promise.
2. **Wrong host for an internet-facing service.** The Mac is an unreliable host: sleep, network changes, OS updates, lid closes. An inbound webhook belongs on something with an uptime SLA.
3. **boop-agent is the precedent.** Sendblue already runs against a server in the user's stack, not a personal Mac. Building parallel Sendblue infrastructure on the Mac would be worse-than-existing.
4. **The original plan flags this itself.** The "Out of scope for v1, flagged" section explicitly calls out the user's planned `hetzner-vps-deployment` as the right relay.
5. **v1 surface drops by ~half.** Removing cloud mode kills: Hummingbird, cloudflared child-proc supervision, browser auth flow, DNS routing, Sendblue webhook handler, HMAC/token scheme, MMS download, and cloud-side catch-up logic that depended on an unverified Sendblue list-messages endpoint.
6. **What's left is a coherent product.** chat.db → filter → file → AppleScript reply. The Siri-to-self flow is the hero use case and works without any of the cloud surface.

**v1.1 direction (deferred, not committed):** Sendblue → VPS relay (queues + dedups on `message_handle`) → push to Mac. Mac never holds a public webhook. Transport TBD (APNs silent push vs Mac long-poll vs WebSocket).

## Why this can't be a Shortcut

Validated empirically 2026-05-16: the Apple Shortcuts path that looks closest ("Hey Siri, *[shortcut name]*" → dictate → append to a file) does **not** work from a locked iPhone in practice. iMessage-to-self via stock Siri *does*. This was first-hand testing, not theoretical.

This isn't a temporary gap or a Shortcuts bug. It's a structural lock-screen policy split that Apple maintains deliberately:

- **iMessage-to-self from a locked phone is a stock Siri primitive.** Messaging is core communication; Apple has always allowed it from the lock screen and has tuned the dictation flow accordingly.
- **Arbitrary Shortcut activation from a locked phone is gated behind unlock.** Permitting it would mean anyone holding the phone could invoke any automation the owner has installed. That's a security policy Apple is not going to loosen, because doing so would either (a) weaken Shortcuts security broadly, or (b) collapse the distinction between "stock Siri behaviors" and "user-authored automations." Neither is acceptable.

**The implication for this product:** rapture-mac's moat is **not** "we built it better than the Shortcuts alternative." It's that the only Apple-permitted path for hands-free voice capture from a locked iPhone is the one we hijack — the message-to-self flow. This holds until Apple fundamentally rearchitects lock-screen policy, which they won't, for the reasons above.

This is the **load-bearing assumption** of the product. If Shortcuts ever did work cleanly from a locked phone, the right answer would be a Shortcut, not a Mac app.

## Reference-code corrections caught during shaping

Exploration of the boop-agent code (which we'd need for v1.1 cloud mode) caught three bugs in the original plan's Sendblue assumptions. Documented here so v1.1 doesn't repeat them:

| Field | Original plan said | Actual (verified) |
|---|---|---|
| Outbound endpoint | `api.sendblue.co` | `api.sendblue.com` (`.com` not `.co`) |
| Auth header 2 | `sb-api-secret-id` | `sb-api-secret-key` |
| Dedup key | `message_uuid` | `message_handle` |
| Inbound HMAC verification | Plan says verify it | boop-agent does NOT verify; scheme unconfirmed against Sendblue docs |
| Inbound MMS field | Plan assumes `media_url` array | boop-agent's webhook handler doesn't read it; needs verification at v1.1 time |

For v1, none of this matters — but `references.md` preserves the details so v1.1 starts from accurate contracts.

## Context

- **Visuals:** None provided. Menu bar UI is small enough to design from text. The plan describes the menu structure inline.
- **References:** Two reference codebases were explored — `external_plugins/imessage/server.ts` (primary v1 reference, fully mapped) and the boop-agent Sendblue files (for v1.1 only). See `references.md`.
- **Product alignment:** Rapture iOS roadmap (`agent-os/product/roadmap.md`) doesn't mention a Mac companion. This is a new surface area under the Rapture product line, not a continuation of an existing phase. The mission file (`agent-os/product/mission.md`) describes Rapture as "zero-tap voice capture" — this Mac app extends that promise to "iMessages-as-notes captured at the Mac." Same philosophical product (hands-free voice → reliable capture on disk), different surface.

## Standards Applied

- **None applicable.** `rapture-ios/agent-os/standards/` does not exist. The new `rapture-mac` repo will establish its own standards as patterns emerge from v1.
