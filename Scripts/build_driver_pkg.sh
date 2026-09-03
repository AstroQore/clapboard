#!/usr/bin/env bash
# Wrap .build/ClapboardDriver.driver into a standard macOS installer package.
# Usage: ./Scripts/build_driver_pkg.sh [--component-only]
# Output: .build/ClapboardDriver.pkg          (double-clickable distribution)
#         .build/ClapboardDriver-component.pkg (raw payload, input to the above)
#
# This is the supported way to install the driver: Installer.app asks for the
# administrator password itself, writes the bundle into
# /Library/Audio/Plug-Ins/HAL with root:wheel ownership, and the package's
# postinstall script restarts coreaudiod. Nobody has to type sudo commands.
#
# Signing: unsigned by default, which is fine for a package you built on the
# machine you are installing it on. To hand the package to someone else, set
#
#   CLAPBOARD_PKG_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
#
# and notarise the result (xcrun notarytool submit … --wait, then
# xcrun stapler staple). See Driver/README.md.
set -euo pipefail

COMPONENT_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --component-only) COMPONENT_ONLY=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--component-only]" >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build"
BUNDLE="$BUILD_DIR/ClapboardDriver.driver"
PKG_ID="com.astroqore.ClapboardDriver"
INSTALL_LOCATION="/Library/Audio/Plug-Ins/HAL"
COMPONENT_PKG="$BUILD_DIR/ClapboardDriver-component.pkg"
PRODUCT_PKG="$BUILD_DIR/ClapboardDriver.pkg"
SIGN_IDENTITY="${CLAPBOARD_PKG_IDENTITY:-}"

if [[ ! -d "$BUNDLE" ]]; then
    echo "==> $BUNDLE not found; building it first"
    "$ROOT/Scripts/build_driver.sh" release
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$BUNDLE/Contents/Info.plist")"
echo "==> packaging ClapboardDriver $VERSION"

# pkgbuild copies whatever is under --root, so stage a clean tree that holds
# nothing but the bundle.
STAGING="$BUILD_DIR/pkgroot"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# ditto rather than cp so resource forks, ACLs and the quarantine flag are
# left behind. macOS still stamps every file with com.apple.provenance, which
# cannot be stripped, so the payload carries one AppleDouble "._" entry per
# file; Installer turns those back into extended attributes rather than
# leaving files behind. The bundle signature lives in the Mach-O and in
# Contents/_CodeSignature, not in xattrs — the verify below proves the staged
# copy is still valid.
ditto --norsrc --noextattr --noacl --noqtn "$BUNDLE" "$STAGING/ClapboardDriver.driver"

if compgen -G "$STAGING/ClapboardDriver.driver/Contents/MacOS/*.dSYM" >/dev/null; then
    echo "The bundle contains a .dSYM; rebuild with ./Scripts/build_driver.sh release" >&2
    exit 1
fi
codesign --verify --strict "$STAGING/ClapboardDriver.driver"

echo "==> pkgbuild"
PKGBUILD_ARGS=(
    --root "$STAGING"
    --install-location "$INSTALL_LOCATION"
    --identifier "$PKG_ID"
    --version "$VERSION"
    --scripts "$ROOT/Driver/Packaging/scripts"
    --ownership recommended
)
if [[ -n "$SIGN_IDENTITY" ]]; then
    PKGBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
fi
rm -f "$COMPONENT_PKG"
pkgbuild "${PKGBUILD_ARGS[@]}" "$COMPONENT_PKG"

if [[ "$COMPONENT_ONLY" -eq 0 ]]; then
    echo "==> productbuild"
    DISTRIBUTION="$BUILD_DIR/clapboard-distribution.xml"
    sed "s/@VERSION@/$VERSION/g" "$ROOT/Driver/Packaging/distribution.xml" > "$DISTRIBUTION"

    PRODUCTBUILD_ARGS=(
        --distribution "$DISTRIBUTION"
        --package-path "$BUILD_DIR"
        --resources "$ROOT/Driver/Packaging/resources"
    )
    if [[ -n "$SIGN_IDENTITY" ]]; then
        PRODUCTBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
    fi
    rm -f "$PRODUCT_PKG"
    productbuild "${PRODUCTBUILD_ARGS[@]}" "$PRODUCT_PKG"
fi

# --- verification, all of it offline -----------------------------------------

echo "==> payload"
pkgutil --payload-files "$COMPONENT_PKG"

echo "==> expanding the package to check its scripts"
EXPANDED="$BUILD_DIR/pkg-expanded"
rm -rf "$EXPANDED"
if [[ "$COMPONENT_ONLY" -eq 0 ]]; then
    pkgutil --expand "$PRODUCT_PKG" "$EXPANDED"
else
    pkgutil --expand "$COMPONENT_PKG" "$EXPANDED"
fi
find "$EXPANDED" -maxdepth 2 -print | sed "s|^$BUILD_DIR/||"

SCRIPT_COUNT=0
while IFS= read -r script; do
    echo "    bash -n $(basename "$(dirname "$script")")/$(basename "$script")"
    bash -n "$script"
    SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
done < <(find "$EXPANDED" -name 'postinstall' -o -name 'preinstall')
if [[ "$SCRIPT_COUNT" -eq 0 ]]; then
    echo "No install scripts found in the package" >&2
    exit 1
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> signature"
    pkgutil --check-signature "${PRODUCT_PKG}"
else
    echo "==> unsigned package (fine locally; see the header for distribution)"
fi

echo "==> done"
if [[ "$COMPONENT_ONLY" -eq 0 ]]; then
    ls -lh "$PRODUCT_PKG"
    echo "Install it with: open \"$PRODUCT_PKG\""
else
    ls -lh "$COMPONENT_PKG"
fi
