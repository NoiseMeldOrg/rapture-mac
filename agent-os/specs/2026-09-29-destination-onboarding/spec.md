# Destination onboarding (durable spec)

> Built 2026-09-29 in three milestones. Frozen build log: `_build_plan/destination-onboarding/` (PRD + per-milestone `milestone-log.md`). This file holds the decisions that should outlive that snapshot.

## Why

Captures were triaged correctly but filed silently into `~/Documents/Rapture Notes`, outside the user's real notes vault, and the user never learned the app could relocate them. Every failure was discoverability, not capability.

## What the app does

- **Detection** (`Destination/DestinationDetector`): Obsidian vaults from `~/Library/Application Support/obsidian/obsidian.json` (`{"vaults":{"<id>":{"path":…}}}`), plus sync roots: iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`), and `~/Library/CloudStorage/{Dropbox*, GoogleDrive-*/My Drive, OneDrive-*}`. Re-read whenever shown, never cached. Reachability reuses `DestinationGuard`: `.volumeAbsent` = listed but not pickable; `.folderMissing` = stale entry, skipped.
- **Containment** (`Destination/Containment`): a folder containing `.obsidian` or visible items that aren't Rapture's gets the offer of one container subfolder (default `Rapture Inbox`). A container is adopted when missing, empty, or already Rapture-shaped; otherwise the next free name is suggested.
- **Consent** (`AppState.setOutputFolder(_:consent:)`): a dry run (`OutputFolderMigrator.plan`) before anything moves; Move / Leave Them Behind / Cancel. Cancel is a silent no-op placed before the capture gate and any status change. Leave Them Behind prunes only the path-keyed ledgers (`triagedRecords`, `enrichedLinkRecords`, `meetingRecords`) via `AppState.forgetFiledNotes()`; name-keyed and fingerprint ledgers stay so nothing re-files, re-creates, or re-dispatches.
- **First run** (`DestinationChoiceFlow`, `DestinationChoiceView`): a fresh install (no `state.json`) persists `destinationChoicePending`; the window appears once `permissionState == .ok`, after the FDA relaunch. The default folder is still created first as the safety net. Keep the Default sets `defaultDestinationNudgeDismissed`.
- **Nudge** (`DestinationNudge`): a menu notice when on the default folder, a reachable vault exists, and the question is open. Dismissal is permanent; Settings → General keeps a quiet line.
- **Vault-root rescue** (`VaultRootRescue`, `AppState.rescueVaultRoot`): when the notes folder contains `.obsidian`, gathers only Rapture-owned items (class folders whose every note has a `captured:` header, `Links/Media`, note attachment folders, ISO-named raw captures) into a container. All-or-nothing: a class folder holding any other file means no offer. Collision renames are remapped into the ledgers.

## Commitments this preserves

- **No networking.** PRIVACY.md's grep claim still returns exactly `TriageAI/AnthropicEngine.swift`, `TriageAI/AnthropicWire.swift`, `Enrichment/URLSessionLinkFetcher.swift`.
- **Output neutrality.** Detection decides where notes go, never how they are written.
- **Never touch the user's own notes.** The rescue refuses rather than guess; `OutputFolderMigrator.migrate` is unchanged and still refuses nested paths.
- **No bookmarks.** The app is unsandboxed; plain absolute paths in `settings.json`.

## Known gap carried forward

`OutputFolderMigrator` still has no guard against adopting a vault root as the notes folder and later moving `.obsidian/` away with a relocation (logged in the M1 prompt as out of scope). The containment offer makes adopting a vault root an explicit choice ("Use … Itself"), which narrows but doesn't close it.
