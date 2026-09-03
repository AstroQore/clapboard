#!/usr/bin/env bash
# Produce a verified GitHub Release asset for the version in Info.plist,
# together with the Sparkle appcast item that advertises it.
#
# Usage:
#   ./Scripts/release_app.sh [--channel main|dev] [--base-appcast <path>] [tag]
#
# Default output:
#   .build/release/Clapboard-<version>[-dev.<build>]-macOS-<arch>.zip
#   .build/release/Clapboard-<version>[-dev.<build>]-macOS-<arch>.zip.sha256
#   .build/release/appcast.xml
#
# Signing: ad-hoc, always. Clapboard has no Apple Developer Program membership,
# so a release is neither Developer ID signed nor notarized — see RELEASING.md
# for what that costs the person downloading it. The EdDSA signature in the
# appcast is a separate mechanism and is NOT optional: it is the only thing
# that makes an in-app update trustworthy here.
#
# The private key is never read from the repository. Either export
# SPARKLE_ED_PRIVATE_KEY (what CI does) or let Sparkle read the key from the
# login Keychain account named by CLAPBOARD_SPARKLE_KEY_ACCOUNT (what a
# maintainer's Mac does).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
APP_DIR="$ROOT/.build/Clapboard.app"
DIST_DIR="$ROOT/.build/release"
SPARKLE_KEY_ACCOUNT="${CLAPBOARD_SPARKLE_KEY_ACCOUNT:-astroqore-clapboard}"
RELEASE_CHANNEL="${CLAPBOARD_RELEASE_CHANNEL:-main}"
BASE_APPCAST="${CLAPBOARD_BASE_APPCAST:-}"
REPO_URL="https://github.com/AstroQore/clapboard"
POSITIONAL_TAG=""

usage() {
    printf '%s\n' \
        "Produce a verified GitHub Release asset for the version in Info.plist." \
        "" \
        "Usage: ./Scripts/release_app.sh [--channel main|dev] [--base-appcast <path>] [tag]" \
        "" \
        "Main tag: v<version>" \
        "Dev tag:  v<version>-dev.<CFBundleVersion>" \
        "" \
        "See RELEASING.md for the key pair, the GitHub secret, and publishing."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            if [[ $# -lt 2 ]]; then
                echo "--channel requires main or dev" >&2
                exit 1
            fi
            RELEASE_CHANNEL="$2"
            shift 2
            ;;
        --base-appcast)
            if [[ $# -lt 2 ]]; then
                echo "--base-appcast requires a file path" >&2
                exit 1
            fi
            BASE_APPCAST="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "$POSITIONAL_TAG" ]]; then
                echo "Only one release tag may be provided." >&2
                exit 1
            fi
            POSITIONAL_TAG="$1"
            shift
            ;;
    esac
done

if [[ "$RELEASE_CHANNEL" != "main" && "$RELEASE_CHANNEL" != "dev" ]]; then
    echo "Release channel must be main or dev, got: $RELEASE_CHANNEL" >&2
    exit 1
fi

if [[ ! -f "$PLIST" ]]; then
    echo "Info.plist not found at $PLIST" >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$PLIST")"
RELEASE_TAG="${POSITIONAL_TAG:-${CLAPBOARD_RELEASE_TAG:-}}"
if [[ -z "$RELEASE_TAG" ]]; then
    if [[ "$RELEASE_CHANNEL" == "dev" ]]; then
        RELEASE_TAG="v$VERSION-dev.$BUILD_NUMBER"
    else
        RELEASE_TAG="v$VERSION"
    fi
fi

# The tag is what users see and what Sparkle's download URLs are built from,
# so a tag that disagrees with the bundle is caught here rather than after an
# asset has been uploaded under the wrong name.
if [[ "$RELEASE_CHANNEL" == "main" ]]; then
    if [[ "$RELEASE_TAG" != "v$VERSION" ]]; then
        echo "Main release tag $RELEASE_TAG does not match Info.plist version v$VERSION" >&2
        echo "Bump CFBundleShortVersionString before releasing this tag." >&2
        exit 1
    fi
else
    EXPECTED_DEV_TAG="v$VERSION-dev.$BUILD_NUMBER"
    if [[ "$RELEASE_TAG" != "$EXPECTED_DEV_TAG" ]]; then
        echo "Dev release tag $RELEASE_TAG does not match $EXPECTED_DEV_TAG" >&2
        echo "Dev tags include CFBundleVersion so every preview has a unique build." >&2
        exit 1
    fi
fi

# Sparkle orders updates by CFBundleVersion, not by the tag, so a build number
# left at its predecessor's value would publish an update nobody is offered.
if ! [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "CFBundleVersion must be a plain integer, got: $BUILD_NUMBER" >&2
    exit 1
fi

if [[ "${CLAPBOARD_SKIP_TESTS:-0}" != "1" ]]; then
    echo "==> running the test suite"
    (cd "$ROOT" && swift test)
fi

echo "==> building Clapboard $VERSION ($BUILD_NUMBER)"
(cd "$ROOT" && ./Scripts/build_app.sh release)

echo "==> verifying bundle signature"
codesign --verify --deep --strict "$APP_DIR"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP_DIR" 2>&1)"
if grep -q 'com.apple.security.app-sandbox' <<<"$ENTITLEMENTS"; then
    echo "Refusing to release a sandboxed Clapboard bundle." >&2
    exit 1
fi

echo "==> verifying bundled Sparkle"
if [[ ! -x "$APP_DIR/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
    echo "Refusing to release an app with no embedded Sparkle framework." >&2
    exit 1
fi
if [[ ! -f "$APP_DIR/Contents/Resources/ThirdPartyLicenses/Sparkle.txt" ]]; then
    echo "Refusing to release a bundle without Sparkle's license." >&2
    exit 1
fi
PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw -o - "$APP_DIR/Contents/Info.plist")"
if [[ "$PUBLIC_KEY" == REPLACE_ME_* || -z "$PUBLIC_KEY" ]]; then
    echo "Resources/Info.plist still carries the SUPublicEDKey placeholder." >&2
    echo "Generate the key pair and paste the public key in; see RELEASING.md." >&2
    exit 1
fi

ARCH_LIST="$(lipo -archs "$APP_DIR/Contents/MacOS/Clapboard")"
if [[ " $ARCH_LIST " == *" arm64 "* && " $ARCH_LIST " == *" x86_64 "* ]]; then
    ARCH_LABEL="universal"
elif [[ " $ARCH_LIST " == *" arm64 "* ]]; then
    ARCH_LABEL="arm64"
elif [[ " $ARCH_LIST " == *" x86_64 "* ]]; then
    ARCH_LABEL="x86_64"
else
    ARCH_LABEL="$(tr ' ' '-' <<<"$ARCH_LIST")"
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
# Seeding from the live feed is what keeps the other channel's head alive: a
# Main release must not drop the current Dev item, or vice versa. With no base
# appcast this run seeds a brand-new feed, which is only correct for the very
# first release.
if [[ -n "$BASE_APPCAST" ]]; then
    if [[ ! -f "$BASE_APPCAST" ]]; then
        echo "Base appcast not found at $BASE_APPCAST" >&2
        exit 1
    fi
    cp "$BASE_APPCAST" "$DIST_DIR/appcast.xml"
fi

VERSION_LABEL="$VERSION"
if [[ "$RELEASE_CHANNEL" == "dev" ]]; then
    VERSION_LABEL="$VERSION-dev.$BUILD_NUMBER"
fi
ARCHIVE="$DIST_DIR/Clapboard-$VERSION_LABEL-macOS-$ARCH_LABEL.zip"

# ditto, not `zip -r`: it preserves the bundle's symlinks, permissions and
# extended attributes, which is what Sparkle unpacks and what codesign
# re-validates on the other end.
rm -f "$ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE"

echo "==> ad-hoc release asset (Gatekeeper will require manual approval)"

GENERATE_APPCAST="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type f \
        -path '*/Sparkle/bin/generate_appcast' \
        -print \
        -quit
)"
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle generate_appcast tool not found after SwiftPM build." >&2
    exit 1
fi

# generate_appcast performs the same EdDSA signing that Sparkle's standalone
# sign_update does, and additionally writes the <item> that carries the
# signature, the length, the version pair and the channel — so there is one
# signing path rather than a signature and a hand-written XML element that can
# disagree with each other.
RELEASE_NOTES="$DIST_DIR/$(basename "${ARCHIVE%.zip}").md"
printf '# Clapboard %s (%s)\n\nSee the [full release notes](%s/releases/tag/%s).\n' \
    "$VERSION" "$RELEASE_CHANNEL" "$REPO_URL" "$RELEASE_TAG" > "$RELEASE_NOTES"

echo "==> generating signed Sparkle appcast ($RELEASE_CHANNEL channel)"
APPCAST_ARGS=(
    --download-url-prefix "$REPO_URL/releases/download/$RELEASE_TAG/"
    --link "$REPO_URL/releases/tag/$RELEASE_TAG"
    --embed-release-notes
    --maximum-versions 0
    -o "$DIST_DIR/appcast.xml"
)
# Main is Sparkle's untagged default channel, so it takes no --channel at all.
if [[ "$RELEASE_CHANNEL" == "dev" ]]; then
    APPCAST_ARGS+=(--channel dev)
fi
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    # Over stdin: never an argv the process list can show, never a file.
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
        | "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$DIST_DIR"
elif [[ "${CI:-}" == "true" ]]; then
    echo "SPARKLE_ED_PRIVATE_KEY is required in CI." >&2
    exit 1
else
    "$GENERATE_APPCAST" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        "${APPCAST_ARGS[@]}" \
        "$DIST_DIR"
fi
rm -f "$RELEASE_NOTES"

APPCAST="$DIST_DIR/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "Generated appcast does not contain an EdDSA archive signature." >&2
    exit 1
fi
if ! grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
    echo "Generated appcast does not contain build $BUILD_NUMBER." >&2
    exit 1
fi
if [[ "$RELEASE_CHANNEL" == "dev" ]] \
    && ! grep -q '<sparkle:channel>dev</sparkle:channel>' "$APPCAST"; then
    echo "Generated appcast does not mark build $BUILD_NUMBER as dev." >&2
    exit 1
fi

CHECKSUM="$ARCHIVE.sha256"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$CHECKSUM")")

echo "==> release assets ready"
echo "$ARCHIVE"
echo "$CHECKSUM"
echo "$APPCAST"
