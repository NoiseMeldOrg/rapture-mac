---
name: release-rapture-mac
description: Cut a notarized Rapture for Mac release end-to-end — run the build/sign/notarize/staple/DMG pipeline, then publish it (CHANGELOG cut, git tag at the build commit, GitHub Release with the DMG attached), and optionally install it locally. Use this whenever the user says "cut a release", "cut the release", "release rapture-mac", "ship a release", "publish a release", "make a new release", or invokes `/release-rapture-mac`. This is the rapture-mac repo's release ritual; it encodes the non-obvious steps (version = commit count, tag points to the BUILD commit not the changelog-cut commit, push the tag before `gh release create`) that are easy to get wrong by hand.
---

# Cut a Rapture for Mac release

Releases are notarized, Developer ID-signed DMGs attached to GitHub Releases (no Mac App Store). `Scripts/release.sh` does the mechanical half (build → sign → notarize → staple → DMG); the rest of this skill is the **publish ritual** around it. Human-readable maintainer docs for the same flow live in `CONTRIBUTING.md → "Cutting a release"` — keep the two in sync if you change one.

## Preconditions (the script enforces these; check first)

- On `main`, working tree clean, `git pull` done.
- One-time setup present: `Developer ID Application` cert for team `P8PLTH44DF`, `notarytool` keychain profile `rapture-mac-notary`, and `create-dmg` (`brew install create-dmg`). See `CONTRIBUTING.md → "First-time release setup"`.
- The `CHANGELOG.md` `[Unreleased]` section already describes what's shipping. If it's empty or stale, stop and write it (with the user) before building — the release notes are sourced from it.

## The version + tag rule — read this before tagging

- **Version = `git rev-list --count HEAD`** on `main` → `1.0.<count>` (from `Scripts/set_git_version.sh`, baked into the build's Info.plist).
- The **build commit is HEAD *before* the changelog-cut commit.** You build first (clean tree required), then make the cut commit — which increments the commit count by one. So the release tag must point at the **build commit**, not at HEAD after the cut. Capture the build SHA before cutting.
- `gh release create --target <short-sha>` is **rejected** (`target_commitish is invalid`). Create and push the git tag explicitly first, then `gh release create` against the existing tag.

## Steps

1. **Capture the build commit and intended version.**
   ```sh
   BUILD_COMMIT=$(git rev-parse HEAD)
   VERSION=1.0.$(git rev-list --count HEAD)   # sanity-check against what the build reports
   ```

2. **Run the pipeline in the background** (build + notarization together take several minutes; signing may pop a one-time keychain prompt — tell the user to approve it):
   ```sh
   ./Scripts/release.sh 2>&1 | tee /tmp/rapture-release-$VERSION.log
   ```
   When it finishes (exit 0), read the Stage 9 summary for the authoritative `Version` and `SHA-256`. Confirm `status: Accepted`, the staple/validate lines, and `spctl … accepted`. The DMG is at `/tmp/RaptureMacDerived/Rapture-<VERSION>.dmg`.

3. **Cut the CHANGELOG.** Turn `## [Unreleased]` into a versioned section and leave a fresh empty `[Unreleased]` above it. Match the existing format exactly:
   ```
   ## [Unreleased]

   ## [1.0.NN] - YYYY-MM-DD: <subtitle>

   Built from commit `<short BUILD_COMMIT>`. SHA-256: `<sha from summary>`.

   <one short paragraph of context>

   ### Added / Changed / Fixed / Tests …
   ```

4. **Bump the roadmap status line** in `agent-os/product/roadmap.md` (`> Status: … latest public release v1.0.NN live on GitHub Releases (YYYY-MM-DD)` and `> Last Updated:`).

5. **Commit the cut** and push `main`:
   ```sh
   git add CHANGELOG.md agent-os/product/roadmap.md
   git commit -m "docs(changelog): cut v1.0.NN — <subtitle>" -m "<body w/ SHA-256>" \
     -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
   git push origin main
   ```

6. **Tag the build commit and push the tag** (NOT HEAD — see the version+tag rule):
   ```sh
   git tag v1.0.NN "$BUILD_COMMIT"
   git push origin v1.0.NN
   ```

7. **Create the GitHub Release** from the pushed tag, DMG attached, notes from the changelog:
   ```sh
   gh release create v1.0.NN \
     --title "Rapture 1.0.NN — <subtitle>" \
     --notes "<release notes incl. 'Built from commit … SHA-256: …'>" \
     /tmp/RaptureMacDerived/Rapture-1.0.NN.dmg
   ```
   Verify: `gh release view v1.0.NN --json name,url,tagName,assets` shows the DMG `uploaded`, and `gh release list` shows it as `Latest`.

8. **(Optional) Install locally** if the user wants this Mac on the new build — see "Install + make-it-the-only-version" below.

## Install + make-it-the-only-version (optional)

```sh
pkill -f "Rapture.app/Contents/MacOS/Rapture"          # quit running instances
MP=$(hdiutil attach -nobrowse -plist /tmp/RaptureMacDerived/Rapture-1.0.NN.dmg \
      | plutil -extract system-entities.0.mount-point raw - | tail -1)
rm -rf /Applications/Rapture.app && ditto "$MP/Rapture.app" /Applications/Rapture.app
hdiutil detach "$MP"
spctl --assess --type execute --verbose=2 /Applications/Rapture.app   # expect: accepted, Notarized Developer ID
open /Applications/Rapture.app
```
To leave only the installed copy, remove stray build products under `/tmp/RaptureMacDerived`, `/tmp/rapture-dd-*`, and the Mac app's Xcode `DerivedData/RaptureMac-*` folder. **Do not** delete the `…Debug-iphonesimulator/Rapture.app` under `DerivedData/Rapture-*` — that's the separate **iOS** app (`noisemeld.Rapture`), a different product.

## Gotchas (each has bitten a real release)

- **Tag the build commit, not the cut commit.** The cut commit's count is one higher than the released version. Tagging HEAD after the cut yields a tag whose rebuild would produce `1.0.(NN+1)`.
- **`gh release --target <sha>` fails** with `target_commitish is invalid` for a short SHA. Push the tag first; create the release from the tag name.
- **The DMG is stapled; the `.app` inside is not** individually stapled. After install, `xcrun stapler validate /Applications/Rapture.app` says "no ticket" — that's expected; `spctl --assess` returning `accepted / Notarized Developer ID` is the check that matters (Gatekeeper validates notarization online).
- **Build on the internal APFS volume** (`/tmp/RaptureMacDerived`). The repo's external SSD generates AppleDouble (`._*`) files that get copied into the bundle and break `codesign`. `release.sh` already routes derived data there.
- **Notarization can take up to ~10 min** and `notarytool` exits 0 even on `status: Invalid` — always confirm `status: Accepted` in the log, which `release.sh` already parses.
