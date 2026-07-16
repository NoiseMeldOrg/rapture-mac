# Rapture for Mac — Vault Git Backup

> **About these build-plan files:** Everything in `_build_plan/vault-backup/` is a documentation and guidance artifact for this feature's build-out. It is **not functional** — no code, configuration, runtime logic, tests, or deployment process should import, read, reference, or depend on anything in `_build_plan/`.
>
> This repo **preserves** `_build_plan/` as a frozen historical record (see the repo `CLAUDE.md`). Durable architectural truth lives in `agent-os/specs/` and `agent-os/product/`.
>
> **Decisions in this PRD were made by the planning agent under an explicit "do whatever you think best" delegation (2026-07-16), not an interactive interview.** Each non-obvious call is written with its rationale so the building agent — and the user reviewing later — can see why. Where a call is genuinely the user's to make, it's flagged as a recommended default, changeable.

## What we're building

**Rapture keeps the destination safe by version-controlling it — automatically, on any drive, and visibly.** When the notes folder lives inside a git repository (typically an Obsidian vault pushed to a private GitHub repo), Rapture commits and pushes that repository on its own, so a week of captures is never one disk failure away from gone. It works identically whether the vault is on the internal disk or an external volume, defers cleanly when an external drive is unplugged, and — critically — **surfaces its status where you can see it**, because a backup that fails silently is worse than no backup at all.

This is a **reversal of an earlier plan.** The first instinct was a separate signed helper app driven by `launchd`. That was wrong for this app's goals. Rapture already *is* a Developer ID-signed, Full-Disk-Access, continuously-running app that writes to both internal and external volumes and already survives its own updates without losing permissions. A helper app would reconstruct all of that, worse — and being headless, it would fail *silently*, which is the exact disease that let the previous backup mechanisms (a `launchd` nightly job and the obsidian-git plugin) go three days making zero commits with nobody noticing. Rapture has a menu bar and a Settings window; putting backup status there is the whole point.

The stack is unchanged: Swift 5.9+, SwiftUI, macOS 14+, MVVM with `@Observable`, XCTest. The app is unsandboxed and already spawns subprocesses (`osascript` via `Process`); `git` is the same mechanism. The build is two milestones.

---

### What the app does

- **Backs up the vault automatically.** When the notes folder is inside a git repo, Rapture commits new content and pushes it to your remote — no plugin, no cron, no second app.
- **Works on internal and external drives, uniformly.** The same code path handles both. On an external drive that's unplugged, backup defers exactly like captures defer, and runs when the drive returns.
- **Never fails silently.** Last-backup time and last error appear in the menu bar and Settings. A push that's rejected, a drive that's gone, an auth failure — you see it, you're not left guessing three days later.
- **Respects your `.gitignore`.** It stages with plain `git add -A`, never `-f`, so the secrets you deliberately keep out of the repo (a `Security/` folder, an SSN note, plugin files with API keys) stay out.
- **Handles the fact that other things commit too.** Obsidian, AI coding sessions, and you all commit to this vault. When the remote has moved ahead, Rapture rebases and retries instead of dying on a rejected push.
- **Stays off until you turn it on.** Opt-in, off by default. When on but the destination isn't a git repo, it's simply inert and says so.

---

### Already provided by the existing codebase

This feature **extends** shipped machinery:

- **`Process` subprocess invocation** — `AppleScriptSender` already runs `osascript` via `Foundation.Process` with a controlled environment. `git` invocation mirrors it: explicit executable path, explicit environment, no login shell.
- **`DestinationGuard` + `DestinationMonitor` + the offline spool** — the volume-present-vs-absent classification and the 2s remount poll. "Defer the backup while the drive is unplugged, run it when it remounts" is the same behavior captures already have, reused rather than reinvented.
- **The menu-bar status line and Settings error surfaces** — `appState.lastError` / `aiLastError` / `enrichmentLastError` / `handoffLastError` and the About-tab diagnostics already render "last time / last error." Backup status is a new member of that family, not a new UI pattern.
- **`OutputFolderSidecar`** — the resolved output-folder path. Repo-root discovery walks up from there.
- **`CaptureGate`** — the quiesce primitive, if a backup must not overlap a relocation.
- **`RuntimeEnvironment.isRunningXCTests`** — the front-guard every side-effecting subsystem uses so the test host never spawns real `git` or touches the network.
- **The `settings.json` / `state.json` atomic-write persistence and lenient-decode conventions** — the new setting and the last-backup state follow them.

---

### Out of scope

- **A separate helper app or `launchd` job** — the rejected alternative. The whole point of this PRD is that Rapture does it.
- **Being the git client for repos unrelated to the notes destination** — Rapture backs up the repo the notes folder lives in, nothing else. No general-purpose "add a repo to back up" list.
- **Switching the user's remote for them, or creating repos** — the app detects and reports the remote; the SSH-remote switch is a documented setup step, not something the app performs silently on the user's repo. (For this install it was done by hand on 2026-07-16.)
- **Resolving genuine merge conflicts** — Rapture rebases and retries a rejected push; a real content conflict is surfaced as an error for the human to resolve, never auto-merged or force-pushed.
- **`git add -f` / bypassing `.gitignore`** — never. The ignore rules protect real secrets.
- **Pull/restore/rollback UI** — this is a backup writer, not a git client. Restoring from history is done in git or Obsidian by the user.
- **Backing up while Rapture is quit** — Rapture backs up while it runs (it launches at login and runs continuously). Vault edits made in Obsidian while Rapture is quit are captured at the next backup after Rapture is running again. A truly always-on daemon is explicitly not what this is.
- **Configurable commit messages, branches, or multiple remotes** — one commit-message format, the repo's current branch, the repo's `origin`. Not a git power-tool.
- **Encrypting the backup** — the repo is what it is; encryption is the user's remote's concern.

---

### Network posture (this changes PRIVACY — read carefully)

This feature adds the app's **fourth** outbound path, and it's different in kind from the first three: a `git push` is a **subprocess** (`/usr/bin/git`), so it is invisible to PRIVACY.md's `grep URLSession\.` verification. That grep must be kept honest.

Three things bound the cost:

1. **No new recipient or exposure.** The push goes only to the git remote the user already configured and already pushes to by hand — their own private repo. The vault is already on GitHub; Rapture pushing it sends data nowhere it doesn't already go. This is materially *less* exposing than the existing Anthropic path, which sends note text to a third party.
2. **Opt-in, off by default**, like the AI and enrichment paths.
3. **Confined and named**, the same discipline already used for networking: all `git` invocation lives in one file (e.g. `VaultBackup/GitBackupRunner.swift`), PRIVACY enumerates it as the fourth path, and the verification gains a **second grep** for the subprocess invocation (e.g. the `git` executable path / `Process` launch) confined to that file — mirroring how `AnthropicEngine` confines `URLSession`. The claim grows from "one mechanism, three files" to "two mechanisms, four files, all named."

Per the repo `CLAUDE.md`, any new networking must update PRIVACY's grep claim **in the same change** as the code. This is a hard requirement of the feature, not a follow-up.

---

### Data model

#### Settings (`settings.json`) — one new field

- **`vaultBackupEnabled`** — whether automatic backup is on. Off by default. Decoded leniently (`decodeIfPresent ?? false`) so existing `settings.json` files load.

#### PersistedState (`state.json`) — backup status

- **`lastVaultBackupAt`** — when the last successful commit+push completed (for the "last backup: 2h ago" line). Optional; nil until the first success.
- **`lastVaultBackupError`** — the last failure, human-readable, cleared on the next success (mirrors how the other `last*Error` transients behave, but persisted so it survives a relaunch — a failure the user hasn't seen yet must not vanish on restart). Optional.
- Both decoded leniently; a strict key would wipe existing users' ledgers via `StateStore.load`'s fresh-state fallback.

#### Derived, never persisted

- **The repo root** — discovered at runtime by walking up from the output folder until a `.git` directory is found. Not stored; the output folder can change and the repo root is always re-derived from the current one.

---

## Milestone 1 — The Backup Engine

Rapture commits and pushes the vault on its own, reliably, on any drive, with its status visible. This is the whole working feature for the real-world path: new captures land, get backed up shortly after, and you can see that it happened.

### What gets built

- A new setting, **Settings → General → "Back up my notes folder to git"** (near the output folder, because it's destination safety), off by default, with a one-line explanation and — when the destination isn't a git repo — an inert status saying so.
- **Repo-root discovery**: walk up from the output folder until a `.git` directory is found; if none, the feature is inert and says "No git repository at the destination." (Works identically for internal and external paths.)
- **The backup run**: `git add -A` (respecting `.gitignore`, never `-f`) → commit only if something is staged (skip quietly when nothing changed) → push. Commit message is a fixed format with an ISO 8601 timestamp.
- **Divergence handling**: on a non-fast-forward push rejection (because Obsidian, an AI session, or the user pushed in between), rebase onto the updated remote and retry the push once. A genuine conflict that rebase can't resolve is surfaced as an error, never force-pushed.
- **In-flight guard**: never two backups at once; if one is running, the next trigger is skipped (not queued deep).
- **Offline-aware**: when the destination volume is absent (`DestinationGuard`), the backup defers and runs when the drive remounts (`DestinationMonitor`) — the same behavior captures already have. This is what makes internal and external drives one code path.
- **Trigger**: a debounced run shortly after capture activity settles (the natural "there's new content to back up" signal), plus a daily floor so an idle day still gets a snapshot.
- **Status, visibly**: last-backup time and last error in the menu bar popover and in Settings. This is a hard requirement — the feature's reason for living in Rapture instead of a headless job.
- All `git` invocation confined to one file, XCTest-front-guarded so the suite never spawns `git` or hits the network.

### What milestone 1 explicitly does NOT include

- Any UI for choosing what to back up, the commit message, the branch, or the remote.
- Auth setup assistance or HTTPS-vs-SSH guidance (milestone 2).
- Restore, rollback, history browsing, or conflict *resolution* UI.
- The full documentation rewrite (milestone 2) — though the setting's own copy must be truthful.

### Done when

With backup on and the notes folder inside a git repo on a **connected** drive: dictate a capture, and within the debounce window a commit lands and pushes, with "last backup: just now" visible in the menu bar. Unplug an external drive, capture (it spools), replug — the backup runs on remount. Make a commit from another clone and push it, then trigger a Rapture backup — it rebases and succeeds rather than failing on rejection. Turn backup on with the destination *not* in a git repo — the app says so and does nothing. Throughout, the test suite spawns no real `git` and makes no network call.

---

## Milestone 2 — Auth Reliability, Failure UX & Docs

Makes the feature trustworthy for someone who isn't watching it, and tells the truth in the docs. This is the milestone that separates "works on my machine" from "works on a stranger's HTTPS-remote vault, and they know when it doesn't."

### What gets built

- **Remote diagnosis**: detect whether the repo's remote is SSH or HTTPS, and when a push fails on auth, surface a specific, actionable message (HTTPS + credential-helper failures are the classic silent killer — name the fix, don't just say "push failed"). The app does **not** rewrite the user's remote; it guides.
- **Auth-failure surfacing**: an authentication failure is a first-class, visible error state with a plain-language explanation, distinct from "drive offline" or "nothing to commit."
- **Divergence-failure surfacing**: when rebase-and-retry can't resolve a conflict, a clear "your vault and its remote have diverged in a way I won't auto-merge — resolve it in git/Obsidian" message, never a force-push.
- **The documentation pass** (mandatory, per repo `CLAUDE.md`, in the same change as any code it describes):
  - **PRIVACY.md** — the fourth outbound path (git push, opt-in, to the user's own configured remote), the second grep for the `git` subprocess confined to its one file, the "two mechanisms, four files" framing, re-verified verbatim.
  - **SECURITY.md** — the new capability and its `.gitignore`-respecting, never-`-f` guarantee.
  - **README.md** — the backup story: capture → triage → *and it's version-controlled off-site*.
  - **tech-stack.md** — `git` via `Process` as an enumerated outbound capability.
- Whether this warrants a dated `agent-os/specs/` folder and a `roadmap.md` line as durable truth (the triage engine's M5 backport is the precedent).

### What milestone 2 explicitly does NOT include

- Automatic remote rewriting, key generation, or GitHub API calls.
- A credential manager or in-app key storage (SSH keys live in `~/.ssh`, the user's domain).
- Conflict resolution — still surfaced, never performed.

### Done when

A vault whose remote is HTTPS and whose credential helper can't authenticate headlessly produces a specific, actionable error in Settings (not a generic failure), and switching that remote to SSH per the guidance makes backup succeed. PRIVACY's grep verification, run verbatim, returns the four named files across the two mechanisms and nothing else. README, SECURITY, and tech-stack describe the shipped behavior.
