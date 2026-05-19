#!/bin/bash
# =============================================================================
# Git-Based Auto Versioning for Rapture for Mac
# =============================================================================
#
# Mirrors ../rapture-ios/Rapture/Scripts/set_git_version.sh so both apps under
# the Rapture product line produce identical version names on the same commit
# of their respective `main` branches (modulo per-repo commit counts).
#
# Versioning scheme (Chrome-inspired, matching Android and iOS):
#
#   Main branch:
#     CFBundleShortVersionString = MAJOR.MINOR.COMMITS    (e.g., "1.0.53")
#     CFBundleVersion            = (MAJOR * 1000000) + COMMITS  (e.g., "1000053")
#
#   Feature branch:
#     CFBundleShortVersionString = MAJOR.MINOR.MAIN_COMMITS+BRANCH_COMMITS-BRANCH-HASH
#                                  (e.g., "1.0.48+5-feature/dmg-a1b2c3d")
#     CFBundleVersion            = 9999 (fixed; dev builds are not shipped)
#
#   Git unavailable:
#     CFBundleShortVersionString = "1.0.dev"
#     CFBundleVersion            = "9999"
#
# Runs as an Xcode Run Script build phase after the Resources phase.
# IMPORTANT: This script NEVER modifies source files. It only writes to the
# built Info.plist at ${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}.
# =============================================================================

set -euo pipefail

# --- Constants ---
MAJOR_VERSION=1
MINOR_VERSION=0
FALLBACK_BUILD_NUMBER=9999
FALLBACK_VERSION_NAME="1.0.dev"

# --- Target plist ---
PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"

if [ ! -f "$PLIST" ]; then
    echo "[AutoVersion] WARNING: Built Info.plist not found at $PLIST — skipping"
    exit 0
fi

# --- Check git availability ---
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "[AutoVersion] git unavailable — using fallback: ${FALLBACK_VERSION_NAME} (${FALLBACK_BUILD_NUMBER})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${FALLBACK_VERSION_NAME}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FALLBACK_BUILD_NUMBER}" "$PLIST"
    exit 0
fi

# --- Determine current branch ---
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -z "$BRANCH" ]; then
    echo "[AutoVersion] Could not determine branch — using fallback: ${FALLBACK_VERSION_NAME} (${FALLBACK_BUILD_NUMBER})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${FALLBACK_VERSION_NAME}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FALLBACK_BUILD_NUMBER}" "$PLIST"
    exit 0
fi

# --- Main branch ---
if [ "$BRANCH" = "main" ]; then
    COMMIT_COUNT=$(git rev-list --count main 2>/dev/null || echo "")

    if [ -z "$COMMIT_COUNT" ]; then
        echo "[AutoVersion] git rev-list failed on main — using fallback: ${FALLBACK_VERSION_NAME} (${FALLBACK_BUILD_NUMBER})"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${FALLBACK_VERSION_NAME}" "$PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FALLBACK_BUILD_NUMBER}" "$PLIST"
        exit 0
    fi

    VERSION_NAME="${MAJOR_VERSION}.${MINOR_VERSION}.${COMMIT_COUNT}"
    VERSION_CODE=$(( MAJOR_VERSION * 1000000 + COMMIT_COUNT ))

    echo "[AutoVersion] main branch: ${VERSION_NAME} (${VERSION_CODE})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION_NAME}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION_CODE}" "$PLIST"
    exit 0
fi

# --- Feature branch ---
MERGE_BASE=$(git merge-base HEAD main 2>/dev/null || echo "")

if [ -z "$MERGE_BASE" ]; then
    echo "[AutoVersion] No merge-base with main — using fallback: ${FALLBACK_VERSION_NAME} (${FALLBACK_BUILD_NUMBER})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${FALLBACK_VERSION_NAME}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FALLBACK_BUILD_NUMBER}" "$PLIST"
    exit 0
fi

MAIN_COUNT_AT_MERGE=$(git rev-list --count "$MERGE_BASE" 2>/dev/null || echo "")
BRANCH_COMMITS=$(git rev-list --count "${MERGE_BASE}..HEAD" 2>/dev/null || echo "")
SHORT_HASH=$(git rev-parse --short=7 HEAD 2>/dev/null || echo "")

if [ -z "$MAIN_COUNT_AT_MERGE" ] || [ -z "$BRANCH_COMMITS" ]; then
    echo "[AutoVersion] git error calculating feature branch version — using fallback: ${FALLBACK_VERSION_NAME} (${FALLBACK_BUILD_NUMBER})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${FALLBACK_VERSION_NAME}" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${FALLBACK_BUILD_NUMBER}" "$PLIST"
    exit 0
fi

HASH_SUFFIX=""
if [ -n "$SHORT_HASH" ]; then
    HASH_SUFFIX="-${SHORT_HASH}"
fi

VERSION_NAME="${MAJOR_VERSION}.${MINOR_VERSION}.${MAIN_COUNT_AT_MERGE}+${BRANCH_COMMITS}-${BRANCH}${HASH_SUFFIX}"
VERSION_CODE="${FALLBACK_BUILD_NUMBER}"

echo "[AutoVersion] feature branch: ${VERSION_NAME} (${VERSION_CODE})"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION_NAME}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION_CODE}" "$PLIST"
exit 0
