#!/usr/bin/env bash
#
# Build Arya IPTV Portal.app.
#
# Usage:
#   ./scripts/build-app.sh                 # release build
#   CONFIGURATION=debug ./scripts/build-app.sh
#
# Optional environment variables:
#   ARYA_SDK                 Explicit SDK path (e.g. a Command Line Tools SDK)
#   ARYA_SWIFT_FLAGS         Extra flags passed to swift build (space separated)
#   CODESIGN_IDENTITY        Signing identity; defaults to ad-hoc "-"
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
BUILD_PRODUCT="StalkerDesk"
APP_NAME="Arya IPTV Portal"
EXECUTABLE_NAME="AryaIPTVPortal"
APP_DIR="$ROOT/.build/${APP_NAME}.app"

EXTRA_FLAGS=()
SDK_VALUE="${ARYA_SDK:-${STALKERDESK_SDK:-}}"
SWIFT_FLAGS_VALUE="${ARYA_SWIFT_FLAGS:-${STALKERDESK_SWIFT_FLAGS:-}}"
if [[ -n "$SDK_VALUE" ]]; then
    EXTRA_FLAGS+=(--sdk "$SDK_VALUE")
fi
if [[ -n "$SWIFT_FLAGS_VALUE" ]]; then
    # shellcheck disable=SC2206
    EXTRA_FLAGS+=(${SWIFT_FLAGS_VALUE})
fi

echo "Building ${APP_NAME} (${CONFIGURATION})…"
swift build -c "$CONFIGURATION" "${EXTRA_FLAGS[@]}"

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path "${EXTRA_FLAGS[@]}")"
BINARY="$BIN_DIR/${BUILD_PRODUCT}"
if [[ ! -x "$BINARY" ]]; then
    echo "error: built binary not found at $BINARY" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/${EXECUTABLE_NAME}"
chmod +x "$APP_DIR/Contents/MacOS/${EXECUTABLE_NAME}"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 || true
fi

IDENTITY="${CODESIGN_IDENTITY:--}"
if command -v codesign >/dev/null 2>&1; then
    CODESIGN_ARGS=(--force --deep --sign "$IDENTITY")
    if [[ "$IDENTITY" != "-" ]]; then
        CODESIGN_ARGS+=(--options runtime --timestamp)
    fi
    if ! codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"; then
        echo "warning: codesign failed; the app may still run locally" >&2
    fi
fi

echo "Built $APP_DIR"
echo "Run with: open \"$APP_DIR\""
