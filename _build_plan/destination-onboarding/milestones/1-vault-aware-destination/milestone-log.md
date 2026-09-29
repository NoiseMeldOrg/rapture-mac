# Milestone 1 — Vault-Aware Destination: log

## What's new in the app

- **Change… lists your real places.** Settings → General → Change… is now a menu: your Obsidian vaults by name ("Second Brain — Obsidian vault"), then iCloud Drive, Dropbox, Google Drive and OneDrive when present, then the default folder, then Choose Another Folder….
- **A vault on an unplugged drive still shows,** marked "(drive not connected)" and not pickable.
- **Your vault stays tidy.** Picking a folder that already has your own files (or any Obsidian vault) offers to keep Rapture's folders together in one subfolder, "Rapture Inbox" by default, with an editable name. A name already used by other files is refused, and the next free name ("Rapture Inbox 2") is suggested.
- **Rapture asks before it moves notes.** Changing folders shows how many notes move, from where to where, and how many get a number added because a file with that name is already there. Choices: Move Them, Leave Them Behind, Cancel. Cancel changes nothing.
- **Leave Them Behind** switches folders, keeps the old notes where they are, and makes Rapture forget them cleanly.
- The Activity window records the move (or the notes left behind).

## For the next milestone

**Built (new folder `RaptureMac/RaptureMac/Destination/`):**
- `DestinationDetector` — pure over an injected `Environment` (home, Obsidian config URL, `DestinationGuard`, directory lister). `parseObsidianVaultPaths` (malformed/missing/empty → `[]`, absolute paths only). `vaults(in:)`: `.available` → reachable, `.volumeAbsent` → listed unreachable, `.folderMissing` → skipped (stale Obsidian entry). `syncRoots(in:)`: iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`), and under `~/Library/CloudStorage`: `Dropbox*`, `GoogleDrive-*/My Drive`, `OneDrive-*`. `detect()` = vaults (sorted) + sync roots. `Environment.live` for production.
- `Containment` — `decide(entries:)` (`.obsidian` present or unrelated visible items → `.offerContainer`; empty or Rapture-shaped → `.useDirectly`), `checkContainer(entries:)` (`nil`/empty/ours → `.adopt`, else `.conflict`), `looksLikeRaptureTree` (class folders, `CLAUDE.md`, ISO-named raw captures), `sanitizedContainerName`, `defaultContainerName = "Rapture Inbox"`.
- `DestinationChangeFlow` — `resolveTarget(chosen:prompt:listDirectory:)` (HandoffEnableFlow shape, injected prompt, re-asks with a `problem` and the next free name on conflict), and `change(to:appState:prompt:consent:)`: the one entry point used by the menu, Choose Another Folder…, and folder drop.
- `DestinationPrompts` — the real `NSAlert`s (containment with a text field; consent with Move / Leave Behind / Cancel). Never reached from tests.
- `OutputFolderMigrator.plan(from:to:)` — dry run: `noteCount` (`.md`/`.txt`, not `CLAUDE.md`), `fileCount`, `collisionCount` (same relative path exists in the destination). The migrator itself is unchanged.
- `AppState.setOutputFolder(_:consent:)` — `consent: RelocationConsent?` (nil = move, so every older caller and test behaves as before). Asked after the volume guard, before the gate and before any status change, only when the plan is non-empty and the old folder's drive is present. `.cancel` returns silently. `.leaveBehind` creates the new folder, skips `migrate`, and calls `forgetFiledNotes()`.
- `AppState.forgetFiledNotes()` — clears the path-keyed ledgers: `triagedRecords`, `enrichedLinkRecords`, `meetingRecords`. Kept on purpose: `relayFiledRecords`/`spoolFiledRecords` (name-keyed, so nothing re-files), handoff fingerprints (no duplicate reminders), transcript-dispatch records (a video is never dispatched twice).

**Decisions not pre-specified:**
- OneDrive is suggested too (it is a sync root like the other three, and the dev Mac has one).
- A folder containing `.obsidian` always counts as populated, even if it has no visible notes yet.
- The picker re-detects every 3 s while Settings is open (a SwiftUI `Menu` can't run code when it opens), which keeps "re-read, never cached" true in practice.
- Containment re-ask suggests "`<name> 2`", "`<name> 3`"… (first free or Rapture-owned).

**For milestone 2:** call `DestinationChangeFlow.change(to:appState:)` for a picked place; `DestinationDetector.detect()` for the list. Nothing from M1 needs changing.

**Tests:** `DestinationOnboardingTests` (15): config parsing (valid, malformed, empty, missing, relative), reachable/unreachable/deleted vaults, sync roots, containment decide/check/sanitize, flow re-ask on conflict, direct use of empty/ours/missing folders, cancel and use-folder-itself, dry-run counts, consent cancel leaves state untouched, leave-behind prunes path ledgers only, move keeps ledgers resolving, no question when nothing moves, sidecar points at the container.
