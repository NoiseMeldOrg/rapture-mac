# Sparkle Auto-Update — Shaping Notes

## Scope

In-app automatic updates via **Sparkle 2** so users on an installed DMG learn about and install new GitHub releases without manually re-downloading. Closes the loop on the v1.0.69–1.0.71 release-pipeline work (every release otherwise requires a manual re-download, so installs silently fall behind). Roadmap item #35.

## Decisions (confirmed during shaping)

- **Appcast hosting: raw-on-`main`.** `appcast.xml` committed at the repo root, served from `https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/appcast.xml`; DMG enclosures point at the GitHub Release asset. Everything stays in git — `release.sh` regenerates the entry and it's committed in the same cut commit as the CHANGELOG. Chosen over GitHub Pages because the host is invisible to end users (all options deliver identical UX) and raw-on-main has the fewest moving parts, so updates ship reliably. Pages is an easy future upgrade.
- **Update UX: auto + manual.** Background checks default **ON** (toggleable in Settings → About), prompting on a new release, plus a "Check for Updates…" menu-bar item.
- **Signing:** a dedicated Sparkle **EdDSA** key pair (separate from Apple notarization). Public key embedded in the app via `INFOPLIST_KEY_SUPublicEDKey`; private key stored off-repo (login keychain via `generate_keys`, mirroring the notary-key handling), used by `release.sh`'s `sign_update`.
- **Privacy posture:** this is the app's **first networking** (it shipped zero-outbound in v1). Accepted for auto-update, kept minimal — Sparkle anonymous **system-profiling OFF** (`SUEnableSystemProfiling = NO`), no analytics. PRIVACY.md updated to disclose the appcast fetch + DMG download and the off-toggle.
- **Bootstrap reality:** the first Sparkle-enabled release can't auto-deliver to today's 1.0.71 users (no Sparkle yet) — one manual download; every release after updates in place.

## Integration approach (from codebase exploration)

- **SPM:** add `sparkle-project/Sparkle` (`upToNextMajor` from 2.5.0) mirroring the GRDB package blocks in `project.pbxproj` (`XCRemoteSwiftPackageReference` A0020, `XCSwiftPackageProductDependency` A0021, a `Sparkle in Frameworks` build file A0022, and the project/target reference arrays). Sparkle is a *binary* framework, so the built `.app` must embed + sign `Sparkle.framework` — verified post-build (Xcode auto-embeds SPM frameworks for app targets; `codesign --verify --deep` + notarization confirm).
- **Info.plist** is generated (`GENERATE_INFOPLIST_FILE = YES`); Sparkle keys go in via `INFOPLIST_KEY_*` build settings. `CFBundleVersion` is already monotonic (`1000000 + commit-count`), which is what Sparkle compares — no version-scheme change.
- **UI:** `UpdaterController` wrapping `SPUStandardUpdaterController`; menu item in `UI/MenuBarView.swift` (between Settings and Quit); toggle/button/last-checked in `UI/SettingsAboutView.swift`.
- **release.sh:** new stage signs the DMG (`sign_update`) and appends an `<item>` to `appcast.xml`, slotting after the staple/validate stages; guarded under `--dry-run`/`--skip-notarize`.

## Context

- **Visuals:** None (Sparkle provides its own standard update UI).
- **References:** Sparkle official docs (sparkle-project.org); GRDB's SPM wiring in `project.pbxproj` as the structural template; the integration-point map in `references.md`.
- **Product alignment:** roadmap #35 (auto-update via Sparkle); requires a deliberate, documented exception to the mission/PRIVACY.md "zero-outbound" stance — handled by profiling-off + disclosure.

## As-built notes (deviations from the plan, discovered during implementation)

- **Info.plist keys go via a Run Script phase, not `INFOPLIST_KEY_*`.** Xcode's `GENERATE_INFOPLIST_FILE` only injects *Apple-known* `INFOPLIST_KEY_*` settings — arbitrary keys like `SUFeedURL`/`SUPublicEDKey` are silently dropped (verified). So a new `Scripts/set_sparkle_info.sh` + build phase writes the four Sparkle keys into the built Info.plist, mirroring how `set_git_version.sh` writes the version keys. `SUPublicEDKey` lives in that script (one obvious edit point for the key).
- **Plist keys only persist on a *clean* build.** Incremental builds regenerate the Info.plist and discard script-phase writes (the version keys are affected the same way). Irrelevant in practice — `release.sh` always does `clean build`. Confirmed: a clean build carries the git version *and* all four Sparkle keys.
- **Binary-framework embedding is automatic.** Mirroring GRDB's link build-file was enough; Xcode embeds `Sparkle.framework` (with `Autoupdate`, `Updater.app`, and the Downloader/Installer XPC services) into the app for the app target. Verified in the built bundle.
- **Appcast: `sign_update` + a Python inserter.** `release.sh` Stage 10 runs `sign_update` on the DMG and `Scripts/append_appcast_item.py` inserts a newest-first `<item>` after the `<!-- appcast:items -->` marker (idempotent; produces valid XML). The Sparkle CLI tools ship in Sparkle's *release tarball*, not the SPM artifact — documented in CONTRIBUTING setup.
- **SwiftPM artifact-cache gotcha:** a half-downloaded Sparkle binary artifact in `~/Library/Caches/org.swift.swiftpm/artifacts/` can wedge resolution (`already exists in file system … fatalError`); clearing that cache entry fixes it.

## Standards applied

- **testing/test-writing** — Sparkle is wiring/config with a thin unit surface; test any extracted logic (appcast-entry generation), validate the rest E2E.
- **global/error-handling** — update failures surface via Sparkle's standard UI; never crash or block capture.
- **global/coding-style** — `UpdaterController` matches the app's `@Observable` + small-controller conventions.
