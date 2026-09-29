# Milestone 2 — First-Run Destination Flow: log

## What's new in the app

- **New users are asked where their notes should go.** Right after Full Disk Access is in place, a window lists the Obsidian vaults and synced folders on the Mac, plus Choose Another Folder… and **Keep the Default**.
- **Picking a vault works like Settings:** Rapture offers the "Rapture Inbox" subfolder and asks before moving anything.
- **Keep the Default is a real answer.** The question is settled and never comes back.
- **Nothing waits on the answer.** Notes captured before the user decides land in the default folder and move with the rest when a place is picked.
- **Closing the window without answering** stops the question at launch; the menu offers it again later (milestone 3).

## For the next milestone

**Built:**
- `PersistedState`: three new lenient-decoded flags (`decodeIfPresent ?? false`, all five sites each): `defaultDestinationNudgeDismissed` (M2 sets it on Keep the Default; M3 sets it on nudge dismissal and reads it), `destinationChoicePending`, and `vaultRootRescueDismissed` (added now for M3 so the model changes land once).
- `StateStore`: a fresh install (no `state.json`) starts with `destinationChoicePending = true` (and `triageIntroShown = true`, from 1.0.127).
- `Destination/DestinationChoiceFlow` (`@MainActor enum`): `shouldPresent` (pending AND `permissionState == .ok`), `keepDefault` (pending off, nudge flag on), `dismiss` (pending off only), `choose(_:appState:prompt:consent:)` (runs `DestinationChangeFlow.change`; answered only if the folder actually changed, so Cancel inside the flow leaves the question open).
- `UI/DestinationChoiceView` + `Window("Rapture", id: "destination")` in `RaptureMacApp`; `MenuBarLabel.presentDestinationChoiceIfNeeded()` runs after `start()` and on every `permissionState` change, the same way the permissions window is presented.

**Semantics of `defaultDestinationNudgeDismissed` (M3 must honor):** true means the user settled the default-folder question (Keep the Default, or dismissed the nudge). Never show the nudge when true. It is not set when the user picks a vault (they are off the default then, which already hides the nudge).

**Why `destinationChoicePending` is persisted (deviation from the PRD's one-flag model):** granting Full Disk Access forces a quit-and-reopen, and `ensureDefaultOutputFolder()` has already set `outputFolder` on the first launch. Keyed off `outputFolder == nil`, the question would be lost at exactly the moment it should appear. The default folder is still created first, unchanged (the safety net).

**Not done:** a GUI clean-install run. The Debug build has no Full Disk Access on the dev Mac, so the window can't be reached headlessly past step one. The logic is covered by tests, including a relay note filed before the answer and then moved into the chosen vault's container with its ledger path still resolving.

**Tests (5 added to `DestinationOnboardingTests`):** fresh-install-only + after-FDA + survives relaunch, Keep the Default settles and persists, closing leaves the nudge open, early note moves with the choice, Cancel inside the choice keeps the question open.
