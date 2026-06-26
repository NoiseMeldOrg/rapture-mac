#!/bin/bash
# =============================================================================
# Rapture for Mac — release orchestrator
# =============================================================================
#
# Builds, signs, packages, notarizes, and staples a distributable DMG.
#
#   ./Scripts/release.sh               # full pipeline
#   ./Scripts/release.sh --dry-run     # print steps only, do nothing
#   ./Scripts/release.sh --skip-notarize  # local-DMG smoke test (no submission)
#
# Prerequisites (one-time, see CONTRIBUTING.md):
#   1. "Developer ID Application" cert for team P8PLTH44DF in the login keychain
#   2. notarytool keychain profile named "rapture-mac-notary" configured via:
#        xcrun notarytool store-credentials "rapture-mac-notary" \
#          --key ~/.appstoreconnect/private_keys/AuthKey_GX6DYX9S2M.p8 \
#          --key-id GX6DYX9S2M --issuer <your-issuer-uuid>
#   3. `brew install create-dmg`
#
# Why /tmp/RaptureMacDerived: the source SSD is exFAT and generates AppleDouble
# (._*) metadata files that get copied into the .app bundle and break codesign.
# Derived data must live on the internal APFS volume.
# =============================================================================

set -euo pipefail

# --- Parse flags ---
DRY_RUN=0
SKIP_NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h|--help)
      sed -n '3,15p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

# --- Constants ---
SCHEME="RaptureMac"
TEAM_ID="P8PLTH44DF"
SIGN_IDENTITY="Developer ID Application"
NOTARY_PROFILE="rapture-mac-notary"
DERIVED="/tmp/RaptureMacDerived"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Rapture.app"             # filesystem bundle name (Display Name "Rapture" via CFBundleDisplayName)
DMG_VOLNAME="Rapture"              # name of the mounted DMG volume in Finder
PROJECT="$REPO_ROOT/RaptureMac/RaptureMac.xcodeproj"

cd "$REPO_ROOT"

# --- Helpers ---
say()  { printf "\n==> %s\n" "$*"; }

# Print a command (with proper quoting via %q) when dry-run; otherwise execute it.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "  [dry-run]"
    printf " %q" "$@"
    printf "\n"
  else
    "$@"
  fi
}

# Submit one artifact (a .zip of the app, or the .dmg) to Apple's notary service and
# fail unless it reaches "status: Accepted". notarytool exits 0 even when the result is
# "Invalid", so we parse the log ourselves. Honors --dry-run.
#   notarize_and_check <artifact> <log-path>
notarize_and_check() {
  local artifact="$1" log="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf "  [dry-run] xcrun notarytool submit %q --keychain-profile %q --wait | tee %q\n" \
      "$artifact" "$NOTARY_PROFILE" "$log"
    return 0
  fi
  set +e
  xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "ERROR: notarytool submit exited $rc (transport / auth error, not a rejection)."
    exit 1
  fi
  if ! grep -q "status: Accepted" "$log"; then
    local sid; sid="$(grep -m1 '^[[:space:]]*id:' "$log" | awk '{print $2}')"
    echo
    echo "ERROR: notarization of $(basename "$artifact") did not reach status: Accepted."
    [ -n "$sid" ] && echo "  xcrun notarytool log $sid --keychain-profile $NOTARY_PROFILE"
    exit 1
  fi
}

# --- Stage 1: Sanity ---
say "Stage 1/10: sanity checks"
if [ ! -d "$REPO_ROOT/RaptureMac" ]; then
  echo "Not at repo root ($REPO_ROOT)"; exit 1
fi
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
  echo "Not on main branch (currently on $(git rev-parse --abbrev-ref HEAD))"
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "Working tree is not clean:"
  git status --short
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg not found on PATH. Install with: brew install create-dmg"
  exit 1
fi
if [ "$SKIP_NOTARIZE" -eq 0 ]; then
  if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY.*$TEAM_ID"; then
    echo "No \"$SIGN_IDENTITY\" cert for team $TEAM_ID in keychain."
    echo "See CONTRIBUTING.md → \"First-time release setup\" for the cert-creation walkthrough."
    exit 1
  fi
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "notarytool keychain profile \"$NOTARY_PROFILE\" is not configured."
    echo "See CONTRIBUTING.md → \"First-time release setup\"."
    exit 1
  fi
fi
echo "OK: on main, clean tree, create-dmg installed, cert + notary profile present."

# --- Stage 2: Clean + build ---
say "Stage 2/10: clean + build (Release)"
run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  clean build

APP="$DERIVED/Build/Products/Release/$APP_NAME"
if [ "$DRY_RUN" -eq 0 ] && [ ! -d "$APP" ]; then
  echo "Built .app not found at: $APP"
  exit 1
fi

# --- Stage 3: Read built version ---
say "Stage 3/10: read built version"
if [ "$DRY_RUN" -eq 1 ]; then
  VERSION="X.Y.Z"
  BUILD="NNNN"
else
  PLIST="$APP/Contents/Info.plist"
  VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
  BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
fi
echo "Version: $VERSION (build $BUILD)"

# --- Stage 4: Verify signing ---
say "Stage 4/10: verify codesign"
run codesign --verify --deep --strict --verbose=2 "$APP"
echo
say "Stage 4b/10: dump signed entitlements"
run codesign -d --entitlements - --xml "$APP"

# --- Stage 5: Notarize + staple the .app ---
# Staple the *app*, not just the DMG, so first launch succeeds even fully offline.
# Stapling requires the app to have been notarized, so zip it and submit that; the
# stapled app is then what gets packaged into the DMG below.
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 5/10: notarize + staple .app — SKIPPED (--skip-notarize)"
else
  say "Stage 5/10: notarize + staple .app (may take 30s–10min)"
  APP_ZIP="$DERIVED/Rapture-$VERSION-app.zip"
  if [ "$DRY_RUN" -eq 0 ] && [ -f "$APP_ZIP" ]; then rm -f "$APP_ZIP"; fi
  run ditto -c -k --keepParent "$APP" "$APP_ZIP"   # notarytool needs a zip, not a bundle
  notarize_and_check "$APP_ZIP" "$DERIVED/notarytool-app.log"
  run xcrun stapler staple "$APP"
  run xcrun stapler validate "$APP"
fi

# --- Stage 6: Build DMG ---
say "Stage 6/10: build DMG"
DMG="$DERIVED/Rapture-$VERSION.dmg"
if [ "$DRY_RUN" -eq 0 ] && [ -f "$DMG" ]; then
  rm -f "$DMG"
fi
run create-dmg \
  --volname "$DMG_VOLNAME" \
  --window-pos 200 120 \
  --window-size 600 320 \
  --icon-size 100 \
  --icon "$APP_NAME" 175 120 \
  --hide-extension "$APP_NAME" \
  --app-drop-link 425 120 \
  --no-internet-enable \
  "$DMG" \
  "$APP"

if [ "$DRY_RUN" -eq 0 ] && [ ! -f "$DMG" ]; then
  echo "DMG was not produced at: $DMG"
  exit 1
fi

# --- Stage 7: Notarize the DMG ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 7/10: notarize DMG — SKIPPED (--skip-notarize)"
else
  say "Stage 7/10: notarize DMG (may take 30s–10min)"
  notarize_and_check "$DMG" "$DERIVED/notarytool-dmg.log"
fi

# --- Stage 8: Staple the DMG ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 8/10: staple DMG — SKIPPED (--skip-notarize)"
else
  say "Stage 8/10: staple DMG"
  run xcrun stapler staple "$DMG"
fi

# --- Stage 9: Assess ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 9/10: stapler validate — SKIPPED (--skip-notarize)"
else
  say "Stage 9/10: stapler validate + mount-and-assess"
  run xcrun stapler validate "$DMG"
  # spctl on a DMG container directly returns "no usable signature" by design —
  # the meaningful check is on the .app inside, which Gatekeeper actually evaluates
  # at install time.
  if [ "$DRY_RUN" -eq 0 ]; then
    MOUNT_OUT="$(hdiutil attach -nobrowse -plist "$DMG")"
    MOUNT_POINT="$(echo "$MOUNT_OUT" | plutil -extract 'system-entities'.0.'mount-point' raw - 2>/dev/null | tail -1)"
    if [ -n "$MOUNT_POINT" ] && [ -d "$MOUNT_POINT/$APP_NAME" ]; then
      spctl --assess --type execute --verbose=2 "$MOUNT_POINT/$APP_NAME" || true
      hdiutil detach "$MOUNT_POINT" >/dev/null
    else
      echo "WARNING: could not mount DMG to assess the .app inside"
    fi
  fi
fi

# --- Stage 10: Summary ---
say "Stage 10/10: summary"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run complete. No artifacts produced."
  exit 0
fi
SIZE="$(du -h "$DMG" | cut -f1)"
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
cat <<EOF

  DMG:     $DMG
  Version: $VERSION (build $BUILD)
  Size:    $SIZE
  SHA-256: $SHA256

EOF
echo "Ready to attach to a GitHub Release."
