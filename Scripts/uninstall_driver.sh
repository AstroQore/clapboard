#!/usr/bin/env bash
# Remove the Clapboard virtual audio device driver.
# Usage: ./Scripts/uninstall_driver.sh [--open] [--run]
#
# Mirrors install_driver.sh:
#
#   (no flag)  report what is installed and print the commands. Nothing is
#              changed.
#   --open     open .build/ClapboardDriverUninstaller.pkg in Installer.app —
#              a payload-free package whose postinstall script does the
#              removal with the password Installer.app already asked for.
#   --run      the manual fallback: sudo rm / pkgutil --forget / restart
#              coreaudiod, for a human sitting at a terminal.
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
PKG="$BUILD_DIR/ClapboardDriverUninstaller.pkg"
HAL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALLED="$HAL_DIR/ClapboardDriver.driver"
PKG_ID="com.astroqore.ClapboardDriver"

echo "==> checking what is installed"
if [[ -d "$INSTALLED" ]]; then
    echo "    $INSTALLED is present"
    echo "    version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
        "$INSTALLED/Contents/Info.plist" 2>/dev/null || echo unknown)"
else
    echo "    $INSTALLED is not installed"
fi
if pkgutil --pkg-info "$PKG_ID" >/dev/null 2>&1; then
    echo "    receipt $PKG_ID is present"
else
    echo "    no receipt for $PKG_ID"
fi

case "$MODE" in
open)
    if [[ ! -f "$PKG" ]]; then
        echo "No uninstaller package at $PKG" >&2
        echo "Build it first: ./Scripts/build_driver_uninstaller_pkg.sh" >&2
        exit 1
    fi
    echo "==> opening $PKG"
    open "$PKG"
    ;;

run)
    echo "==> removing with sudo (manual fallback)"
    sudo rm -rf "$INSTALLED"
    sudo pkgutil --forget "$PKG_ID" >/dev/null 2>&1 || true
    sudo pkgutil --forget "$PKG_ID.uninstaller" >/dev/null 2>&1 || true
    if ! sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod; then
        sudo killall coreaudiod
    fi
    echo "==> removed"
    ;;

print)
    echo
    echo "Recommended — run the uninstaller package:"
    if [[ -f "$PKG" ]]; then
        echo "    open \"$PKG\""
        echo "  or: ./Scripts/uninstall_driver.sh --open"
    else
        echo "    ./Scripts/build_driver_uninstaller_pkg.sh   # builds $PKG"
        echo "    open \"$PKG\""
    fi
    echo
    echo "Fallback — do it by hand (./Scripts/uninstall_driver.sh --run does exactly this):"
    echo "    sudo rm -rf $INSTALLED"
    echo "    sudo pkgutil --forget $PKG_ID"
    echo "    sudo launchctl kickstart -kp system/com.apple.audio.coreaudiod"
    echo "    # or, equivalently:  sudo killall coreaudiod"
    echo
    echo "Verify afterwards:"
    echo "    ls $HAL_DIR"
    echo "    system_profiler SPAudioDataType | grep \"Clapboard Bus\"   # should print nothing"
    ;;
esac
