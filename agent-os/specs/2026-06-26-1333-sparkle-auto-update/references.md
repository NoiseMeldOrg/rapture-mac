# References for Sparkle Auto-Update

## External

- **Sparkle 2 docs** — https://sparkle-project.org/documentation/ (sandboxing, Info.plist keys, `generate_keys`/`sign_update`, appcast format, `SPUStandardUpdaterController`).
- **Appcast format** — https://sparkle-project.org/documentation/publishing/

## Integration points (codebase, from exploration)

### SPM wiring — mirror GRDB (`RaptureMac/RaptureMac.xcodeproj/project.pbxproj`)
- `PBXBuildFile`: `A001D /* GRDB in Frameworks */` (line ~10) → added `A0022 /* Sparkle in Frameworks */`.
- `PBXFrameworksBuildPhase A000C` files list (line ~46) → added A0022.
- Project `packageReferences` (line ~158) → added A0020.
- Target `packageProductDependencies` (line ~100) → added A0021.
- `XCRemoteSwiftPackageReference` (lines ~516–523) → added A0020 (`sparkle-project/Sparkle`, upToNextMajor 2.5.0).
- `XCSwiftPackageProductDependency` (lines ~527–530) → added A0021 (`Sparkle`).
- **No Embed Frameworks copy-phase exists** (GRDB is source-only); Sparkle (binary) relies on Xcode's automatic SPM-framework embedding for app targets — **verify** `Rapture.app/Contents/Frameworks/Sparkle.framework` exists and is signed after a Release build.

### Info.plist (generated via build settings)
- `GENERATE_INFOPLIST_FILE = YES`; version written at build time by `Scripts/set_git_version.sh` (`CFBundleShortVersionString = 1.0.<commits>`, `CFBundleVersion = 1000000 + <commits>` — monotonic, what Sparkle compares).
- Add `INFOPLIST_KEY_SUFeedURL`, `INFOPLIST_KEY_SUPublicEDKey`, `INFOPLIST_KEY_SUEnableAutomaticChecks`, `INFOPLIST_KEY_SUEnableSystemProfiling`.

### Entitlements / signing
- `RaptureMac/RaptureMac/RaptureMac.entitlements`: sandbox **off**, Apple Events on. Hardened runtime **on** (Debug + Release). Release: Developer ID, manual signing, `--timestamp`. (Sparkle's XPC-service entitlements are sandbox-only → not needed.)

### App + UI
- `RaptureMac/RaptureMac/RaptureMacApp.swift` — `MenuBarExtra` + Settings `Window`; create the updater at launch here.
- `RaptureMac/RaptureMac/UI/MenuBarView.swift` — menu rows (~lines 56–102); "Check for Updates…" goes between the Settings divider (~94) and Quit (~97).
- `RaptureMac/RaptureMac/UI/SettingsAboutView.swift` — version line (`CFBundleShortVersionString`/`CFBundleVersion`, ~lines 51–56), Open Source section (~40); add the auto-update toggle + button + last-checked after it.
- `RaptureMac/RaptureMac/Persistence/SettingsStore.swift` — `binding(for:)` pattern for toggles (note: Sparkle owns the auto-check pref, so the toggle binds to the updater, not necessarily `settings.json`).

### Release pipeline
- `Scripts/release.sh` — VERSION/BUILD read from the built Info.plist (~lines 150–153); DMG at `$DERIVED/Rapture-$VERSION.dmg`; SHA-256 (~line 246); stages numbered /10 after the staple-the-app change. Appcast stage slots after Stage 9 (validate), before Stage 10 (summary).
- `Scripts/set_git_version.sh` — version source of truth.

### Confirmed absent
- No existing networking/update code (`grep URLSession|Sparkle|SUFeedURL|appcast` → none). This is net-new.
