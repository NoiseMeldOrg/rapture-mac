# Milestone 4 — Public Release · build log

> Authored at end of M4 build, 2026-05-19. Covers Phase 14 of the spec — code signing, notarization, DMG packaging — plus the FOSS public-flip work and the M1/M2/M3 carry-over auto-versioning.

## Status

**Shipped.** First public release artifact is **`Rapture-for-Mac-1.0.18.dmg`** — Developer ID signed, Apple-notarized, stapled, attached to a draft GitHub Release at `https://github.com/NoiseMeldOrg/rapture-mac/releases/tag/untagged-4c31a97ec753d3435a88`. The repo flip to public + draft publish are gated on explicit user OK and are run as the final step of this milestone.

All 80 tests pass (M1: 8 · M2: 36 · M3: 29 · M4: 7 from the vibe-security-driven attachment-filename sanitizer). Builds emit zero warnings.

## What was built

### Auto-versioning — `Scripts/set_git_version.sh`

Direct adaptation of `../rapture-ios/Rapture/Scripts/set_git_version.sh`. Constants `MAJOR_VERSION=1`, `MINOR_VERSION=0`, `FALLBACK_BUILD_NUMBER=9999`, `FALLBACK_VERSION_NAME="1.0.dev"` — full parity with iOS.

Writes to `${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}` via `PlistBuddy`. Three branches:

- **Main**: `VERSION = MAJOR.MINOR.${commit_count}`, `CODE = MAJOR*1_000_000 + count`. So the first release built with this script is `1.0.18 (1000018)` (18 = commit count on main at build time).
- **Feature branch**: `VERSION = MAJOR.MINOR.${main_at_merge}+${branch_commits}-${branch}-${hash}`, `CODE = 9999`. Dev builds aren't shipped, so the build number is fixed.
- **Fallback** (git unavailable / branch unknown): `1.0.dev (9999)`.

`SettingsAboutView` already reads `CFBundleShortVersionString` / `CFBundleVersion` from `Bundle.main`, so the About tab picks up the auto-generated values with no view changes needed.

### Xcode integration

- **New `PBXShellScriptBuildPhase`** on the `RaptureMac` target, named "Auto-Version (git commit count)". Positioned after the Resources phase (mirrors iOS). `alwaysOutOfDate = 1` so the phase runs every build — Xcode's default dependency-analysis caching would otherwise ship stale versions.
- **Release config signing settings** (Debug stays ad-hoc):
  - `CODE_SIGN_IDENTITY = "Developer ID Application"`
  - `CODE_SIGN_STYLE = Manual` (Developer ID doesn't use provisioning profiles)
  - `DEVELOPMENT_TEAM = P8PLTH44DF`
  - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` (see "Notarization fixes" below)
  - `OTHER_CODE_SIGN_FLAGS = "--timestamp"` (also see below)
- `ENABLE_HARDENED_RUNTIME = YES` was already set from M1; not touched.

### Release orchestration — `Scripts/release.sh`

Function-per-stage bash, `set -euo pipefail`. CLI:

```
./Scripts/release.sh               # full pipeline
./Scripts/release.sh --dry-run     # print steps only
./Scripts/release.sh --skip-notarize  # build + sign + DMG, no submission
```

Stages (each one logs `==> Stage N/9: <name>` and bails on first failure):

1. **Sanity**: in repo root, on `main`, clean working tree, `create-dmg` on PATH, Developer ID Application cert in keychain, `rapture-mac-notary` keychain profile configured.
2. **Clean + build**: `xcodebuild -derivedDataPath /tmp/RaptureMacDerived -configuration Release clean build`. Always uses APFS-derived path (the M1/M2/M3 environment note about exFAT AppleDouble files breaking codesign is honored here).
3. **Version capture**: read `CFBundleShortVersionString` back from the built Info.plist (set by the Run Script phase) so the DMG filename gets the right version.
4. **Sign verification**: `codesign --verify --deep --strict --verbose=2` followed by `codesign -d --entitlements - --xml` to dump entitlements for the log.
5. **DMG build**: `create-dmg --volname "Rapture for Mac" --app-drop-link 425 120 ...` with the standard drag-to-Applications layout.
6. **Notarize**: `xcrun notarytool submit "$DMG" --keychain-profile rapture-mac-notary --wait`. Captures stdout to a log file; parses for `status: Accepted` because `notarytool submit --wait` exits 0 even when the final status is `Invalid` (this was the gotcha in the first live-build run — script sailed past the Invalid status into a misleading stapler error).
7. **Staple**: `xcrun stapler staple`.
8. **Assess**: `xcrun stapler validate`, then mount the DMG and run `spctl --assess --type execute` against the `.app` inside (the `.app`, not the DMG, is what Gatekeeper evaluates).
9. **Summary**: prints DMG path, size, SHA-256.

### Public-repo docs

- **`SECURITY.md`**: reporting flow to `michael@noisemeld.com`, supported versions, in-scope / out-of-scope clarifications, supply-chain transparency (one third-party dep — GRDB.swift — zero outbound network calls). Closes with the `xcrun stapler validate` + `spctl --assess` commands users can run before opening the DMG.
- **`CONTRIBUTING.md`**: build + test instructions including the `/tmp/RaptureMacDerived` exFAT-AppleDouble workaround, coding-style notes (the `@MainActor` default, pure-helper test pattern, OSLog subsystem), and the full first-time release setup — Developer ID cert creation walkthrough, `notarytool store-credentials` setup, `brew install create-dmg`.
- **`CHANGELOG.md`**: Keep-a-Changelog format. `[1.0.18]` section with Added (M1+M2+M3 feature surface), Security (signed, notarized, hardened runtime), Known issues (FDA manual grant, group chats not captured, no auto-update). `[Unreleased]` header on top for the next iteration.
- **`README.md`**: rewritten for public-facing first-touch. License + release badges, install section (download DMG → drag to Applications → grant FDA → done), numbered first-run walkthrough, verify-the-download commands, build-from-source pointer to `CONTRIBUTING.md`, out-of-scope summary linking back to `shape.md`, sibling repos block, license.

### Pre-public security audit (vibe-security skill)

Ran the `vibe-security` skill against the full codebase before flipping public. The skill is web-app-focused, so most of its categories (Supabase RLS, Firebase, payments) didn't apply. Surfaced one **medium-severity finding** worth acting on:

- **Path traversal via `attachment.transferName`** in `Writer/FileWriter.swift`. `URL.appendingPathComponent` does NOT normalize `..` segments, so an adversarial attachment filename from the sender of an iMessage attachment could write a file outside the user's chosen output folder. Exploitation requires the sender to be on the user's allowlist (or self-chat).

Fixed in `fix: sanitize attachment filenames to prevent path traversal` (commit `101ca0b`):

- Added pure-helper `FileWriter.sanitizeAttachmentFilename(_:)` — strips null bytes, collapses traversal segments via `(s as NSString).lastPathComponent`, replaces `/` and `:` separators, falls back to `"attachment"` for empty / `.` / `..` inputs.
- 7 unit tests in `FileWriterSanitizationTests.swift` cover normal names, traversal segments, absolute roots, dot-only fallback, null bytes, `:` separators, and unicode preservation.

Also confirmed in the audit:

- `osascript` subprocess passes text via argv (`process.arguments = ["-", text, chatGuid]`) — Swift's `Process` `posix_spawn`s directly, no shell. AppleScript treats argv items as literal strings. No injection vector.
- All `chat.db` SQL uses parameterized `?` placeholders. One query in `SelfChatResolver.fetchSelfChatGuid` interpolates an int constant (`dmChatStyle = 45`) and a count-derived placeholder string (`"?, ?, ..."`); both safe by construction since the database is also opened read-only (`config.readonly = true`).
- No secrets in tracked files. The notarization key lives outside the repo at `~/.appstoreconnect/private_keys/`.
- Zero `URLSession` / `URLRequest` / `NWConnection` anywhere — SECURITY.md's "zero outbound network calls" claim is grep-verifiable.

### Notarization fixes (first live run)

The first live `release.sh` invocation made it all the way through DMG creation, but **Apple's notary service rejected the binary** with two errors (commit `9a5972d` fixes both):

1. **"The signature does not include a secure timestamp."** When `CODE_SIGN_STYLE` is `Manual`, Xcode silently drops the `--timestamp` flag that Automatic style would have included. Notarization requires TSA-timestamped signatures. Fixed by adding `OTHER_CODE_SIGN_FLAGS = "--timestamp"` to the Release config.
2. **"The executable requests the `com.apple.security.get-task-allow` entitlement."** Xcode auto-injects this entitlement (which lets debuggers attach) into Manual-signed builds via `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`. Notarization forbids it in release binaries. Fixed by setting `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` on the Release config (Debug still gets it injected → Xcode debugger still works locally).

Also hardened `release.sh` to parse the `notarytool submit --wait` stdout for `status: Accepted`; without this, the script would have continued to the staple stage after an Invalid notarization and produced a misleading "Could not find base64 encoded ticket" error instead of the actual rejection reason.

### Final spctl-flag fix

After the successful notarization, `spctl --assess --type install` returned `rejected: no usable signature` against the DMG. **The DMG itself isn't signed** (a DMG container isn't expected to be signed — only the `.app` inside and the stapled ticket are verifiable); `--type install` is also the wrong flag for a DMG (it's for `.pkg` installers). Fixed in commit `2775b15` by:

- `xcrun stapler validate "$DMG"` — confirms the ticket is intact on the DMG.
- Mount the DMG via `hdiutil attach`, run `spctl --assess --type execute` on the `.app` inside (which is what Gatekeeper actually evaluates at install time), then `hdiutil detach`.

When this ran against the shipped DMG, the `.app` returned `accepted, source=Notarized Developer ID`. ✅

## Reproduce-a-release recipe

```sh
# Once, on a fresh maintainer's machine (full walkthrough in CONTRIBUTING.md):
#   1. Generate CSR via Keychain Access → Certificate Assistant.
#   2. developer.apple.com → + → "Developer ID Application" → upload CSR → download .cer → double-click.
#   3. Verify: security find-identity -v -p codesigning | grep "Developer ID Application"
#   4. xcrun notarytool store-credentials "rapture-mac-notary" \
#        --key ~/.appstoreconnect/private_keys/AuthKey_GX6DYX9S2M.p8 \
#        --key-id GX6DYX9S2M --issuer <issuer-uuid-from-asc-team-keys>
#   5. brew install create-dmg

# Each release:
git checkout main && git pull
./Scripts/release.sh    # ~30s build + variable notary wait + staple
# Output ends with: DMG path, size, SHA-256.
# Attach to a GitHub Release tagged v<VERSION> matching the printed version.
```

## Decisions made during implementation that weren't pre-specified

1. **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` only on Release** instead of explicitly setting `com.apple.security.get-task-allow = false` in the entitlements file. Cleaner separation — Debug still gets the debugger-attach entitlement injected, so dev workflow is unaffected. Documented because the alternative (single entitlements file with `get-task-allow = false`) would have broken Xcode debug-attach for ad-hoc Debug builds.

2. **`OTHER_CODE_SIGN_FLAGS = "--timestamp"` only** (no `--options runtime`). The `runtime` option is redundant when `ENABLE_HARDENED_RUNTIME = YES` is set (Xcode adds it automatically), so adding it to OTHER_CODE_SIGN_FLAGS would have caused codesign to receive `--options runtime --options runtime`, which works but is noisy.

3. **`xcrun notarytool wait` as a separate post-submit step** rather than relying entirely on `notarytool submit --wait`. The first live submission was Invalid (and came back in 90s); the second was Accepted but spent **~25 minutes** in Apple's notarization queue. The script's bash-level timeout is bounded, so detaching the wait into a re-runnable step lets the maintainer walk away from the build while Apple processes. Documented in the M4 milestone log so this isn't relitigated on the next release.

4. **DMG container is unsigned and unstapled directly; the stapled ticket lives on the DMG.** The `.app` inside is what Gatekeeper evaluates at install time, and it accepts on `source=Notarized Developer ID`. A "fully offline-first-launch" pattern would require stapling the `.app` itself (requires submitting the zipped `.app` separately, then re-packaging into a DMG); deferred to a future release. For v1, online-required first launch is the documented limitation in CHANGELOG and release notes.

5. **Notarization profile name is `rapture-mac-notary`** (not `rapture-notary` or `noisemeld-notary`). Keeps the profile per-product so a future MAS-targeting variant could use a separate profile under the same App Store Connect API key without name collision.

6. **`release.sh` does NOT publish the GitHub Release** — it stops after producing the local DMG. Publication is a separate `gh release create --draft` + `gh release edit --draft=false` flow because the public-flip step needs an explicit human OK (per the project's "don't push the public flip without my explicit OK" rule) and shouldn't be coupled to the automation script.

7. **Tag points to the build commit, not the doc-update commit.** `v1.0.18` is tagged at commit `9a5972d` (the fix commit that produced the binary), not at the later CHANGELOG / milestone-log update commits. This keeps `git checkout v1.0.18` reproducible — the tree at the tag actually corresponds to the artifact.

8. **`release.sh` parses `status:` from notarytool stdout via `grep`** rather than `--output-format json`. The non-JSON output preserves the "Current status: In Progress..." progress stream the user sees while waiting, which is load-bearing for a multi-minute wait. The `grep -q "status: Accepted"` check is robust because the output is line-formatted by notarytool itself.

9. **The CHANGELOG `[Unreleased]` header is kept above `[1.0.18]`** even though there's nothing in it yet. Standard Keep-a-Changelog practice — gives the next contributor an obvious place to add entries without restructuring the file.

10. **Verify-the-download commands are duplicated** in README.md and SECURITY.md. The same two commands (`xcrun stapler validate` and an assess check) appear in both. Intentional — the README points to install flow first-touch, SECURITY.md covers post-incident or pre-trust verification, and a curious user shouldn't have to follow a cross-reference.

## What M5+ will need to know (carry-over)

- **First-launch online dependency**: as long as the ticket is stapled only to the DMG (not the `.app`), Gatekeeper does an online lookup on first launch of the `.app` after install. If a future v1.0.x wants offline-first-launch support, the release flow needs to: zip the `.app`, submit and notarize the zip, staple to the `.app`, then re-package into a DMG, then (optionally) re-notarize+staple the DMG.
- **Notarization wait times are unbounded**. The May 2026 baseline turnaround for a first-cert submission appears to be 15–30 minutes; subsequent submissions from the same cert may be faster. Plan release flow around "submit, walk away, come back later" rather than "hold the terminal open."
- **`OTHER_CODE_SIGN_FLAGS = "--timestamp"`** is fragile-looking but necessary as long as Xcode keeps stripping the flag under Manual signing. If a future Xcode version restores the auto-include behavior for Manual style, this can be removed.
- **The `_build_plan/` folder is preserved in the public flip**. Per the project CLAUDE.md, it's historical/non-functional and ships alongside the source. This was a deliberate keep-it decision, not an accident.

## Deviations from the PRD / plan, and why

- **`release.sh` ships as a single orchestrator script** instead of separate sign / dmg / notarize scripts as the plan considered. The full pipeline is short enough (~150 lines) that splitting added more ceremony than maintainability. The `--skip-notarize` flag covers the "iterate locally" use case the multi-script alternative would have addressed.
- **`CHANGELOG.md` was added** even though the PRD's M4 scope didn't strictly call for it. Standard FOSS hygiene; cost was small (one short file).
- **No screenshots in the README** in v1. Adding one means picking a frame that doesn't leak personal handles or message text. The menu-bar UI is small enough that the prose carries the load. Easy follow-up for a future release.
- **No GitHub Actions / CI** — PRD explicitly says no CI/CD in v1. Honored. Tests are run by the release script's `xcodebuild` invocation as part of the Debug compile path before Release builds happen.

## Files that didn't exist at the start of M4 and now do

```
Scripts/set_git_version.sh
Scripts/release.sh
SECURITY.md
CONTRIBUTING.md
CHANGELOG.md
RaptureMac/RaptureMacTests/FileWriterSanitizationTests.swift
_build_plan/milestones/4-public-release/milestone-log.md
```

## Files modified

- `README.md` — public-facing rewrite with install + first-run walkthrough.
- `RaptureMac/RaptureMac.xcodeproj/project.pbxproj` — Release-config signing settings, Run Script build phase wiring, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`, `OTHER_CODE_SIGN_FLAGS="--timestamp"`.
- `RaptureMac/RaptureMac/Writer/FileWriter.swift` — added `sanitizeAttachmentFilename` helper plus its wiring at the attachment-copy call site.

Total: 7 new files + 3 modified. Five commits on `main` from `6d58f93` (M3 end) to `2775b15` (final M4 spctl fix):

- `101ca0b fix: sanitize attachment filenames to prevent path traversal` (vibe-security finding)
- `85bd543 feat(M4): public release — signing, notarization, DMG packaging, docs`
- `9a5972d fix(M4): notarizable Release config — timestamp + drop get-task-allow` ← **build commit for v1.0.18**
- `2775b15 fix(M4): release.sh — use correct Gatekeeper-assessment flags for a DMG`
- *(this commit, when it lands)* — CHANGELOG entry for v1.0.18 + M4 milestone log

## v1 done-when verification (full pipeline)

The PRD's M4 "Done when" — *"A first-time user can navigate to https://github.com/NoiseMeldOrg/rapture-mac, find the latest Release, download the DMG, double-click to open, drag `Rapture for Mac.app` into Applications, launch it, go through the FDA and Automation prompts, send themselves an iMessage from across the room, and receive a `✓ Saved` confirmation — without ever opening a terminal or seeing the source code"* — is gated on the public flip + draft publish (next user-OK'd step) and a human walking the install+capture flow.

What's been verified mechanically through M4:

- ✅ DMG builds reproducibly from `main`.
- ✅ Built `.app` passes `codesign --verify --deep --strict`.
- ✅ Built `.app` has no `get-task-allow` entitlement.
- ✅ Signature has TSA timestamp.
- ✅ Hardened runtime active.
- ✅ Apple notarized the submission (`status: Accepted`).
- ✅ Notarization ticket stapled to the DMG.
- ✅ `xcrun stapler validate` passes against the DMG.
- ✅ Gatekeeper accepts the mounted `.app` with `source=Notarized Developer ID`.
- ✅ GitHub Release exists in draft state with the DMG attached, tagged `v1.0.18` against the build commit, SHA-256 verified against the local hash.

The end-to-end Siri-dictation → file-on-disk → `✓ Saved` reply flow is the same test M1/M2 deferred to the user — it requires a human granting FDA and Automation, then dictating into a locked iPhone, which can't run inside this Claude Code session.
