#!/bin/bash
set -euo pipefail

# Builds the LiveContainer archive consumed by package-plain.sh / package-sidestore.sh.
# Keep the invocation as-is: the project ad-hoc signs its own nested binaries during
# the archive step, and forcing CODE_SIGNING_ALLOWED=NO would change what the IPAs
# ship (no _CodeSignature folders inside the frameworks/extensions).
#
# Requires the litehook submodule to be checked out:
#   git submodule update --init litehook
#
# Usage: scripts/build-archive.sh [archive-path]

cd "$(dirname "$0")/.."

ARCHIVE=${1:-build/LiveContainer.xcarchive}
[[ "$ARCHIVE" = /* ]] || ARCHIVE="$PWD/$ARCHIVE"

xcodebuild archive \
    -project LiveContainer.xcodeproj \
    -scheme LiveContainer \
    -sdk iphoneos \
    -arch arm64 \
    -configuration Release \
    -archivePath "$ARCHIVE"

echo "archive: $ARCHIVE"
