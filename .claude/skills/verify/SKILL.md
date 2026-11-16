---
name: verify
description: Build, launch, and drive a Debug build of Rapture for Mac to verify changes end-to-end against its real surfaces (destination folder, relay folder, menu bar). Use when verifying capture/triage/relay changes by observing the running app rather than the test suite.
---

# Verifying Rapture for Mac live

The app's surfaces are filesystem side effects (the notes destination, the iCloud relay folder) plus the menu bar. Drive them by dropping files and observing what the running app produces.

## Read this first: a launch once cost the installed app its Full Disk Access

**What happened.** Until 2026-11-15 the Debug build had the same bundle id as the installed app (`noisemeld.RaptureMac`) and a different signature. On macOS 26.6.2 a Debug launch tried to open `chat.db`. macOS (`tccd`) logged `Failed to match existing code requirement for subject noisemeld.RaptureMac and service kTCCServiceSystemPolicyAllFiles` and `recording denied`, and the installed app's Full Disk Access grant became a denial. The installed app could not read Messages until the user turned Full Disk Access on again and reopened the app.

**What changed.** The Debug build now has its own bundle id, `noisemeld.RaptureMac.debug`, and its own name, "Rapture (Debug)". macOS records privacy grants under the bundle id (the `subject` in that log line), so the Debug build's requests go under its own id. `DebugBuildIdentityTests` fails if the two builds share an id again.

**Confirmed live on 2026-11-16 (macOS 26.6.2, with the user's go).** The Debug build ran next to the installed app for 65 seconds. It tried to open `chat.db` four times. Each time `tccd` answered with a denial for `noisemeld.RaptureMac.debug` (`recording denied`) and logged no `Failed to match` line. The installed app was then restarted, and macOS still allowed it Full Disk Access (`authValue=2`).

So a Debug launch no longer puts the installed app's Full Disk Access at risk. Two rules remain:

- **Check the copy before you open it:** `defaults read /tmp/RaptureMacDerived/Build/Products/Debug/Rapture.app/Contents/Info CFBundleIdentifier` must print `noisemeld.RaptureMac.debug`. A copy built before the change keeps the old id until it is rebuilt, and that copy can still do the damage. Xcode's own DerivedData folder can hold one.
- **Tell the user before you launch, and tell them not to click.** The Debug build shows a "Rapture needs Full Disk Access" window. It tells the user to turn Rapture on in System Settings, and that list now has two entries. During the 2026-11-16 test the switch for the installed app went off and on again in those seconds (a user-set change in the log, not the Debug build), and the installed app restarted twice. The Debug build also raises a dialog that asks for access to the Documents folder. On 2026-11-15, reads of `~/Documents` from the shell hung while that dialog was open. Both go away when the Debug process stops.

To check a launch afterwards, read the privacy log with the shell sandbox off: `log show --last 10m --predicate 'subsystem == "com.apple.TCC"'`. A line that says `Failed to match existing code requirement for subject noisemeld.RaptureMac and` means the installed app was hit. To see the answer an app got, find its `AUTHREQ_ATTRIBUTION` line (it names the bundle id and the pid), take the `msgID`, and read the `AUTHREQ_CTX` and `AUTHREQ_RESULT` lines with that `msgID`. Those two lines do not contain the bundle id, so a filter on the bundle id hides them. `authValue=2` is allowed and `authValue=0` is denied.

Most changes do not need the launch. Use these first:

- the unit tests;
- the real source files compiled as a command-line tool (`xcrun swiftc -O -parse-as-library -swift-version 5 <the source files> main.swift -o tool`). This runs code that is switched off under XCTest, such as the real `Process` launchers, with no app bundle and no privacy prompts;
- for a SwiftUI view, a temporary XCTest that hosts the view in an off-screen borderless `NSWindow` and writes PNG files with `bitmapImageRepForCachingDisplay` and `cacheDisplay(in:to:)`. Delete the test after you look at the pictures.

With the shell sandbox off, `log show --predicate 'subsystem == "noisemeld.RaptureMac"'` works, and `.notice` lines are kept. Both builds log under that subsystem name.

## Build + launch

```sh
xcodebuild -derivedDataPath /tmp/RaptureMacDerived \
  -project RaptureMac/RaptureMac.xcodeproj -scheme RaptureMac \
  -configuration Debug build            # test runs also produce the app

open -n /tmp/RaptureMacDerived/Build/Products/Debug/Rapture.app   # -n + the full path launches THIS bundle
ps -ax -o pid,comm | grep "Rapture.app/Contents/MacOS"          # both copies: /Applications and /private/tmp
```

**Leave the installed app open.** The two builds are different apps to macOS, and they ran side by side in the 2026-11-16 test. The Debug build has no Full Disk Access, its own relay folder and its own notes folder, so it does not take the installed app's captures. Do not give the Debug build Full Disk Access while the installed app runs: both would file and answer the same message.

**Never move or rename `/Applications/Rapture.app`** to get the Debug build to launch. Moving the installed app aside and back made macOS drop its Full Disk Access grant (2026-09-29): the user had to re-grant it and Quit & Reopen.

**Stop the Debug build by its path, never by name.** `pkill -x Rapture` also stops the user's installed app, and a script that hangs after it leaves capture off (20 minutes on 2026-11-15).

```sh
pkill -f "RaptureMacDerived/Build/Products/Debug/Rapture.app/Contents/MacOS/Rapture"
ps -ax -o pid,comm | grep "Rapture.app/Contents/MacOS"          # only /Applications is left
```

In a script, put that `pkill -f` in a `trap … EXIT`, give every wait a time limit, and do not read `~/Documents` without one.

## Debug isolation (what to drive)

- Notes destination: `~/Documents/Rapture Notes (Debug)/`
- Relay folder: `~/Library/Mobile Documents/iCloud~noisemeld~Rapture/Relay (Debug)/`
- Settings/state: `~/Library/Application Support/Rapture for Mac (Debug)/{settings.json,state.json}`

Drop `.txt` files at the destination root (or a `.txt`+`.m4a` pair in the relay folder) and watch the outputs. `state.json` is the best oracle: `triagedRecords` / `relayFiledRecords` / `lastError` record exactly what the app did and when.

## Gotchas (all bitten before)

- **A freshly built debug binary re-triggers Full Disk Access onboarding, and granting it quits the app.** Each rebuild is a new bundle at a new/changed signature, so TCC treats it as a new app: the FDA sheet opens on launch, and after the user grants FDA the app must quit and relaunch to see it (a running process never picks up a new grant). To the verifying agent this looks like the app **silently vanished mid-test** — no crash report, drops stop being processed. What to do: (a) if the surfaces under test don't need FDA (relay, triage, enrichment — most of them), tell the user up front they can ignore/dismiss the FDA sheet for this run; (b) poll process liveness (`kill -0 <pid>`) between steps rather than assuming the pid survives; (c) if it exited, just `open` it again — settings/state are on disk and the test continues where it left off; (d) if the user *does* grant FDA mid-run, expect exactly one quit-and-relaunch cycle and re-`open` afterwards.

- **The Debug build can restart itself under a new pid.** "Reopen Rapture" in its permissions window (and macOS's own "Quit & Reopen") starts a new process one second later. A script that saved the first pid then stops nothing (seen 2026-11-16). Look the pid up again with `pgrep -f` on the Debug path, or use the `pkill -f` line above.
- **App Nap stalls the poll loops.** A debug build launched via `open` from a shell has no window and no user input, so macOS naps it — 5s polls stretched to ~18 minutes in one session. Wake it deterministically after each file drop: `sample <pid> 1 >/dev/null 2>&1` (attaching wakes the process), then wait ~10s (two poll ticks; the triage settle rule needs two same-size sightings ≥5s apart). The user-launched production app has not shown this in dogfooding, but keep it in mind if "nothing happens."
- **The debug build has no Full Disk Access**, so iMessage capture won't run (FDA poll loops harmlessly; a permissions window may open). Relay + triage surfaces need no FDA and are fully drivable.
- **`log show`/`log stream` return nothing from the sandboxed shell.** Use `state.json`, output files, and `sample <pid>` stacks as evidence instead.
- Don't pre-create files you expect the app to create; don't clean the debug notes folder — it's isolated scratch and prior artifacts are useful realism.
- **Exec'ing the binary directly never starts the pipeline.** `pipeline.start()` fires from the menu-bar label's `.task`, which needs a proper LaunchServices launch — a directly-exec'd binary sits idle forever (looks like "nothing happens", no errors). To pass an env var (e.g. `RAPTURE_AI_FORCE_ENGINE=anthropic`), use `launchctl setenv KEY value` then `open …/Rapture.app`, and `launchctl unsetenv KEY` when done.
- **Planting a keychain item with the `security` CLI blocks the app on an ACL dialog** (invisible in a headless session — the process hangs inside `SecItemCopyMatching`). Add `-A` (any-app access) when planting a test key for the debug service `noisemeld.RaptureMac.debug`. App-created items (Settings → Triage → Save) never prompt.
- **Don't relaunch the installed app while a test run is in flight.** When both builds shared a bundle ID (before 2026-11-15), the relaunch could abort the hosted test session partway ("TEST FAILED" with a fraction of the suite executed, zero failures). The IDs differ now, and nobody has checked whether this still happens. If you see it, re-run after the launch settles.
