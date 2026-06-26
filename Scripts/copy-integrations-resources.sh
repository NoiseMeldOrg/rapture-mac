#!/bin/bash
# Bundle Scripts/ + examples/ into the .app's Contents/Resources/ at build time.
# Source of truth: this repo's Scripts/ and examples/ folders. The Integrations
# panel reads from Bundle.main.resourceURL/{Scripts,examples} at runtime, so
# nothing leaves the signed bundle to fetch them.
#
# Excludes dev-only scripts that have no user-facing role:
#   release.sh                       - DMG build orchestrator
#   set_git_version.sh               - Auto-Version build phase script
#   copy-integrations-resources.sh   - This script
#
# Also excludes macOS metadata files (._*, .DS_Store) that can break the
# signed bundle's resource layout on some macOS versions.

set -euo pipefail

SRC="${SRCROOT}/.."
DEST="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/Resources"

rsync -a --delete \
  --exclude='._*' --exclude='.DS_Store' \
  --exclude='release.sh' \
  --exclude='set_git_version.sh' \
  --exclude='copy-integrations-resources.sh' \
  "${SRC}/Scripts/" "${DEST}/Scripts/"

rsync -a --delete \
  --exclude='._*' --exclude='.DS_Store' \
  "${SRC}/examples/" "${DEST}/examples/"
