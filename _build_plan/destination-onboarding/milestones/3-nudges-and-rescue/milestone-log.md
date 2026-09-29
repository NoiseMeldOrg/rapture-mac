# Milestone 3 — Nudges & Vault-Root Rescue: log

## What's new in the app

- **A one-time offer to move off the default folder.** If notes still go to `~/Documents/Rapture Notes` and a vault exists, the menu names the vault and offers **Move…**. Dismissing it is permanent.
- **A quiet reminder in Settings.** Settings → General says when notes are going to the default folder, and keeps saying so after the menu notice is dismissed.
- **Gather Rapture's loose folders out of a vault.** If the notes folder is a vault's top level with `Notes/`, `Links/`… loose among the vault's own folders, the menu offers **Gather** into `Rapture Inbox`. Only Rapture's own folders move; the vault's content is never touched.

## What was built

- `Destination/DestinationNudge` — pure `vaultToOffer(outputFolder:defaultFolder:detected:dismissed:choicePending:)` and `isDefault` (normalized path compare).
- `Destination/VaultRootRescue` — `offer(for:)` (requires `.obsidian`; collects Rapture-owned class folders and ISO-named raw captures; returns nil if any class folder is mixed), `ownership(of:isLinks:)` (every note must carry a `captured:` frontmatter line; note attachment folders and `Links/Media` are Rapture's; any other subfolder or file = mixed), `gather(_:into:)` (move when free; merge a folder into an existing one via `OutputFolderMigrator.migrate`, which is safe here because `<root>/Notes` and `<root>/Rapture Inbox/Notes` are not nested; files take a `-N` name on collision; returns container-relative renames).
- `AppState.rescueVaultRoot(_:containerName:)` — under the capture gate with `isRelocating` set: gather, switch `outputFolder` to the container (no migrate), remap all four path ledgers with the renames, write the sidecar, set `vaultRootRescueDismissed`, record Activity.
- `MenuBarView` — `destinationNudge` and `vaultRootRescueNotice`, both using a shared `notice(...)` in the triage-intro shape (plus an action link). Detection and the rescue check run in a detached task each time the menu opens. The rescue container name falls back to the next free name when `Rapture Inbox` holds other files.
- `SettingsGeneralView` — the permanent default-folder line in `outputFolderSection`.

## Decisions not pre-specified

- The rescue is **all-or-nothing** and uses the capture-contract header as proof of ownership. A user's own `Notes/` folder (common in Obsidian vaults) is never moved, and if Rapture wrote into it, the offer is withheld rather than split.
- The nudge is suppressed while the first-run question is still pending, so a new user never sees both.
- The rescue dismissal flag (`vaultRootRescueDismissed`) was added in M2's model change to land all state fields once; the rescue also sets it after a successful gather.

## Tests (6 added to `DestinationOnboardingTests`, 925 total)

Nudge conditions (default + vault + open question; no vault; settled; pending; off default; unreachable vault; trailing slash), dismissal persists across relaunch, rescue offers only Rapture's items, refuses a mixed `Notes/`, gathers with triage and enrichment ledgers resolving and the vault's own files untouched, merges into an existing container with the collision rename remapped in the ledger.

## Residuals

- No GUI run of the notices (the Debug build lacks Full Disk Access headlessly); behavior is covered by the tests above.
- The known migrator gap (adopting a vault root, then relocating `.obsidian/` away) is recorded in `agent-os/specs/2026-09-29-destination-onboarding/spec.md`.
