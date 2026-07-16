# Rapture for Mac — Destination Backup Health (Watchdog)

> **About these build-plan files:** Everything in `_build_plan/vault-backup/` is a documentation and guidance artifact for this feature's build-out. It is **not functional** — no code, configuration, runtime logic, tests, or deployment process should import, read, reference, or depend on anything in `_build_plan/`.
>
> This repo **preserves** `_build_plan/` as a frozen historical record (see the repo `CLAUDE.md`). Durable architectural truth lives in `agent-os/specs/` and `agent-os/product/`.
>
> **This PRD was reshaped twice under a "do whatever you think best" delegation, and the evolution is the point of the design — keep it visible:**
> 1. First scoped (2026-07-16) as a separate signed `launchd` **helper app** to git-push the vault.
> 2. Reversed to **Rapture doing the git push itself**, because Rapture already is the signed, Full-Disk-Access, always-running, both-drive-types app a helper would reconstruct.
> 3. Reversed again, on the user's challenge, to **Rapture only *watching* the backup, never pushing** — because the one real benefit of Rapture pushing (backing up while Obsidian is closed) barely applies when Obsidian is usually open, while the costs (a fourth outbound path concentrated in the message-reading app, git auth/key/divergence surface, scope drift) are real. The purpose-built tool (obsidian-git, on an SSH remote) does the pushing; Rapture supplies the one thing that was actually missing — **loud, always-on detection when backup falls behind.**

## What we're building

**Rapture tells you the truth about whether your notes are safely backed up — because a backup you can't see the status of is a backup you can't trust.** When the notes folder lives inside a git repository, Rapture reads that repo's *local* state (no network, no pushing, no keys) and — if the vault has gone too long with uncommitted or unpushed work — raises a loud warning in the menu bar. That's it. It never commits, never pushes, never touches a remote. Whatever mechanism actually does the backup (the obsidian-git plugin, a `launchd` job, your own hand-commits) keeps doing it; Rapture just verifies it's happening and shouts when it isn't.

This exists because of a real, measured failure: the vault's backup silently stopped for **three days** and nobody noticed — obsidian-git failed quietly, its own status indicator (a small icon in Obsidian's status bar) was too easy to miss, and the loss of trust that follows "was my stuff even being saved?" is the whole problem. Rapture is already the always-running app looking at your vault; making it the thing that notices — and says so where you'll actually see it — is a small, on-mission addition. It is destination health, the same family as the "destination offline — N queued" status Rapture already shows.

The stack is unchanged: Swift 5.9+, SwiftUI, macOS 14+, MVVM with `@Observable`, XCTest. The build is a single milestone.

---

### What the app does

- **Notices when your backup falls behind.** If the notes folder is a git repo and it's been too long with work that isn't safely committed and pushed, Rapture shows a clear warning in the menu bar — where an always-visible, always-running app can't be missed the way a buried plugin icon can.
- **Reads only, over no network.** It inspects the repo's *local* git state (last commit, uncommitted changes, whether local commits have been pushed as far as the local tracking ref knows). It never commits, pushes, fetches, authenticates, or opens a socket. **This feature adds zero networking; PRIVACY is unchanged.**
- **Doesn't care how you back up.** obsidian-git, a scheduled job, hand-commits — Rapture is mechanism-agnostic. It verifies the *result* (the repo is current), so it keeps working if you change your backup approach later.
- **Stays quiet when things are fine.** No news is no noise: a healthy repo shows at most a subtle "backed up: 2h ago" in Settings, nothing in the menu bar. It speaks up only when there's a real problem.
- **Is inert when there's nothing to watch.** If the notes folder isn't inside a git repo, the feature does nothing and says so in Settings — no false alarms.

---

### Already provided by the existing codebase

This feature **extends** shipped machinery and adds almost no new surface:

- **`Process` subprocess invocation** — `AppleScriptSender` already runs a subprocess with a controlled environment and no login shell. Reading git state runs `/usr/bin/git` the same way, **read-only** (`status`, `log`, `rev-list`), never a mutating command.
- **The menu-bar status surface** — `MenuBarView`'s status block already renders warning states (FDA-needed, destination-offline). The "backup is behind" warning is a sibling of those, not a new pattern. `MenuBarStatus.Kind` is a closed enum; treat the backup warning as an additional caption line, not a new `Kind` (capture is still working — the *destination's backup* is what's stale).
- **`DestinationGuard` + `OutputFolderSidecar`** — repo-root discovery walks up from the current output folder (read live) until a `.git` directory is found; volume-absent handling means an unplugged external vault is "can't check right now," not "backup failed."
- **`RuntimeEnvironment.isRunningXCTests`** — the front-guard so the test host never spawns real `git`.
- **The `settings.json` lenient-decode convention** — the one new setting follows it.

---

### Out of scope

The entire *doing* of backup is out of scope — that is the heart of this reshape:

- **Committing, pushing, or touching a remote** — Rapture never runs `git add`, `git commit`, `git push`, or `git fetch`. The backup is performed by obsidian-git (or a `launchd` job, or the user). Rapture only observes.
- **Auth, credentials, SSH keys** — Rapture holds no key and performs no authenticated operation, so there is nothing to store, rotate, or leak. (The vault's remote was switched HTTPS→SSH by hand on 2026-07-16 so the *actual* pusher authenticates reliably; that is the pusher's concern, not Rapture's.)
- **Divergence / conflict handling, rebases, force-pushes** — none; Rapture never writes to the repo.
- **A fourth outbound network path** — explicitly avoided. This was the decisive reason to reshape away from Rapture-pushing: reading local git refs needs no network, so PRIVACY's "three outbound paths, grep three files" claim stays exactly as it is.
- **Fixing a broken backup** — Rapture *alerts*; it does not repair. The fix (open Obsidian, run a commit, re-check the plugin) was always easy once known; not-knowing was the problem.
- **Backing up non-git destinations** — if the notes folder isn't a git repo, there's nothing to watch; the feature is inert, not an error.
- **Watching repos other than the notes destination** — Rapture watches the repo its own output lives in, nothing else.
- **A general git status / history / diff UI** — this is a single health signal (behind / current), not a git client.

---

### Network posture

**None.** This feature makes no outbound connection of any kind — it reads local git state via read-only subprocess calls. The app's three enumerated outbound paths (Sparkle, the BYO-key Anthropic engine, the link-enrichment fetcher) are unchanged, and PRIVACY.md's `grep URLSession\.` verification still returns the same three files. The only doc touch is a short README line noting Rapture warns when the notes folder's backup falls behind.

---

### Data model

#### Settings (`settings.json`) — one new field

- **`vaultBackupWarningsEnabled`** — whether the **loud menu-bar warning** is shown. **Defaults to off** (`decodeIfPresent ?? false`), consistent with the app's opt-in posture for everything past core capture. The audience is technical (a git-backed vault is set up deliberately), so an opt-in toggle is discoverable to exactly the people who'd want it, and an unrequested nag from a capture tool about git hygiene is avoided.

  The toggle governs **only the menu-bar warning**. The **passive status line in Settings** (near the output folder) is shown whenever the destination is a git repo *regardless of the toggle* — "Backed up · 2h ago" / "27 changes uncommitted for 2 days" / "Destination isn't a git repository." So the information is always one glance away for anyone who opens Settings (no nag, no discoverability cliff), and turning the toggle on escalates it to the always-visible menu-bar safety net. Off by default, not invisible.

Everything else is computed live from the repo at check time and nothing else is persisted — there is no state to keep stale, and no risk of a saved "healthy" flag masking a real problem.

#### The staleness signal (derived, never persisted)

Read with no network:
- **Uncommitted work** — `git status --porcelain` is non-empty.
- **Unpushed commits** — `git rev-list --count @{u}..HEAD` > 0 (uses the *local* remote-tracking ref, which a successful `git push` advances locally — so this reflects whether the last push worked, with no fetch).
- **Age** — how long the repo has continuously been in an un-backed-up state (via last-commit time and/or how long the working tree has been dirty), so a normal same-session edit doesn't trigger a warning.

"At risk" = there's uncommitted or unpushed work **and** it's been that way longer than a grace threshold comfortably above a normal backup cadence (proposed default ~24 hours; tunable, and gracefully degraded for repos with no upstream/remote — where "unpushed" is undefined and only commit-age applies).

---

## Milestone 1 — The Backup-Health Watchdog

Rapture notices when the notes folder's git backup has fallen behind and says so loudly, reading only local state over no network. This is the whole feature.

### What gets built

- **Repo-root discovery**: walk up from the current output folder until a `.git` directory is found. None found → inert, with a Settings line saying the destination isn't a git repo. (Same discovery for internal and external paths.)
- **A no-network staleness check**: read `git status --porcelain`, `git rev-list --count @{u}..HEAD` (guarded for repos with no upstream), and last-commit time — all read-only, all local. Determine "current" vs "at risk (behind for > threshold)."
- **A loud menu-bar warning when at risk — only if the toggle is on** (`vaultBackupWarningsEnabled`, default off): a clear caption in the menu-bar popover — e.g. *"⚠︎ Notes folder not backed up in 2 days"* — in the same visual family as the existing offline/FDA warnings. Nothing in the menu bar when healthy, and nothing in the menu bar at all when the toggle is off.
- **A Settings line, always shown when the destination is a git repo** (Settings → General, near the output folder — this is destination health), *independent of the toggle*: current state in plain language ("Backed up · last commit 2h ago", "⚠︎ 27 changes uncommitted for 2 days", or "Destination isn't a git repository — nothing to back up"), plus the on/off toggle that governs the menu-bar warning.
- **Volume-aware**: if the destination volume is absent (`DestinationGuard`), the state is "can't check — drive not connected," never a false "backup failed."
- All `git` invocation is read-only and confined to one file, XCTest-front-guarded so the suite spawns no real `git`.

### What milestone 1 explicitly does NOT include

- Any mutating git operation — no commit, push, fetch, or remote contact of any kind.
- Any credential, key, or auth handling.
- Fixing or performing a backup.
- A configurable threshold UI, snooze, or per-repo settings (a sensible fixed default; revisit only if it proves noisy).
- Any change to PRIVACY's grep claim (there is no networking to disclose) beyond the one README line.

### Done when

With the notes folder inside a git repo that has uncommitted or unpushed work older than the threshold, the Settings status line shows the at-risk state in plain language (always, regardless of the toggle), and — with the warnings toggle on — a clear menu-bar warning also appears; with the toggle off (the default), the menu bar stays silent. No network call is made in either case (verifiable: the check touches no socket). Bring the repo current (commit + push from any tool) and, on the next check, the state returns to "backed up" on its own. Point the destination at a folder that isn't a git repo and the feature goes quiet and says so. Unplug an external vault and the state reads "can't check — drive not connected," not a failure. The test suite spawns no real `git` (the git-state reader is injected behind a protocol) and makes no network call.
