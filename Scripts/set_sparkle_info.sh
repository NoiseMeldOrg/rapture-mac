#!/bin/bash
# =============================================================================
# Sparkle Info.plist configuration for Rapture for Mac
# =============================================================================
#
# Xcode generates the Info.plist (GENERATE_INFOPLIST_FILE = YES) and only injects
# Apple-known INFOPLIST_KEY_* settings, so Sparkle's custom keys can't be set that
# way. This Run Script phase writes them into the built Info.plist after generation
# — the same approach Scripts/set_git_version.sh uses for the version keys.
#
# IMPORTANT: NEVER modifies source files. Only the built Info.plist at
# ${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}.
# =============================================================================

set -euo pipefail

# --- Sparkle configuration ---
FEED_URL="https://raw.githubusercontent.com/NoiseMeldOrg/rapture-mac/main/appcast.xml"

# EdDSA public key that pairs with the private signing key used by
# Scripts/release.sh (sign_update). Generate the pair ONCE with Sparkle's
# `generate_keys` (stores the private key in your login keychain) and paste the
# printed public key below. Until then it's a placeholder and updates won't verify.
PUBLIC_ED_KEY="REPLACE_WITH_SPARKLE_EDDSA_PUBLIC_KEY"

PLIST="${BUILT_PRODUCTS_DIR:-}/${INFOPLIST_PATH:-}"
if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ ! -f "$PLIST" ]; then
  echo "warning: set_sparkle_info.sh: built Info.plist not found at '$PLIST'; skipping." >&2
  exit 0
fi

set_key() {  # name type value
  /usr/libexec/PlistBuddy -c "Set :$1 $3" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$PLIST"
}

set_key SUFeedURL string "$FEED_URL"
set_key SUPublicEDKey string "$PUBLIC_ED_KEY"
set_key SUEnableAutomaticChecks bool true
set_key SUEnableSystemProfiling bool false

echo "set_sparkle_info.sh: wrote Sparkle keys to $PLIST"
