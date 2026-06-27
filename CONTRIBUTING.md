# Contributing to Rapture for Mac

Rapture for Mac is small enough that the contribution loop is straightforward: open an issue if you want to discuss something, send a PR if you've got a fix in hand. This doc covers the build environment, the conventions the codebase already follows, and the release process (for maintainers).

## Build and test

```sh
xcodebuild \
  -derivedDataPath /tmp/RaptureMacDerived \
  -project RaptureMac/RaptureMac.xcodeproj \
  -scheme RaptureMac \
  -configuration Debug \
  clean build test
```

You should see 234 tests pass.

**Why `/tmp/RaptureMacDerived`**: this repo is often checked out on an exFAT-formatted SSD. Building in-place causes macOS to write AppleDouble (`._*`) metadata files into the derived-data tree, which then get copied into the `.app` bundle and break `codesign`. Routing derived data to the internal APFS volume sidesteps that. The same path is used everywhere derived data appears in our scripts and docs.

### Continuous integration

Every PR and push to `main` runs the full XCTest suite on a macOS GitHub Actions runner (`.github/workflows/ci.yml`). It builds the Debug configuration (which ad-hoc signs, so no certificates are needed) — signing and notarization stay a maintainer-only release concern. Keep the suite green; a red check blocks merge.

### Running a local build interactively

To exercise a Debug build by hand (e.g. to test the output-folder relocation flow), **quit and move the installed app aside first**:

```sh
pkill -x Rapture
mv /Applications/Rapture.app /Applications/Rapture.app.aside   # reversible
open /tmp/RaptureMacDerived/Build/Products/Debug/Rapture.app
# ... test, then restore:
pkill -x Rapture && mv /Applications/Rapture.app.aside /Applications/Rapture.app
```

**Why**: a Debug build shares the `noisemeld.RaptureMac` bundle identifier with an installed copy in `/Applications`. When both are registered, macOS LaunchServices resolves the bundle ID to the installed copy — so `open <debug>.app` (and even exec'ing the binary directly, because AppKit re-launches GUI apps through LaunchServices) can silently run the **installed** app instead of your build. Moving the installed app aside leaves your Debug build as the only registered copy. Confirm which binary is live with `ps -ax | grep Rapture.app/Contents/MacOS/Rapture`.

**Data isolation (since v1.0.71)**: Debug builds use **separate data containers** — `~/Library/Application Support/Rapture for Mac (Debug)/` (its own `settings.json` / `state.json` / sidecar) and a `~/Documents/Rapture Notes (Debug)/` default — so a Debug build *never* reads, writes, or relocates the installed app's settings or notes. You no longer need to back anything up before a test that changes them, and a Debug build can run alongside the installed app safely. A "(Debug)" marker in the Settings window title and General tab confirms which build you're driving. (See `AppSupportDirectory`; this isolation is the root-cause fix from the 2026-06 data-safety hardening.)

You'll also need:

- **Xcode 26+** (the project file uses `objectVersion = 77`).
- **macOS 14+** as the build host (matches the deployment target).
- The login keychain only needs an `Apple Development` cert for local debug builds. Distribution signing is a maintainer-only concern (see below).

## Architecture and code style

Most of these are visible from a single read of the codebase, but worth stating for new contributors:

- **`@MainActor` is the project's default actor isolation** (`SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` build setting). Cross only when you actually need to: typically in GRDB closures (`pool.read { ... }`) or `Task.detached` for the `osascript` subprocess. Use `nonisolated` explicitly when crossing.
- **Pure-helper test pattern**. Where there's stateful orchestration (`BatchProcessor`, `EchoGuard`, `Replier`), the decision logic is extracted into pure `nonisolated static` helpers that take all inputs as arguments. Tests hit the helpers directly, no fixture infrastructure. See `BatchProcessor.isCatchup` (M2) and `BatchProcessor.policy` (M3) for examples to follow.
- **The test bundle is hosted inside `Rapture.app`** (`TEST_HOST` in the project), so the app's `@main` startup actually runs during `xcodebuild test`. Any startup work that hits the network, spawns a shell, or touches a TCC-protected resource will destabilize the headless test host — opening `chat.db` raises a **Full Disk Access prompt** that can make xcodebuild report `Restarting after unexpected exit` (an intermittent red CI/stress run that looks like a code bug but isn't). **Gate all such startup machinery behind `ProcessInfo.processInfo.isRunningXCTests`** (see `RuntimeEnvironment.swift`). Current gates: `Pipeline.start()` (chat.db open + watcher), `LoginShellPath.capture()` (the `/bin/zsh -ilc` PATH probe), and `UpdaterController` (Sparkle). Add a gate to any new launch-time side effect.
- **OSLog subsystem is `noisemeld.RaptureMac`** with one category per file/role. Use `Logger(subsystem: "noisemeld.RaptureMac", category: "...")`.
- **Atomic file writes**: `AtomicFile.write(_:to:)` wraps `Data.write(to:options: .atomic)`, which does `.tmp` → `rename(2)`. Don't roll your own.
- **`_build_plan/` is historical**. No code, configuration, or runtime logic depends on it. The durable architectural docs live in `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`.

## Issue and PR conventions

- One commit per logical change; if a fix has cleanup along the way, split it.
- Commit subjects in the same shape as the existing log: `feat(M3): user control — menu bar, settings tabs, allowlist editor`, `fix: LSUIElement apps need explicit NSApp.activate to claim front`. Past tense, present-imperative; match what's already there.
- PRs should describe **why** before **what**. The code shows the what.

## First-time release setup (maintainers)

You'll need three things once, before you can run `Scripts/release.sh`:

### 1. Developer ID Application certificate

Required for signing a DMG distributed outside the Mac App Store. This is a **different cert type** from the `Apple Distribution` cert iOS uses for App Store / TestFlight, even with the same team ID. Apple's notarization service rejects anything signed with the wrong cert type.

To create one:

1. Open **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…**. Enter the org Apple ID. Choose **Saved to disk** → produces a `.certSigningRequest` file.
2. Sign in to <https://developer.apple.com/account/resources/certificates/list> as the org account. Confirm the team selector reads **Bensolutions LLC d/b/a Noise Meld** (team `P8PLTH44DF`).
3. Click `+` → choose **Developer ID Application** → upload the CSR. Download the resulting `.cer` file.
4. Double-click the `.cer` to install it into the login keychain.

Verify:

```sh
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Should print something like `Developer ID Application: Bensolutions LLC d/b/a Noise Meld (P8PLTH44DF)`.

### 2. Notarization keychain profile

`notarytool` stores credentials in the login keychain under a named profile so the release script doesn't have to pass them each time:

```sh
xcrun notarytool store-credentials "rapture-mac-notary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_GX6DYX9S2M.p8 \
  --key-id GX6DYX9S2M \
  --issuer <your-issuer-uuid>
```

The issuer UUID is the team-specific App Store Connect issuer ID. Find it at <https://appstoreconnect.apple.com> → **Users and Access → Integrations → Team Keys**, top of the page.

Verify:

```sh
xcrun notarytool history --keychain-profile rapture-mac-notary
```

Should list past submissions (empty list on first run is fine; it confirms the profile is configured).

### 3. `create-dmg`

```sh
brew install create-dmg
```

### 4. Sparkle signing key + tools (for auto-update)

Auto-updates are signed with an **EdDSA key**, separate from Apple notarization. **This is already set up:** the project's **public** key is committed in `Scripts/set_sparkle_info.sh` (baked into every build's Info.plist as `SUPublicEDKey`), and the matching **private** key lives in the release maintainer's login keychain.

To *cut a release* you need two things on your machine:

1. **Sparkle's CLI tools** (`sign_update`, `generate_keys`) — they ship in Sparkle's release tarball, not the Swift package. Download the matching `Sparkle-*.tar.xz` from <https://github.com/sparkle-project/Sparkle/releases> and put its `bin/` on your `PATH`. Install them to a **stable** location (e.g. `cp .../bin/{sign_update,generate_keys} ~/.local/bin/`), **not** `/tmp` — a `/tmp` copy is cleared on reboot, so a later release silently skips the appcast step. `release.sh` Stage 10 uses `sign_update`; if it's missing the release still builds, just skipping the appcast step with a warning — which means **no auto-update path for that version**, so verify `which sign_update` before cutting.
2. **The private key** in your login keychain. `generate_keys` created it on the original maintainer's Mac; if you're releasing from a different machine, import the backed-up private key first.

**Back it up.** Losing the private key means you can never ship a verifiable update to existing installs again. Export and store it offline:
```sh
./bin/generate_keys -x sparkle_private_key.pem   # then move it to a password manager / offline backup
```

**Rotating the key** (new maintainer with no access to the original private key): run `generate_keys` to make a new pair, replace `PUBLIC_ED_KEY` in `Scripts/set_sparkle_info.sh`. Note that installs on the *old* key can't auto-update across the change — they need one manual re-download of the first build signed with the new key.

## Cutting a release

```sh
git checkout main
git pull
./Scripts/release.sh
```

**Stay at the keyboard while it runs.** Signing touches the keychain several times (Stage 3b re-signs each Sparkle helper + the framework + app; Stage 10's `sign_update` uses the EdDSA key), so macOS may prompt to **unlock the keychain (login/Mac password)** and/or to **allow `codesign`/`sign_update` to use a key** — and the run *blocks* on each prompt. Click **Always Allow** so later signing calls in the same run don't re-prompt. To avoid the password prompt entirely, `security unlock-keychain` before starting.

The script will:

1. Sanity-check (on `main`, clean tree, cert + notary profile + `create-dmg` present).
2. `xcodebuild` a Release configuration into `/tmp/RaptureMacDerived/`.
3. Read the auto-generated `CFBundleShortVersionString` from the built Info.plist (the `Scripts/set_git_version.sh` Run Script phase writes it from the `main` commit count).
3b. **Re-sign Sparkle's nested helpers** (`Updater.app`, `Autoupdate`, the Downloader/Installer XPC services) inside-out with the Developer ID identity + hardened runtime + a secure timestamp, then re-seal the framework and app. Sparkle ships them ad-hoc-signed and Xcode doesn't re-sign that nested code, so without this the notary rejects the app ("not signed with a valid Developer ID certificate" / "no secure timestamp") even though `codesign --verify --deep` passes locally. This bit v1.0.79.
4. Verify the signature (`codesign --verify --deep --strict`).
5. Notarize and **staple the `.app`** — zip it, `xcrun notarytool submit --wait` (~30s–10min), then `xcrun stapler staple` the app — so first launch works even fully offline.
6. Build the DMG via `create-dmg` from the now-stapled app.
7. Submit the DMG to Apple's notarization service (`xcrun notarytool submit --wait`).
8. Staple the notarization ticket onto the DMG.
9. Run `spctl --assess` and `xcrun stapler validate` for final sanity.
10. **EdDSA-sign the DMG and append the `appcast.xml` entry** (`sign_update`) — the Sparkle feed that lets installed copies auto-update. Skipped with a warning if `sign_update` isn't on `PATH`.
11. Print the DMG path, size, and SHA-256.

Notarization runs **twice** (once for the app, once for the DMG), so a release submits two `notarytool` jobs.

**First run**: when `codesign` first uses the new Developer ID Application cert, macOS will prompt to allow access to the private key in the keychain. Click **Always Allow** so subsequent runs are unattended.

**Flags**:

- `--dry-run`: print every shell command without executing. Use this to verify env before doing a real build.
- `--skip-notarize`: build and DMG-package locally without submitting. Useful for verifying signing changes without burning a notarytool round-trip.

### Publish the build

`Scripts/release.sh` stops at a built, notarized DMG — it does not touch git or GitHub. After a successful run, publish it:

1. **Cut the CHANGELOG.** Turn `## [Unreleased]` into `## [<VERSION>] - <date>: <subtitle>`, add the `` Built from commit `<short-sha>`. SHA-256: `<sha>`. `` line (the script printed both), and leave a fresh empty `[Unreleased]` above it.
2. **Bump the roadmap status line** in `agent-os/product/roadmap.md`.
3. **Commit** `docs(changelog): cut v<VERSION> — <subtitle>` and push `main`. **Include `appcast.xml`** in this commit — `release.sh` Stage 10 added the new `<item>` to it, and it must land on `main` so the Sparkle feed (served from raw `main`) advertises the release. The `<enclosure>` URL points at the GitHub Release asset you create in step 5, so committing it before/with the release is correct — the file goes live the moment the release exists.
4. **Tag the *build* commit, not HEAD.** The version is the `main` commit count *at build time*, so the build commit is HEAD **before** the changelog-cut commit. Tag that commit and push the tag:
   ```sh
   git tag v<VERSION> <build-commit>   # the commit you built from, not the cut commit
   git push origin v<VERSION>
   ```
   (`gh release create --target <short-sha>` is rejected with `target_commitish is invalid`; pushing the tag first avoids it.)
5. **Create the release** from the tag with the DMG attached:
   ```sh
   gh release create v<VERSION> --title "Rapture <VERSION> — <subtitle>" \
     --notes "<notes from CHANGELOG>" /tmp/RaptureMacDerived/Rapture-<VERSION>.dmg
   ```

> **Shortcut:** the `release-rapture-mac` Claude Code skill (`.claude/skills/release-rapture-mac/`) automates this entire ritual — build, notarize, changelog cut, tag, GitHub Release, and optional local install — with these gotchas baked in. Say "cut a release" in a Claude Code session on `main`.

**A note on stapling:** both the `.app` and the DMG are stapled — `release.sh` notarizes and staples the app *before* packaging it, then notarizes and staples the DMG. So after installing, `xcrun stapler validate /Applications/Rapture.app` succeeds and first launch works even offline. `spctl --assess --type execute` returning `accepted / source=Notarized Developer ID` remains the definitive Gatekeeper check.

## When in doubt

The PRD and milestone build logs (`_build_plan/prd.md` + `_build_plan/milestones/*/milestone-log.md`) describe what was built and **why** for each milestone. The technical truth lives in `agent-os/specs/2026-05-16-1854-rapture-mac-v1-local-capture/`. Both are good starting points for context.
