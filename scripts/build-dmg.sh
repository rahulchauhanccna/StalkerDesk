#!/usr/bin/env bash
#
# Build a distributable DMG for Arya IPTV Portal.
#
# Usage:
#   ./scripts/build-dmg.sh
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-dmg.sh
#
# Optional environment variables:
#   CODESIGN_IDENTITY  Developer ID Application identity
#   NOTARY_PROFILE     xcrun notarytool keychain profile for notarization
#   VERSION            Override the DMG version (defaults to CFBundleShortVersionString)
#
# A Developer ID signed, notarized DMG is required for frictionless installs on
# other Macs. An ad-hoc build is created when no identity is supplied; Gatekeeper
# will then require the user to right-click > Open or remove quarantine.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Arya IPTV Portal"
APP_PATH="$ROOT/.build/${APP_NAME}.app"
STAGING="$ROOT/.build/dmg-staging"
DIST="$ROOT/dist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")}"
DMG_PATH="$DIST/${APP_NAME} ${VERSION}.dmg"

# 1. Build the app bundle using the same toolchain flags as build-app.sh.
"$ROOT/scripts/build-app.sh"

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: app bundle not found at $APP_PATH" >&2
    exit 1
fi

# 2. Stage the app and an Applications shortcut.
rm -rf "$STAGING"
mkdir -p "$STAGING" "$DIST"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Create a compressed, read-only disk image.
rm -f "$DMG_PATH"
echo "Creating ${DMG_PATH}…"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$STAGING"

# 4. Optionally sign the disk image for distribution.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing disk image..."
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

# 5. Optionally notarize and staple.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "Submitting for notarization (profile: $NOTARY_PROFILE)…"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "Built $DMG_PATH"
