#!/usr/bin/env bash
# Build the Clapboard virtual audio device driver.
# Usage: ./Scripts/build_driver.sh [debug|release] [--harness] [--harness-asan]
# Output: .build/ClapboardDriver.driver
#
# The driver is a Core Audio AudioServerPlugIn — a plain CFPlugIn bundle that
# coreaudiod dlopen()s out of /Library/Audio/Plug-Ins/HAL. It is pure C and
# links only CoreAudio and CoreFoundation, so it is built here with clang
# directly rather than through SwiftPM.
#
# Signing is ad-hoc, which is all coreaudiod asks for on the machine that
# built it. Shipping the driver to anyone else needs a Developer ID
# Application certificate plus notarisation — see Driver/README.md.
#
#   --harness       build Driver/Harness/harness.c and run it against the
#                   freshly built bundle. No coreaudiod, no install, no sudo.
#   --harness-asan  same, but against a separate copy of the driver built with
#                   -fsanitize=address,undefined.
set -euo pipefail

CONFIG="release"
RUN_HARNESS=0
RUN_HARNESS_ASAN=0

for arg in "$@"; do
    case "$arg" in
        debug|release)  CONFIG="$arg" ;;
        --harness)      RUN_HARNESS=1 ;;
        --harness-asan) RUN_HARNESS=1; RUN_HARNESS_ASAN=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [debug|release] [--harness] [--harness-asan]" >&2
            exit 2
            ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build"
BUNDLE="$BUILD_DIR/ClapboardDriver.driver"
SOURCES=("$ROOT"/Driver/Sources/*.c)
FRAMEWORKS=(-framework CoreAudio -framework CoreFoundation)
WARNINGS=(-Wall -Wextra -Werror)

if [[ "$CONFIG" == "debug" ]]; then
    OPT=(-O0 -g)
else
    OPT=(-O2)
fi

# Universal by default so the bundle keeps working if coreaudiod is ever run
# under Rosetta. Falls back to the host architecture when the toolchain has no
# x86_64 slice.
ARCHS=(-arch arm64 -arch x86_64)
ARCH_PROBE="$(mktemp -t clapboard-arch-probe).c"
printf 'int main(void){return 0;}\n' > "$ARCH_PROBE"
if ! clang -x c "$ARCH_PROBE" -arch arm64 -arch x86_64 -o "$ARCH_PROBE.out" >/dev/null 2>&1; then
    echo "==> x86_64 slice unavailable in this toolchain; building for $(uname -m) only"
    ARCHS=(-arch "$(uname -m)")
fi
rm -f "$ARCH_PROBE" "$ARCH_PROBE.out"

echo "==> building ClapboardDriver ($CONFIG)"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

clang -bundle \
    -std=c11 \
    "${WARNINGS[@]}" \
    "${OPT[@]}" \
    -fPIC \
    "${ARCHS[@]}" \
    -mmacosx-version-min=12.0 \
    "${FRAMEWORKS[@]}" \
    "${SOURCES[@]}" \
    -o "$BUNDLE/Contents/MacOS/ClapboardDriver"

# A debug build makes clang run dsymutil, which drops a .dSYM bundle next to
# the binary. It must not end up inside the .driver bundle: codesign would
# seal it and the installer payload would carry it.
rm -rf "$BUNDLE/Contents/MacOS/"*.dSYM

cp "$ROOT/Driver/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'BNDL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> plutil -lint"
plutil -lint "$BUNDLE/Contents/Info.plist"

echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLE"

echo "==> bundle"
find "$BUNDLE" -print | sed "s|^$BUILD_DIR/||"

echo "==> architectures"
lipo -archs "$BUNDLE/Contents/MacOS/ClapboardDriver"

echo "==> signature"
codesign -dv "$BUNDLE" 2>&1 | sed 's/^/    /'

if [[ "$RUN_HARNESS" -eq 1 ]]; then
    HARNESS_BIN="$BUILD_DIR/clapboard-driver-harness"
    HARNESS_TARGET="$BUNDLE/Contents/MacOS/ClapboardDriver"
    HARNESS_SAN=()

    if [[ "$RUN_HARNESS_ASAN" -eq 1 ]]; then
        # The harness dlopen()s the driver, so the driver needs the same
        # instrumentation to be checked properly. Build a second, sanitized
        # copy next to the bundle and point the harness at that.
        echo "==> building a sanitized copy of the driver"
        HARNESS_SAN=(-fsanitize=address,undefined -fno-omit-frame-pointer -g)
        HARNESS_TARGET="$BUILD_DIR/ClapboardDriver-asan"
        clang -bundle \
            -std=c11 \
            "${WARNINGS[@]}" \
            -O1 \
            -fPIC \
            -arch "$(uname -m)" \
            -mmacosx-version-min=12.0 \
            "${HARNESS_SAN[@]}" \
            "${FRAMEWORKS[@]}" \
            "${SOURCES[@]}" \
            -o "$HARNESS_TARGET"
        HARNESS_BIN="$BUILD_DIR/clapboard-driver-harness-asan"
    fi

    echo "==> building the harness"
    clang \
        -std=c11 \
        "${WARNINGS[@]}" \
        "${OPT[@]}" \
        -arch "$(uname -m)" \
        -mmacosx-version-min=12.0 \
        "${HARNESS_SAN[@]}" \
        "${FRAMEWORKS[@]}" \
        "$ROOT/Driver/Harness/harness.c" \
        -o "$HARNESS_BIN"

    echo "==> running the harness"
    if [[ "$RUN_HARNESS_ASAN" -eq 1 ]]; then
        ASAN_OPTIONS="detect_leaks=0" \
        UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1" \
            "$HARNESS_BIN" "$HARNESS_TARGET"
    else
        "$HARNESS_BIN" "$HARNESS_TARGET"
    fi
fi

echo "==> done: $BUNDLE"
echo "Install it with: ./Scripts/install_driver.sh"
