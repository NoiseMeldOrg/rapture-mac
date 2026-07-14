# CONTEXT

> Domain language and architectural ground-truth for `rapture-mac`. Read this before proposing changes, writing tests, or filing issues.

Rapture for Mac is a small, single-app codebase. Rather than duplicate the domain narrative here, this file points at the canonical sources and names the vocabulary that's load-bearing across them.

## Authoritative sources

Read the relevant doc for the question at hand. Don't paraphrase from memory; the files below are short.

| Question | Source |
| --- | --- |
| What is this product? Who's it for? What's in/out of scope? | [`agent-os/product/mission.md`](agent-os/product/mission.md) |
| What's the deployment target, language, framework choices, sandboxing posture? | [`agent-os/product/tech-stack.md`](agent-os/product/tech-stack.md) |
| What's shipped, what's queued, what's deferred? | [`agent-os/product/roadmap.md`](agent-os/product/roadmap.md) |
| How does the v1 capture pipeline work end-to-end (the actual technical truth)? | [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md`](agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/plan.md) |
| How does the built-in triage engine work (capture contract, filing seams, spool, handoff, AI tier, link enrichment)? | [`agent-os/specs/2026-07-13-2230-triage-engine/plan.md`](agent-os/specs/2026-07-13-2230-triage-engine/plan.md) |
| Why was the architecture shaped this way (local-only v1, no sandbox, no MAS)? | [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md`](agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/shape.md) |
| Why does the app now triage in-app, and what happened to the "no built-in AI" commitment? | [`agent-os/specs/2026-07-13-2230-triage-engine/shape.md`](agent-os/specs/2026-07-13-2230-triage-engine/shape.md) |
| What external reference implementations does the design port from? | [`agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md`](agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/references.md) |

## Glossary

The terms below appear across the spec and the code. Use them as defined; don't drift to synonyms.

- **Capture** — the act of detecting a qualifying arrival (an iMessage in `chat.db`, a relay file from the iPhone app, or a `.txt` dropped at the folder root), decoding its text, filing the note, and (for iMessage) optionally replying with `✅ Saved`. Not "sync," not "import," not "ingest."
- **Note** — a single filed capture in the output folder: a Markdown file with the capture contract (YAML `captured`/`source`/`type`/`raw_media` frontmatter, body, `## Raw` verbatim when formatting changed the body, `Attachments:` footer), named `YYYY-MM-DD <Title>.md` and filed into `Notes/`, `Links/`, `Tasks/`, `Ideas/`, or `Journal/`. In raw mode: a `.txt` named `<iso-ts>.txt` at the root, the pre-triage contract. The body is immutable once written; the app may later rename a *link* note to its fetched real title and append a `Media:` artifact link (link enrichment, opt-in).
- **Triage** — the in-app conversion of every capture into its filed Markdown note: deterministic classification (URL-dominance → `youtube-link`/`article-link`, else `voice-note`), first-words titling, subfolder filing. The AI tier (opt-in) refines voice notes to `task`/`idea`/`journal` with smart titles. Runs at the four filing seams (`FileWriter`, `RelayFiler`, `SpoolFlusher`, `TriageProcessor`).
- **Enrichment** — the opt-in, best-effort fetch that gives a link note its `Links/Media/` transcript/article artifact and real title. Strictly after filing; the note is complete without it.
- **Output folder** — the user-chosen directory where notes land. Stored as a plain absolute-path `URL` in `settings.json` (the app is **not** sandboxed, so no security-scoped bookmark is needed). Defaults to `~/Documents/Rapture Notes/` on first launch when none configured. Changing it relocates the existing notes tree to the new folder automatically (Dropbox-style; see **Relocation**). Its absolute path is mirrored to `~/Library/Application Support/Rapture for Mac/output-folder.path` so downstream consumers can track folder changes without reading `settings.json`.
- **Relocation** — when the user changes the output folder, Rapture moves the existing notes tree into the new folder before switching to it (same-volume atomic rename; cross-volume copy-verify-delete; merge-never-clobber on collisions). Routed through `AppState.setOutputFolder`; the capture pipeline is quiesced via `CaptureGate` during the move. Silent on success; on failure the source is left intact and the active folder is unchanged.
- **Catch-up** — the replay of messages that arrived while Rapture wasn't watching (sleep, quit, reboot). Triggered when a poll batch yields 10+ events. In catch-up mode the replier emits a single `📥 Caught up: N notes` summary instead of per-message confirmations.
- **Echo guard** — the 15-second LRU that suppresses re-capture of Rapture's own `✅ Saved` / `📥 Caught up` replies after iCloud multi-device sync re-delivers them as inbound. Hardened in v1.0.27 with greedy consume + pattern-match drop after the v1.0.18 echo-cascade incident.
- **Self-handle** — the user's own iMessage addresses (email/phone), normalized and cached. A message from a self-handle is always allowed; non-self handles must appear in the allowlist.
- **Allowlist** — the set of non-self handles whose messages are captured. Configured in Settings → Allowlist.
- **Reply mode** — one of `.all` (per-message + summary), `.errorsOnly` (failures only), `.off` (silent; `UNUserNotification` fallback for catch-up).
- **Local mode** — the v1 architecture: `chat.db` polling + AppleScript replies. The *only* shipping mode. "Cloud mode" was the original v1 plan, deferred to v1.1 via a VPS-relay design and out of scope here.
- **FDA** — Full Disk Access. The primary onboarding friction point; required to read `~/Library/Messages/chat.db`.

## Hard product commitments

These are not "preferences" — they're load-bearing constraints surfaced in mission.md. Treat any proposal that contradicts one as ADR-worthy.

- **Output neutrality: the folder is the integration surface.** No SDK, no protocol, no vendor coupling on the *consumption* side — any AI/agent that reads files can consume the triaged Markdown. The app may use opt-in AI to *process* captures on the way in (a documented 2026-07 reversal of the original "no built-in AI / no in-app categorizing" commitments — see the [triage-engine shape doc](agent-os/specs/2026-07-13-2230-triage-engine/shape.md)), but the *output* stays plain files any tool can read. Features that would make the output readable only by a specific vendor remain out of scope.
- **Networking is enumerated, opt-in, and inbound-free.** Three outbound paths exist — Sparkle updates (opt-out), the BYO-key Anthropic engine, and link-enrichment fetches (both opt-in, both plain `URLSession` in-repo) — and PRIVACY.md names every networking file. No webhook listener, no server, nothing accepts inbound connections. Any new outbound path must be similarly opt-in, similarly enumerated, and update PRIVACY's grep claim in the same change.
- **No sandbox.** Required for FDA, arbitrary folder writes, and AppleScript control of Messages.app. Distribution is Developer ID-signed + notarized DMG, never Mac App Store.
- **Filing never blocks on optional features.** AI triage, handoff, and enrichment are all strictly best-effort: any failure files the capture deterministically, immediately. A feature that could delay or drop a capture when its dependency misbehaves violates the product's core trust promise.
- **Raw mode is a contract.** The `.raw` escape hatch reproduces the pre-triage behavior byte-for-byte (`<iso-ts>.txt` at the root, no conversion). Downstream scripts written against the old contract keep working there; the default contract is the triaged Markdown tree.

## ADRs

Architectural decisions that diverge from or extend the spec live in [`docs/adr/`](docs/adr/). Empty at the time of writing — the spec itself carries the v1 decision record. New ADRs are produced lazily via `/grill-with-docs` when a decision actually crystallises.
