# Sparkle Auto-Update — Plan

> Spec folder (created by Task 1): `agent-os/specs/2026-06-26-1333-sparkle-auto-update/`

## Context

Rapture for Mac ships as a Developer ID-signed, notarized DMG from GitHub Releases (v1 → current v1.0.71). We just built a clean release pipeline (`Scripts/release.sh` + the `release-rapture-mac` skill), but users have **no in-app update path** — every new version requires manually re-downloading the DMG, so installs silently fall behind (a user on 1.0.71 won't learn 1.0.72 stapled the app for offline launch). This is roadmap item #35.

This spec adds **Sparkle 2** auto-update: the app checks an appcast feed, notifies the user when a new GitHub release exists, and installs it in place. It closes the loop on the distribution work.

**The product tension (deliberate, confirmed):** the app ships *zero networking* today and a strong privacy posture (PRIVACY.md "zero-outbound"). Sparkle introduces the first outbound calls (fetch the appcast XML, download the DMG). We accept this for auto-update, but keep it minimal: Sparkle's anonymous **system-profiling stays OFF**, no analytics, and PRIVACY.md is updated to disclose exactly what is fetched and that nothing is sent.

**Decisions (confirmed during shaping):**
- **Appcast hosting:** raw-on-`main` — `appcast.xml` committed at repo root, served from `https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/appcast.xml`; DMG enclosures point at the GitHub Release asset. Everything stays in git; `release.sh` appends an entry as part of the existing publish ritual.
- **Update UX:** automatic background checks (default **ON**, toggleable in Settings → About) that prompt on a new release, **plus** a "Check for Updates…" menu-bar item.
- **Signing:** Sparkle EdDSA key pair (separate from Apple notarization); public key embedded in the app, private key stored **off-repo** (like the notary key), used by `release.sh` to sign each DMG.
- **Bootstrap reality:** the *first* Sparkle-enabled release can't be auto-delivered to today's 1.0.71 users (no Sparkle yet) — they download it once manually; every release after updates in place.

## Out of scope
- GitHub Pages hosting (raw-on-main chosen; Pages is a future option).
- Delta updates, automatic silent install without prompt, beta channels.
- Sandboxing changes (app stays non-sandboxed; Sparkle's XPC-service entitlements are a sandbox-only concern, so not needed here).

---

## Task 1: Save spec documentation

Create `agent-os/specs/2026-06-26-1333-sparkle-auto-update/` with `plan.md` (this), `shape.md` (scope + the confirmed decisions + the privacy-posture reasoning), `standards.md` (full text of applied standards), `references.md` (Sparkle docs + the integration-point map from exploration), `visuals/.gitkeep` (none).

## Task 2: Generate + store the Sparkle EdDSA key (one-time maintainer setup)

- Run Sparkle's `generate_keys` to produce the EdDSA key pair. Store the **private** key off-repo (keychain entry / `~/.appstoreconnect`-style location, mirroring the notary key); **never** commit it.
- Capture the **public** key string for the app's Info.plist (Task 4).
- Document the setup (and how a maintainer recovers/rotates it) in CONTRIBUTING → "First-time release setup".

## Task 3: Add the Sparkle SPM dependency

- Add `https://github.com/sparkle-project/Sparkle` (`upToNextMajorVersion` from `2.x`) to `RaptureMac.xcodeproj`, mirroring the existing GRDB `XCRemoteSwiftPackageReference` / `XCSwiftPackageProductDependency` blocks (project.pbxproj ~lines 516–532) and the target's `packageProductDependencies`.
- Confirm `Sparkle.framework` embeds and is signed by the existing Release flow under **hardened runtime + Developer ID + `--timestamp`** (the embedded `Autoupdate`/`Updater.app`/XPC binaries must each be signed). `release.sh` Stage 4's `codesign --verify --deep --strict` should cover verification — extend if needed.

## Task 4: Configure Sparkle via Info.plist build settings

Info.plist is generated (`GENERATE_INFOPLIST_FILE = YES`), so add keys via `INFOPLIST_KEY_*` build settings (Release config, and Debug where useful):
- `SUFeedURL` = `https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/appcast.xml`
- `SUPublicEDKey` = the public key from Task 2
- `SUEnableAutomaticChecks` = YES (auto-checks default on; still user-toggleable at runtime)
- `SUEnableSystemProfiling` = NO (privacy: no profile sent)
- Sparkle compares `CFBundleVersion` — already monotonic (`1000000 + commit-count` from `set_git_version.sh`), so no version-scheme change needed.

## Task 5: Wire the updater into the app + UI

- Add a small `UpdaterController` owning an `SPUStandardUpdaterController` (standard user-driver), created at app launch in `RaptureMacApp` and exposed to the UI (env or a lightweight `@Observable`).
- **Menu:** add a "Check for Updates…" item in `UI/MenuBarView.swift`, between the Settings divider (line ~94) and "Quit Rapture" (line ~97), calling the updater's check action; disable it while a check is in flight (Sparkle exposes `canCheckForUpdates`).
- **Settings → About** (`UI/SettingsAboutView.swift`, after the Open Source section ~line 40): an "Automatically check for updates" toggle bound to `updater.automaticallyChecksForUpdates`, a "Check for Updates…" button, and the last-checked date. Mirror the existing `SettingsStore.binding` style for the toggle where it fits.

## Task 6: Automate appcast generation in `release.sh`

After the DMG is built/notarized/stapled (after Stage 9, before the Stage 10 summary):
- Sign the DMG with Sparkle's `sign_update` (using the off-repo private key) to get `sparkle:edSignature` + length.
- Append a new `<item>` to the repo's `appcast.xml`: `sparkle:shortVersionString` = `$VERSION`, `sparkle:version` = `$BUILD` (CFBundleVersion), `<enclosure>` URL = `https://github.com/NoiseMeldOrg/rapture-mac/releases/download/v$VERSION/Rapture-$VERSION.dmg`, the edSignature/length, `sparkle:minimumSystemVersion` = 14.0, and release notes (link to the CHANGELOG section or embed a short HTML description).
- This runs locally; the updated `appcast.xml` is committed as part of the publish ritual (next task), so Sparkle picks it up once pushed to `main`.
- Provide a path for `--skip-notarize`/`--dry-run` to no-op the signing/appcast step, consistent with the other stages.

## Task 7: Update the release ritual + docs + privacy

- **`release-rapture-mac` skill** + CONTRIBUTING "Publish the build": add the appcast step — `appcast.xml` is regenerated by `release.sh` and **committed in the same cut commit** as the CHANGELOG/roadmap, then pushed to `main` so the feed updates atomically with the release. Note the EdDSA key requirement in first-time setup.
- **PRIVACY.md:** disclose that, when auto-update is enabled, the app fetches `appcast.xml` and downloads DMGs from GitHub; no telemetry/profile is sent; the toggle to disable.
- **CHANGELOG `[Unreleased]`:** add the Sparkle feature entry (and the bootstrap note: existing users download this one manually).
- **README:** mention in-app auto-update.

## Task 8: Verification

Sparkle is largely a config/wiring feature with limited unit-test surface; verification is mostly end-to-end:
1. Build with a **test** `SUFeedURL` pointing at a local/staging appcast advertising a higher version; confirm: auto-check prompts, "Check for Updates…" works from both the menu and About, the toggle persists, and a signed test DMG installs and relaunches.
2. Confirm "you're up to date" when the appcast matches the current version.
3. `codesign --verify --deep --strict` passes on the Sparkle-embedded app; `spctl --assess` accepts; notarization still succeeds with the framework embedded.
4. Any pure-logic helper added for appcast generation gets a unit test (mirror `OutputFolderMigratorTests` style); the Sparkle wiring itself is validated manually.

---

## Standards applied
- **testing/test-writing** — limited unit surface; test any extracted logic (e.g. appcast-entry generation), validate the rest E2E. Mirror existing temp-dir/injected-FileManager test style.
- **global/error-handling** — update failures (no network, bad signature, failed download) must surface a clear, non-alarming message via Sparkle's standard UI; never crash or block capture.
- **global/coding-style** — match the app's `@Observable` + small-controller conventions for `UpdaterController`.

## Verification (summary)
Build → point `SUFeedURL` at a staging appcast with a higher signed version → confirm prompt + install + relaunch; toggle + manual check work; `codesign --verify --deep`, `spctl --assess`, and notarization all pass with Sparkle embedded.
