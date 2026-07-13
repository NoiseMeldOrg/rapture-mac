---
name: verify
description: Build, launch, and drive a Debug build of Rapture for Mac to verify changes end-to-end against its real surfaces (destination folder, relay folder, menu bar). Use when verifying capture/triage/relay changes by observing the running app rather than the test suite.
---

# Verifying Rapture for Mac live

The app's surfaces are filesystem side effects (the notes destination, the iCloud relay folder) plus the menu bar. Drive them by dropping files and observing what the running app produces.

## Build + launch

```sh
xcodebuild -derivedDataPath /tmp/RaptureMacDerived \
  -project RaptureMac/RaptureMac.xcodeproj -scheme RaptureMac \
  -configuration Debug build            # test runs also produce the app

pkill -x Rapture                        # quit the installed app (watermark catch-up recovers anything missed)
mv /Applications/Rapture.app /Applications/Rapture.app.aside   # LaunchServices resolves the shared bundle ID to the installed copy
open /tmp/RaptureMacDerived/Build/Products/Debug/Rapture.app
ps -ax -o pid,comm | grep "Rapture.app/Contents/MacOS"          # confirm the /tmp binary is the one running
```

**Always restore when done** (and relaunch — the user's capture pipeline was running):

```sh
pkill -x Rapture
mv /Applications/Rapture.app.aside /Applications/Rapture.app
open /Applications/Rapture.app
```

## Debug isolation (what to drive)

- Notes destination: `~/Documents/Rapture Notes (Debug)/`
- Relay folder: `~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay (Debug)/`
- Settings/state: `~/Library/Application Support/Rapture for Mac (Debug)/{settings.json,state.json}`

Drop `.txt` files at the destination root (or a `.txt`+`.m4a` pair in the relay folder) and watch the outputs. `state.json` is the best oracle: `triagedRecords` / `relayFiledRecords` / `lastError` record exactly what the app did and when.

## Gotchas (all bitten before)

- **App Nap stalls the poll loops.** A debug build launched via `open` from a shell has no window and no user input, so macOS naps it — 5s polls stretched to ~18 minutes in one session. Wake it deterministically after each file drop: `sample <pid> 1 >/dev/null 2>&1` (attaching wakes the process), then wait ~10s (two poll ticks; the triage settle rule needs two same-size sightings ≥5s apart). The user-launched production app has not shown this in dogfooding, but keep it in mind if "nothing happens."
- **The debug build has no Full Disk Access**, so iMessage capture won't run (FDA poll loops harmlessly; a permissions window may open). Relay + triage surfaces need no FDA and are fully drivable.
- **`log show`/`log stream` return nothing from the sandboxed shell.** Use `state.json`, output files, and `sample <pid>` stacks as evidence instead.
- Don't pre-create files you expect the app to create; don't clean the debug notes folder — it's isolated scratch and prior artifacts are useful realism.
