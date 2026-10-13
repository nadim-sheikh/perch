#!/bin/bash
# Builds Perch.app (universal, ad-hoc signed).
# Output goes to ~/Applications by default (override with OUT_DIR); exFAT drives
# add ._ files that break code signing, so build onto an APFS volume.
set -euo pipefail
cd "$(dirname "$0")"

# The standard build uses Anthropic, OpenAI or xAI keys. With PERCH_OPENROUTER=1, or a `.perch-local`
# file next to this script (git-ignored), Perch is built to use OpenRouter instead.
FLAGS=(-c release --arch arm64 --arch x86_64)
# PERCH_OPENROUTER=0 forces the standard build even when .perch-local exists.
if [[ "${PERCH_OPENROUTER:-}" == "1" || ( -f .perch-local && "${PERCH_OPENROUTER:-}" != "0" ) ]]; then
  FLAGS+=(-Xswiftc -DPERCH_OPENROUTER)
  echo "Building the OpenRouter edition."
fi
swift build "${FLAGS[@]}"
BIN="$(swift build "${FLAGS[@]}" --show-bin-path)/Perch"

OUT_DIR="${OUT_DIR:-$HOME/Applications}"
mkdir -p "$OUT_DIR"
APP="$OUT_DIR/Perch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Perch"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS can remember permissions for this build.
dot_clean -m "$APP" 2>/dev/null || true
find "$APP" -name "._*" -delete
# A stable identity lets macOS remember Screen Recording / Accessibility across builds.
IDENTITY="${PERCH_SIGN_IDENTITY:-Perch Developer}"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --deep --sign "$IDENTITY" --entitlements Resources/Perch.entitlements "$APP"
else
  echo "Note: '$IDENTITY' certificate not found; using an ad-hoc signature (permissions reset on each build)."
  codesign --force --deep --sign - --entitlements Resources/Perch.entitlements "$APP"
fi
echo "Built $APP"
