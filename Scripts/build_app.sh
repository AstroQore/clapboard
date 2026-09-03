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

# --- the bundled virtual-device installer -------------------------------------
#
# The app carries ClapboardDriver.pkg (and its uninstaller) so that the setup
# assistant can hand the package straight to Installer.app: nobody has to
# clone the repository, run a shell script or download anything to get
# Clapboard Bus 1…4. ClapboardDriverInstaller.plist beside them records the
# driver's version, because reading a version out of a .pkg at launch would
# mean cracking open an xar archive.
#
# A driver that will not build must NOT fail the app build. Without the
# package the app reports `installerUnavailable` and the assistant points at
# Scripts/build_driver_pkg.sh — an app you can still use beats no app.
DRIVER_LOG="$ROOT/.build/build_driver_pkg.log"
DRIVER_BUNDLE="$ROOT/.build/ClapboardDriver.driver"
DRIVER_PKG="$ROOT/.build/ClapboardDriver.pkg"
DRIVER_UNINSTALLER_PKG="$ROOT/.build/ClapboardDriverUninstaller.pkg"

if [[ "${CLAPBOARD_SKIP_DRIVER_PKG:-0}" == "1" ]]; then
    echo "==> CLAPBOARD_SKIP_DRIVER_PKG=1: skipping the bundled driver installer"
else
    echo "==> building the virtual-device installer (log: $DRIVER_LOG)"
    if ! { "$ROOT/Scripts/build_driver_pkg.sh" \
        && "$ROOT/Scripts/build_driver_uninstaller_pkg.sh"; } > "$DRIVER_LOG" 2>&1; then
        echo "WARNING: the driver installer failed to build. The app will be" >&2
        echo "         built WITHOUT it and will say so in its setup assistant." >&2
        echo "         Last lines of $DRIVER_LOG:" >&2
        tail -n 15 "$DRIVER_LOG" | sed 's/^/         /' >&2
    fi
fi

if [[ -f "$DRIVER_PKG" && -f "$DRIVER_BUNDLE/Contents/Info.plist" ]]; then
    DRIVER_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$DRIVER_BUNDLE/Contents/Info.plist")"
    DRIVER_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$DRIVER_BUNDLE/Contents/Info.plist")"
    DRIVER_BUS_COUNT="$(/usr/libexec/PlistBuddy -c 'Print :ClapboardDeviceCount' \
        "$DRIVER_BUNDLE/Contents/Info.plist")"
    echo "==> bundling ClapboardDriver $DRIVER_VERSION ($DRIVER_BUS_COUNT buses)"
    cp "$DRIVER_PKG" "$APP_DIR/Contents/Resources/ClapboardDriver.pkg"

    UNINSTALLER_ENTRY=""
    if [[ -f "$DRIVER_UNINSTALLER_PKG" ]]; then
        cp "$DRIVER_UNINSTALLER_PKG" \
            "$APP_DIR/Contents/Resources/ClapboardDriverUninstaller.pkg"
        UNINSTALLER_ENTRY=$'\t<key>uninstallerPkgName</key>\n\t<string>ClapboardDriverUninstaller.pkg</string>'
    else
        echo "    (no uninstaller package; the assistant will not offer Uninstall)"
    fi

    # Read by ClapboardCore's DriverInstallation.bundledInstaller().
    cat > "$APP_DIR/Contents/Resources/ClapboardDriverInstaller.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>pkgName</key>
	<string>ClapboardDriver.pkg</string>
$UNINSTALLER_ENTRY
	<key>driverVersion</key>
	<string>$DRIVER_VERSION</string>
	<key>driverShortVersion</key>
	<string>$DRIVER_SHORT_VERSION</string>
	<key>busCount</key>
	<integer>$DRIVER_BUS_COUNT</integer>
</dict>
</plist>
PLIST
    plutil -lint "$APP_DIR/Contents/Resources/ClapboardDriverInstaller.plist"
else
    echo "==> no driver package to bundle; the app will report installerUnavailable"
fi

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
