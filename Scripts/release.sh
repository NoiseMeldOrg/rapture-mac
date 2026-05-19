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
APP_NAME="RaptureMac.app"          # filesystem bundle name (Display Name "Rapture for Mac" via CFBundleDisplayName)
DMG_VOLNAME="Rapture for Mac"      # name of the mounted DMG volume in Finder
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

# --- Stage 1: Sanity ---
say "Stage 1/9: sanity checks"
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
say "Stage 2/9: clean + build (Release)"
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
say "Stage 3/9: read built version"
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
say "Stage 4/9: verify codesign"
run codesign --verify --deep --strict --verbose=2 "$APP"
echo
say "Stage 4b/9: dump signed entitlements"
run codesign -d --entitlements - --xml "$APP"

# --- Stage 5: Build DMG ---
say "Stage 5/9: build DMG"
DMG="$DERIVED/Rapture-for-Mac-$VERSION.dmg"
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

# --- Stage 6: Notarize ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 6/9: notarize — SKIPPED (--skip-notarize)"
else
  say "Stage 6/9: notarize (may take 30s–10min)"
  run xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
fi

# --- Stage 7: Staple ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 7/9: staple — SKIPPED (--skip-notarize)"
else
  say "Stage 7/9: staple"
  run xcrun stapler staple "$DMG"
fi

# --- Stage 8: Assess ---
if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  say "Stage 8/9: spctl assess — SKIPPED (--skip-notarize)"
else
  say "Stage 8/9: spctl assess + stapler validate"
  run spctl --assess --type install --verbose=2 "$DMG"
  run xcrun stapler validate "$DMG"
fi

# --- Stage 9: Summary ---
say "Stage 9/9: summary"
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
