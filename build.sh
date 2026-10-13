#!/bin/bash
# Builds OpenBuddy.app (universal, ad-hoc signed).
# Output goes to ~/Applications by default (override with OUT_DIR); exFAT drives
# add ._ files that break code signing, so build onto an APFS volume.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/OpenBuddy"

OUT_DIR="${OUT_DIR:-$HOME/Applications}"
mkdir -p "$OUT_DIR"
APP="$OUT_DIR/OpenBuddy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenBuddy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS can remember permissions for this build.
dot_clean -m "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete
codesign --force --deep --sign - --entitlements Resources/OpenBuddy.entitlements "$APP"
echo "Built $APP"
