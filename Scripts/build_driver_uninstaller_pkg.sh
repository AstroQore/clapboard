#!/usr/bin/env bash
# Build a payload-free installer package that removes the Clapboard driver.
# Usage: ./Scripts/build_driver_uninstaller_pkg.sh
# Output: .build/ClapboardDriverUninstaller.pkg
#
# macOS has no "uninstall" verb for packages, so the conventional answer is a
# second package whose only content is a postinstall script. Double-clicking
# it deletes /Library/Audio/Plug-Ins/HAL/ClapboardDriver.driver, forgets the
# receipts and restarts coreaudiod — with Installer.app asking for the
# administrator password, so no sudo is typed by hand.
#
# Set CLAPBOARD_PKG_IDENTITY to a "Developer ID Installer" identity to sign it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build"
PKG="$BUILD_DIR/ClapboardDriverUninstaller.pkg"
PKG_ID="com.astroqore.ClapboardDriver.uninstaller"
SIGN_IDENTITY="${CLAPBOARD_PKG_IDENTITY:-}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Driver/Info.plist")"
echo "==> packaging the ClapboardDriver uninstaller $VERSION"

mkdir -p "$BUILD_DIR"

PKGBUILD_ARGS=(
    --nopayload
    --identifier "$PKG_ID"
    --version "$VERSION"
    --scripts "$ROOT/Driver/Packaging/uninstall-scripts"
)
if [[ -n "$SIGN_IDENTITY" ]]; then
    PKGBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
fi
rm -f "$PKG"
pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG"

echo "==> expanding the package to check its script"
EXPANDED="$BUILD_DIR/pkg-uninstaller-expanded"
rm -rf "$EXPANDED"
pkgutil --expand "$PKG" "$EXPANDED"
find "$EXPANDED" -maxdepth 2 -print | sed "s|^$BUILD_DIR/||"

FOUND=0
while IFS= read -r script; do
    echo "    bash -n $(basename "$script")"
    bash -n "$script"
    FOUND=1
done < <(find "$EXPANDED" -name 'postinstall')
if [[ "$FOUND" -eq 0 ]]; then
    echo "The uninstaller package has no postinstall script" >&2
    exit 1
fi

echo "==> done"
ls -lh "$PKG"
echo "Run it with: open \"$PKG\""
