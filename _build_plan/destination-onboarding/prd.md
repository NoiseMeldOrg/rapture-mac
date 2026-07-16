# Rapture for Mac — Destination Onboarding

> **About these build-plan files:** Everything in `_build_plan/destination-onboarding/` (this PRD and the per-milestone folders) is a **documentation and guidance artifact** for this feature's build-out. These files are **not functional** — no code, configuration, runtime logic, tests, or deployment process should import, read, reference, or depend on anything in `_build_plan/`.
>
> Unlike the bm-prd-creator default, this repo **preserves** `_build_plan/` as a frozen historical record rather than deleting it after build-out (see the repo `CLAUDE.md`). Durable architectural truth lives in `agent-os/specs/` and `agent-os/product/`; this folder is the snapshot of how the work was shaped.

## What we're building

**Rapture should land captures where the user's notes actually live — on day one, not a week later.** The app detects the notes vaults already installed on the Mac and offers them as the destination, contained in a single subfolder so its output never scatters among the vault's own folders; it nudges existing users still sitting on the silent default; and it asks before moving any notes, instead of relocating them invisibly.

The triage engine (v1.0.98) already does the hard part correctly: every capture becomes a classified Markdown note the moment it arrives. This feature is about the *last mile* — the gap between "perfectly triaged" and "actually in my vault."

That gap is not hypothetical. It was measured in a real dogfood: the app's author wanted captures in an Obsidian vault, was never prompted to repoint, and a week of correctly-triaged notes piled up in `~/Documents/Rapture Notes` — stranded outside the vault and synced nowhere. The feature silently did the right thing in the wrong place. He then hand-moved the notes into the vault, unaware the app has shipped automatic, ledger-aware relocation since v1.0.69 — and the hand-move desynced both ledgers (4 of 4 triage records and 2 of 2 enrichment records pointed at files that no longer existed). Every failure in this story is a discoverability failure, not a missing capability.

The stack is unchanged: Swift 5.9+, SwiftUI, macOS 14+, MVVM with `@Observable`, XCTest. The app is not sandboxed, which is why vault detection needs no new entitlement. The build is structured as three milestones, each independently shippable.

---

### What the app does

- **Finds your real notes vault.** Reads Obsidian's own config for vault paths and offers each by name, rather than defaulting silently to a folder you never chose.
- **Suggests sync roots too.** iCloud Drive, Dropbox, and Google Drive folders appear as secondary suggestions — a synced destination is what makes notes reachable from the phone.
- **Falls back gracefully.** No vault found means `~/Documents/Rapture Notes`, exactly as today.
- **Asks on first run.** After Full Disk Access is granted, you choose where notes go. The default folder still exists underneath as a safety net, so a capture arriving before you decide is never lost.
- **Keeps its output contained.** Point at a populated vault and the app offers to nest everything under one container (default: `Rapture Inbox`) instead of scattering `Notes/`, `Links/`, `Tasks/`, `Ideas/`, and `Journal/` among your own top-level folders.
- **Asks before it moves anything.** Changing the folder shows what's about to happen — how many notes move, from where to where, how many hit name collisions — and lets you move them, leave them behind, or cancel.
- **Nudges you off the default.** If a vault is detected and you're still on the default folder, a dismissible notice offers to move. It never switches anything on its own.
- **Rescues a scattered vault root.** If Rapture's folders are already loose in a vault root, it offers to gather them into a container.

---

### Already provided by the existing codebase

This feature **extends** shipped machinery. None of the following is re-specced or rebuilt:

- **`OutputFolderMigrator`** (v1.0.69) — the relocation engine. Same-volume rename, cross-volume copy-verify-delete, merge-never-clobber collisions, note+attachment pairs moved in lockstep, source intact on failure.
- **`AppState.setOutputFolder`** — the orchestration: quiesce via `CaptureGate`, volume guard, migrate, ledger remaps, sidecar write, scaffold seed.
- **`TriageLedger` / `EnrichedLinkLedger`** and their `remap` functions — the "already processed" memory, keyed on destination-relative paths.
- **`DestinationGuard` + the offline spool** — volume-absent vs folder-missing, FIFO queueing while a drive is unplugged, flush on reconnect.
- **`OutputFolderSidecar`** — the public contract at `~/Library/Application Support/Rapture for Mac/output-folder.path` for downstream consumers.
- **`OutputFolderScaffold`** — the opt-in starter `CLAUDE.md` seed.
- **`HandoffEnableFlow` / `AITriageEnableFlow`** — the testable consent pattern (injected prompt closures, persist-on-success) to copy.
- **The `triageIntroShown` menu-bar notice** — the dismissible one-time notice pattern to copy.
- **`PermissionsView`** — the existing Full Disk Access onboarding, which stays as first-run step one.

---

### Out of scope

- **Rebuilding migration** — `OutputFolderMigrator` ships and works. The gap is consent and discoverability, not capability.
- **Security-scoped bookmarks** — the app is unsandboxed; there are zero bookmark usages in the codebase and `tech-stack.md` states explicitly that none is needed. Plain absolute-path URLs in `settings.json` are the shipped design.
- **Note-level dedup for re-dictations** — reported as a bug, but files-always-land is the `mission.md` commitment ("never drop a capture"). Handoff dedup is separate and verified working.
- **Apple Notes, Bear, Notion as destinations** — database-backed, no folder to point at. Filing into them needs an importer, which breaks output neutrality.
- **Obsidian-flavored output** (wikilinks, vault-native frontmatter) — `mission.md`'s hard commitment is that output must never be readable only by one vendor's tool. Detection decides *where* to write, never *how*.
- **Multi-folder or per-class destinations** — `mission.md` commits to one output folder per install.
- **Two-way sync** — Rapture writes notes; it never reads the vault back or reacts to edits.
- **Backfill / re-triage after moving** — bulk re-triage is out of scope per `mission.md`; enrichment set the no-backfill precedent.
- **Following a vault that moves** — relocate your vault in Finder and you repoint. No filesystem surveillance.
- **Touching the vault's existing content** — Rapture never renames, reorganizes, or reads the user's own notes.
- **Installing Obsidian for you** — no vault found means the default folder is the answer.
- **Cloud/remote destinations (S3, WebDAV)** — local paths only; sync engines handle the rest.
- **Vault git backup** — a real feature, but its own PRD, not part of destination onboarding. (Reshaped several times on 2026-07-16: helper app → Rapture-pushes → **Rapture only *watches* the backup and warns when it falls behind, never pushing.** Read-only, no networking. The actual pushing stays with obsidian-git / the user. See [`_build_plan/vault-backup/prd.md`](../vault-backup/prd.md).)

---

### External integrations

**None.** No providers, no credentials, no API keys, nothing to sign up for. Vault detection reads one local JSON file that Obsidian already maintains.

This matters beyond convenience: **this feature adds no outbound network path.** The app's three enumerated paths in `PRIVACY.md` (Sparkle updates, the BYO-key Anthropic engine, the link-enrichment fetcher) stay exactly three, and PRIVACY's grep claim still returns the same three files. Any implementation that would change that is out of scope by definition.

---

### Data model

The destination is already modeled — `outputFolder` in `settings.json` — and containment is just a longer path, so this feature adds almost nothing.

#### PersistedState (`state.json`) — one new field

- **`defaultDestinationNudgeDismissed`** — whether the user has settled the question of the default folder. Set when they either pick "keep the default" at first run *or* dismiss the nudge banner. One flag covers both cases, so someone who deliberately chose the default is never nagged. Defaults to "no". Must decode leniently (`decodeIfPresent ?? false`) — a strict key would wipe every ledger for existing users.

#### Detected vault (in memory only, never persisted)

- **name** — the vault's display name, as the user knows it (e.g. "Second Brain").
- **path** — where it lives on disk.
- **source** — how it was found (an Obsidian vault, or a sync root like iCloud/Dropbox).
- **reachable** — whether its drive is connected right now.

Detected vaults are re-read each time the picker opens, never cached. A vault added tomorrow shows up without a stale entry, and a drive unplugged five seconds ago shows as unreachable immediately.

---

## Milestone 1 — Vault-Aware Destination

Teaches the existing "change your notes folder" path to know about vaults, contain its output, and ask before moving. Delivered entirely through Settings → General, which already exists. This milestone alone would have prevented the stranded-week problem.

### What gets built

- The folder picker offers **detected vaults by name** ("Second Brain — Obsidian vault") alongside "Choose another folder…" and the current default.
- Sync roots (iCloud Drive, Dropbox, Google Drive) appear as secondary suggestions when present.
- A vault on a **disconnected drive is shown but not selectable**, with the reason stated plainly ("drive not connected") — never hidden, so detection never looks broken.
- Choosing a **populated folder** offers to contain output under a single subfolder, with an editable name defaulting to `Rapture Inbox`.
- If that container name **already exists**: adopt it when it's empty or already looks like a Rapture tree; when it holds unrelated content, say so and suggest a different name rather than mixing in.
- Choosing an **empty or already-Rapture folder** uses it directly, with no containment prompt.
- Changing the folder shows a **consent step first**: how many notes will move, from where to where, and how many will be renamed for collisions.
- Consent offers three choices: **Move them**, **Leave them behind**, or **Cancel**. Cancel changes nothing. "Leave them behind" switches the folder and **prunes the ledger records for the notes left behind**, so the app forgets them cleanly instead of holding paths that no longer resolve.
- The sidecar path always reflects the **final** destination, including the container subfolder.

### What milestone 1 explicitly does NOT include

- Any change to first launch — the default folder is still created silently on first run.
- The default-folder nudge, or any proactive notice.
- The vault-root rescue for already-scattered users.
- Any change to how notes are named, formatted, or classified.
- Any new network call, credential, or entitlement.

### Done when

You can open Settings → General, see your real Obsidian vault offered by name, pick it, be offered `Rapture Inbox` as a container, see exactly what's about to move, and decline or accept — with the notes ending up where you chose, the ledgers still resolving, and the sidecar pointing at the container. Unplugging the drive and reopening the picker shows the vault as unreachable rather than gone.

---

## Milestone 2 — First-Run Destination Flow

Replaces the silent default with an actual question, in the one place where asking prevents a week of stranded notes.

### What gets built

- After Full Disk Access is granted, the app **asks where notes should go** — the FDA window stays step one, because the app is useless without it.
- The choice presents detected vaults (using milestone 1's detection), "Choose another folder…", and an explicit **"Keep the default"** option.
- Picking a vault runs milestone 1's containment offer and migration consent.
- Choosing "Keep the default" is a real, respected answer — it settles the question permanently, and no nudge ever appears.
- The **default folder is still created underneath as a safety net**, so a capture arriving before the choice is made lands safely and migrates when the user picks. Nothing is ever lost or stranded, and no capture waits on a decision.
- Dismissing the choice without answering leaves the default in place and leaves the question open, so the nudge can raise it later.

### What milestone 2 explicitly does NOT include

- Changing, restyling, or reordering the Full Disk Access step itself.
- Blocking capture on the destination choice — captures always have somewhere to land.
- The nudge or the vault-root rescue.
- Any onboarding beyond the destination question (no tour, no feature intro).

### Done when

A clean install (fresh containers, no `settings.json`) walks from launch → FDA grant → destination choice → notes landing in the chosen vault, contained. Dictating a note *before* answering still files safely to the default and moves when the choice is made.

---

## Milestone 3 — Nudges & Vault-Root Rescue

Reaches the users milestones 1 and 2 can't: everyone who already installed Rapture and is sitting on a silent default, or scattered across a vault root.

### What gets built

- A **dismissible menu-bar notice** for anyone still on the default folder when a vault is detected: names the vault, offers to move, dismisses forever. Uses the same slot and shape as the existing triage-intro notice.
- A **quiet, permanent line in Settings → General** ("Notes are going to the default folder · Change…") that survives dismissal — so the offer stays discoverable without nagging.
- Neither surface ever switches the destination on its own; both route into milestone 1's containment and consent.
- The notice never appears when no vault is detected (nothing to offer), or once the question is settled.
- **Vault-root rescue:** when the destination is a vault root (a sibling `.obsidian/` gives it away) and Rapture's folders are sitting loose among the vault's own, the same notice shape offers to gather them into a container.
- The rescue works despite the migrator refusing nested paths — moving `<vault>` to `<vault>/Rapture Inbox` is rejected outright today, so this path needs its own mechanism.

### What milestone 3 explicitly does NOT include

- Repeated or recurring nagging — each notice is dismissible and stays dismissed.
- Any notice when no vault is detected.
- Auto-switching, auto-containing, or auto-moving under any condition.
- Rescuing anything other than Rapture's own folders — the vault's content is never touched.

### Done when

An existing install pointed at the default folder, with a vault present, shows the notice on next launch; dismissing it hides it forever while the Settings line remains. A destination set to a vault root with scattered Rapture folders offers the rescue, and accepting gathers them into `Rapture Inbox` with the ledgers still resolving.
