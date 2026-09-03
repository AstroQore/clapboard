#!/usr/bin/env bash
# Install the Clapboard virtual audio device driver.
# Usage: ./Scripts/install_driver.sh [--open] [--run]
#
# The supported route is the installer package: it asks for the administrator
# password itself, sets root:wheel ownership and restarts coreaudiod. This
# script validates what has been built and then either prints what to run or,
# with a flag, runs it.
#
#   (no flag)  validate, then print the commands. Nothing is changed.
#   --open     open .build/ClapboardDriver.pkg in Installer.app.
#   --run      the manual fallback: sudo cp / chown / restart coreaudiod,
#              for a human sitting at a terminal who would rather not use the
#              package. You will be asked for your password.
set -euo pipefail

MODE="print"
for arg in "$@"; do
    case "$arg" in
        --open) MODE="open" ;;
        --run)  MODE="run" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--open] [--run]" >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build"
BUNDLE="$BUILD_DIR/ClapboardDriver.driver"
PKG="$BUILD_DIR/ClapboardDriver.pkg"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"

# --- validate what we are about to install -----------------------------------

if [[ ! -d "$BUNDLE" ]]; then
    echo "No driver bundle at $BUNDLE" >&2
    echo "Build it first: ./Scripts/build_driver.sh release" >&2
    exit 1
fi

echo "==> validating $BUNDLE"
for required in Contents/Info.plist Contents/MacOS/ClapboardDriver; do
    if [[ ! -e "$BUNDLE/$required" ]]; then
        echo "Bundle is missing $required" >&2
        exit 1
    fi
done

plutil -lint "$BUNDLE/Contents/Info.plist"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_ID" != "com.astroqore.ClapboardDriver" ]]; then
    echo "Unexpected bundle identifier: $BUNDLE_ID" >&2
    exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :CFPlugInFactories' \
        "$BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "Info.plist has no CFPlugInFactories; coreaudiod would ignore it" >&2
    exit 1
fi

codesign --verify --strict "$BUNDLE"
echo "    identifier: $BUNDLE_ID"
echo "    version:    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$BUNDLE/Contents/Info.plist")"
echo "    buses:      $(/usr/libexec/PlistBuddy -c 'Print :ClapboardDeviceCount' \
    "$BUNDLE/Contents/Info.plist")"
echo "    archs:      $(lipo -archs "$BUNDLE/Contents/MacOS/ClapboardDriver")"
echo "    signature:  $(codesign -dv "$BUNDLE" 2>&1 | grep -E '^Signature' || echo unknown)"

# --- act ---------------------------------------------------------------------

case "$MODE" in
open)
    if [[ ! -f "$PKG" ]]; then
        echo "No installer package at $PKG" >&2
        echo "Build it first: ./Scripts/build_driver_pkg.sh" >&2
        exit 1
    fi
    echo "==> opening $PKG"
    open "$PKG"
    ;;

run)
    echo "==> installing with sudo (manual fallback)"
    sudo mkdir -p "$HAL_DIR"
    sudo rm -rf "$HAL_DIR/ClapboardDriver.driver"
    sudo cp -R "$BUNDLE" "$HAL_DIR/"
    sudo chown -R root:wheel "$HAL_DIR/ClapboardDriver.driver"
    sudo chmod -R go-w "$HAL_DIR/ClapboardDriver.driver"
    if ! sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod; then
        sudo killall coreaudiod
    fi
    echo "==> installed"
    ;;

print)
    echo
    echo "Recommended — install the package (Installer.app asks for your password):"
    if [[ -f "$PKG" ]]; then
        echo "    open \"$PKG\""
        echo "  or: ./Scripts/install_driver.sh --open"
    else
        echo "    ./Scripts/build_driver_pkg.sh      # builds $PKG"
        echo "    open \"$PKG\""
    fi
    echo
    echo "Fallback — do it by hand (./Scripts/install_driver.sh --run does exactly this):"
    echo "    sudo cp -R \"$BUNDLE\" $HAL_DIR/"
    echo "    sudo chown -R root:wheel $HAL_DIR/ClapboardDriver.driver"
    echo "    sudo chmod -R go-w $HAL_DIR/ClapboardDriver.driver"
    echo "    sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod"
    echo "    # or, equivalently:  sudo killall coreaudiod"
    echo
    echo "Verify afterwards:"
    echo "    .build/Clapboard.app/Contents/MacOS/Clapboard --list-devices | grep \"Clapboard Bus\""
    echo "    system_profiler SPAudioDataType | grep -A2 \"Clapboard Bus\""
    echo "    # or open Audio MIDI Setup and look for Clapboard Bus 1…4"
    echo
    echo "Uninstall with: ./Scripts/uninstall_driver.sh"
    ;;
esac
