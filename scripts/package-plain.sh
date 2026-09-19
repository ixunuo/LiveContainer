#!/bin/bash
set -euo pipefail

# Packages the plain LiveContainer IPA (no SideStore), mirroring the upstream
# .github/build_github.sh recipe.
#
# Usage: scripts/package-plain.sh <LiveContainer.xcarchive> [output.ipa]

ARCHIVE=${1:?usage: package-plain.sh <LiveContainer.xcarchive> [output.ipa]}
START=$PWD
OUT=${2:-LiveContainer.ipa}
[[ "$OUT" = /* ]] || OUT="$START/$OUT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cp -R "$ARCHIVE/Products/Applications" "$WORK/Payload"
# upstream ships the plain IPA without the SideStore support framework
rm -rf "$WORK/Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework"

cd "$WORK"
zip -q -r "$OUT" Payload -x "._*" -x ".DS_Store" -x "__MACOSX"
echo "created: $OUT"
