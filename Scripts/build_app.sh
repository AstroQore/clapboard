#!/usr/bin/env bash
# Build the Clapboard executable, wrap it into a .app bundle, and sign it.
# Usage: ./Scripts/build_app.sh [debug|release]
# Output: .build/Clapboard.app
#
# Signing defaults to ad-hoc. Because an ad-hoc signature's designated
# requirement is the binary's cdhash, macOS treats every rebuild as a new app
# and the Microphone permission has to be granted again (or is silently
# denied). Set CLAPBOARD_CODESIGN_IDENTITY to any Keychain code-signing
# identity — a self-signed "Code Signing" certificate made in Keychain Access
# is enough — to get a stable identity across rebuilds.
#
# The hardened runtime is intentionally NOT enabled in either mode: the app
# loads third-party AUv2 plug-ins in-process, which library validation blocks.
set -euo pipefail

CONFIG="${1:-release}"
SIGN_IDENTITY="${CLAPBOARD_CODESIGN_IDENTITY:--}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXEC_PATH="$BIN_DIR/Clapboard"
if [[ ! -x "$EXEC_PATH" ]]; then
    echo "Executable not found at $EXEC_PATH" >&2
    exit 1
fi

APP_DIR="$ROOT/.build/Clapboard.app"
ENTITLEMENTS="$ROOT/Resources/Clapboard.entitlements"
echo "==> packaging $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXEC_PATH" "$APP_DIR/Contents/MacOS/Clapboard"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
# SwiftPM resource bundles (none yet); copied verbatim if a target adds one.
for bundle in "$BIN_DIR"/Clapboard_*.bundle; do
    [[ -d "$bundle" ]] && cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> ad-hoc codesign (microphone permission will not survive rebuilds; see header)"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
    echo "==> codesign with identity: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "==> done: $APP_DIR"
echo "Run with: open \"$APP_DIR\""
