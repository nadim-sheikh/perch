#!/bin/bash
# Builds the standard edition (bring your own Anthropic, OpenAI or xAI key) and packs it into
# dist/Perch-<version>.dmg with an Applications shortcut for drag-to-install.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
WORK="$(mktemp -d)"
STAGE="$WORK/Perch"
mkdir -p "$STAGE"
trap 'rm -rf "$WORK"' EXIT

# Ad-hoc signed: there is no paid Apple Developer ID, so first launch needs right-click → Open.
PERCH_OPENROUTER=0 PERCH_SIGN_IDENTITY=none OUT_DIR="$STAGE" ./build.sh
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
hdiutil create -volname "Perch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$WORK/Perch-$VERSION.dmg" >/dev/null
mv -f "$WORK/Perch-$VERSION.dmg" "dist/Perch-$VERSION.dmg"
echo "Built dist/Perch-$VERSION.dmg"
