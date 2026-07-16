# Milestone 1 — The Backup-Health Watchdog

You are entering plan mode to plan and then build this feature (a single milestone).

## Context

- Read `@_build_plan/vault-backup/prd.md` in full, **including the "reshaped twice" note at the top.** The one-sentence version: Rapture **watches** whether the notes folder's git backup is current and warns loudly if it's fallen behind — it never commits, pushes, fetches, authenticates, or opens a socket. The actual backup is done by something else (obsidian-git, a `launchd` job, hand-commits); Rapture only observes.
- This is the whole feature. There is no prior milestone.

### The non-negotiable boundary

**Rapture reads git state, read-only, over no network. It never mutates the repo or contacts a remote.** No `git add`, `commit`, `push`, `fetch`, `pull`. No credentials, no keys. If you find yourself planning auth, rebase, or a fourth outbound path, you've drifted back into the *previous* (rejected) design — stop and re-read the PRD's "Out of scope." The feature's whole value is that it has **zero** networking and security surface: PRIVACY's `grep URLSession\.` claim must still return exactly three files afterward, and you should be able to state plainly "this feature opens no socket."

### Repo truth (the PRD is the *what*; these are the *how*)

- **`@CLAUDE.md`** — repo conventions. Load-bearing here: **tests run inside the app**, so gate the git-state reader behind `RuntimeEnvironment.isRunningXCTests` (the `SystemEventKitClient` pattern) so the test host never spawns real `git`. Also: any new networking must update PRIVACY's grep claim — you are adding *no* networking, so state that explicitly in the milestone log as a verification result.
- **`@agent-os/product/mission.md`** — "the folder is the UI" and the destination-health framing. This feature is the same family as the existing "destination offline — N queued" signal: it reports on the safety of the notes Rapture captured, it does not become a general backup tool.

### The exact files to read and touch

- **`RaptureMac/RaptureMac/Reply/AppleScriptSender.swift`** — the existing `Foundation.Process` pattern (explicit executable path, controlled environment, no login shell). Your git-state reader mirrors it but runs only **read-only** commands (`git -C <root> status --porcelain`, `git -C <root> rev-list --count @{u}..HEAD`, `git -C <root> log -1 --format=%ct`). Set an explicit `PATH`, exec `/usr/bin/git` directly.
- **`RaptureMac/RaptureMac/UI/MenuBarView.swift`** — the status block. The "backup behind" warning is an additional caption line (see the destination-offline caption at `MenuBarView.swift:48` for the shape), **not** a new `MenuBarStatus.Kind` (`MenuBarStatus.Kind` is a closed enum, and capture is still working — it's the *destination's backup* that's stale). Healthy → render nothing here.
- **`RaptureMac/RaptureMac/UI/SettingsGeneralView.swift`** — `outputFolderSection`, alongside `destinationOfflineStatusView` / `relocationStatusView`. The plain-language backup-health line and the on/off toggle live here, near the output folder, because this is destination health.
- **`RaptureMac/RaptureMac/Models/Settings.swift`** — add `vaultBackupWarningsEnabled`, **default OFF** via `decodeIfPresent(...) ?? false` (consistent with the app's opt-in posture; the audience is technical and will find the toggle). This switch governs **only the loud menu-bar warning** — the passive Settings status line shows whenever the destination is a git repo regardless of the toggle. It is the switch answering the user's request to have the warning off by default and turn-off-able.
- **`RaptureMac/RaptureMac/Writer/DestinationGuard.swift`** — reuse `classify` for "volume absent → can't check, not a failure." Do not write a second reachability rule.
- **`RaptureMac/RaptureMac/Persistence/OutputFolderSidecar.swift`** — repo-root discovery walks up from the *current* output folder (read live, don't cache — the folder can change).
- **`RaptureMac/RaptureMac/App/Pipeline.swift`** and the app's existing poll cadences (e.g. `DestinationMonitor`'s timer) — the staleness check is cheap and infrequent; hang it off an existing low-frequency tick or a lightweight timer rather than inventing heavy machinery. It can also re-check after capture activity settles.
- **New code**: a small folder, e.g. `RaptureMac/RaptureMac/VaultBackup/`, holding the injected git-state-reader protocol + its `Process` implementation + the pure staleness-evaluation logic. Folder-sync project — **no pbxproj edits**.
- **`README.md`** — one line: Rapture warns when the notes folder's git backup falls behind. (No PRIVACY/SECURITY rewrite — there's no networking to disclose. Confirm PRIVACY's grep still returns three files as a verification step.)

### Locked design decisions (do not re-litigate)

- **Read-only, no network, ever.** (Restated because it's the whole point.)
- **Default OFF, with an on switch** (`vaultBackupWarningsEnabled`) that governs the **menu-bar warning only**. The passive Settings status line always shows when the destination is a git repo. So: toggle off → Settings shows status, menu bar stays silent; toggle on → Settings shows status AND the menu bar warns when at risk. Quiet when healthy either way.
- **"At risk" = uncommitted or unpushed work that's persisted longer than a grace threshold** comfortably above a normal backup cadence (**default ~24h**; a fixed default, not a UI knob in this milestone). Gracefully degrade when the repo has no upstream/remote (then `@{u}..` is undefined — fall back to commit-age only, or stay quiet, but never crash).
- **Inert when the destination isn't a git repo** — a calm Settings line, not an error, and nothing in the menu bar.
- **Mechanism-agnostic** — never assume obsidian-git specifically; read the repo result, not any tool's state.

### Verified facts — don't re-derive

- The staleness signal is readable with **zero network calls** — confirmed live on the real vault 2026-07-16 (`git status --porcelain`, `rev-list --count @{u}..HEAD`, `log -1 --format=%ct` are all local; a successful `git push` advances the local `origin/*` ref, so `@{u}..HEAD` reflects push success without a fetch).
- The app is **unsandboxed** and already spawns `Process`; read-only `git` needs no new entitlement.
- The real vault is on an **external USB volume** with the output folder (`Rapture Inbox`) *inside* it — so repo-root discovery genuinely must walk *up* past the output folder. Do not assume output folder == repo root.

## Your task

1. Plan the implementation. If any part of the plan mutates the repo or opens a network connection, it's wrong — re-scope to read-only.
2. After the user confirms, build it.
3. Verify against "Done when." Tests are **mandatory**, run with **no real `git` and no network** (inject the git-state reader behind a protocol, like `EventKitClient`/`LinkFetcher`). Cover: repo-root discovery (found above the output folder; output folder *is* the root; no `.git` → inert), the staleness evaluation (current vs at-risk, the grace threshold, the no-upstream degradation), the volume-absent "can't check" state, and the toggle silencing the warning. As a verification step, re-run PRIVACY's `grep URLSession\.` and confirm it still returns exactly three files.
4. When complete, write a `milestone-log.md` in this folder:
   - **Start with `## What's new in the app`** — the user-facing change (Rapture now warns you when your notes folder's backup falls behind; you can turn it off), framed as a capability.
   - Then: what was built (the reader protocol seam, the staleness logic, the trigger cadence), decisions not pre-specified, the confirmed "no networking added / PRIVACY unchanged" verification result, and any deviations from the PRD and why.

Ask clarifying questions with the AskUserQuestion tool to lock the plan.
