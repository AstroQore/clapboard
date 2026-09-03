#!/usr/bin/env bash
# Add one already-published release archive to a reconstructed Sparkle appcast.
#
# The release-published workflow calls this once for the newest published Main
# archive and once for the newest published Dev archive. Existing items in the
# supplied base appcast are preserved and re-checked afterwards, so the final
# feed always carries both channel heads and GitHub Actions concurrency never
# has to behave like an event queue: a run that replaces a pending run still
# rebuilds the complete feed from what is published.
#
# Unlike Scripts/release_app.sh this never builds, signs or replaces the app —
# it works from the reviewed archive a maintainer already published.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_KEY_ACCOUNT="${CLAPBOARD_SPARKLE_KEY_ACCOUNT:-astroqore-clapboard}"
REPO_URL="https://github.com/AstroQore/clapboard"
RELEASE_CHANNEL=""
RELEASE_TAG=""
ARCHIVE=""
BASE_APPCAST=""
OUTPUT=""

usage() {
    printf '%s\n' \
        "Add a published release archive to a reconstructed Sparkle appcast." \
        "" \
        "Usage: ./Scripts/generate_update_feed.sh \\" \
        "  --channel main|dev --tag <tag> --archive <zip> --output <appcast.xml> \\" \
        "  [--base-appcast <appcast.xml>]"
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
        --tag)
            if [[ $# -lt 2 ]]; then
                echo "--tag requires a release tag" >&2
                exit 1
            fi
            RELEASE_TAG="$2"
            shift 2
            ;;
        --archive)
            if [[ $# -lt 2 ]]; then
                echo "--archive requires a ZIP path" >&2
                exit 1
            fi
            ARCHIVE="$2"
            shift 2
            ;;
        --base-appcast)
            if [[ $# -lt 2 ]]; then
                echo "--base-appcast requires an appcast path" >&2
                exit 1
            fi
            BASE_APPCAST="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 ]]; then
                echo "--output requires an appcast path" >&2
                exit 1
            fi
            OUTPUT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown or incomplete option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "$RELEASE_CHANNEL" != "main" && "$RELEASE_CHANNEL" != "dev" ]]; then
    echo "--channel must be main or dev" >&2
    exit 1
fi
if [[ -z "$RELEASE_TAG" || -z "$ARCHIVE" || -z "$OUTPUT" ]]; then
    echo "--tag, --archive, and --output are required" >&2
    exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
    echo "Release archive not found at $ARCHIVE" >&2
    exit 1
fi
if [[ -n "$BASE_APPCAST" && ! -f "$BASE_APPCAST" ]]; then
    echo "Base appcast not found at $BASE_APPCAST" >&2
    exit 1
fi

GENERATE_APPCAST="$(
    find "$ROOT/.build/artifacts/sparkle" \
        -type f \
        -path '*/Sparkle/bin/generate_appcast' \
        -print \
        -quit
)"
if [[ -z "$GENERATE_APPCAST" || ! -x "$GENERATE_APPCAST" ]]; then
    echo "Sparkle generate_appcast tool not found after SwiftPM resolution." >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clapboard-update-feed.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_ARCHIVE="$STAGING_DIR/$(basename "$ARCHIVE")"
cp "$ARCHIVE" "$STAGED_ARCHIVE"

# The version pair comes out of the archive itself, not out of this checkout:
# the feed describes what was published, and `main` may already be ahead.
EXTRACTED_DIR="$STAGING_DIR/extracted"
mkdir -p "$EXTRACTED_DIR"
ditto -x -k "$STAGED_ARCHIVE" "$EXTRACTED_DIR"
ARCHIVE_PLIST="$(
    find "$EXTRACTED_DIR" \
        -mindepth 3 \
        -maxdepth 3 \
        -type f \
        -path '*.app/Contents/Info.plist' \
        -print \
        -quit
)"
if [[ -z "$ARCHIVE_PLIST" ]]; then
    echo "Release archive does not contain an app Info.plist." >&2
    exit 1
fi
VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$ARCHIVE_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$ARCHIVE_PLIST")"
if [[ "$RELEASE_CHANNEL" == "main" ]]; then
    EXPECTED_TAG="v$VERSION"
else
    EXPECTED_TAG="v$VERSION-dev.$BUILD_NUMBER"
fi
if [[ "$RELEASE_TAG" != "$EXPECTED_TAG" ]]; then
    echo "Release tag $RELEASE_TAG does not match archived build $EXPECTED_TAG" >&2
    exit 1
fi

if [[ -n "$BASE_APPCAST" ]]; then
    cp "$BASE_APPCAST" "$STAGING_DIR/appcast.xml"
fi

RELEASE_NOTES="$STAGING_DIR/$(basename "${STAGED_ARCHIVE%.zip}").md"
printf '# Clapboard %s (%s)\n\nSee the [full release notes](%s/releases/tag/%s).\n' \
    "$VERSION" "$RELEASE_CHANNEL" "$REPO_URL" "$RELEASE_TAG" > "$RELEASE_NOTES"

APPCAST_ARGS=(
    --download-url-prefix "$REPO_URL/releases/download/$RELEASE_TAG/"
    --link "$REPO_URL/releases/tag/$RELEASE_TAG"
    --embed-release-notes
    --maximum-versions 0
    -o "$STAGING_DIR/appcast.xml"
)
if [[ "$RELEASE_CHANNEL" == "dev" ]]; then
    APPCAST_ARGS+=(--channel dev)
fi

if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" \
        | "$GENERATE_APPCAST" --ed-key-file - "${APPCAST_ARGS[@]}" "$STAGING_DIR"
elif [[ "${CI:-}" == "true" ]]; then
    echo "SPARKLE_ED_PRIVATE_KEY is required in CI." >&2
    exit 1
else
    "$GENERATE_APPCAST" \
        --account "$SPARKLE_KEY_ACCOUNT" \
        "${APPCAST_ARGS[@]}" \
        "$STAGING_DIR"
fi

APPCAST="$STAGING_DIR/appcast.xml"
if ! grep -q 'sparkle:edSignature=' "$APPCAST"; then
    echo "Generated shared appcast does not contain an EdDSA archive signature." >&2
    exit 1
fi
if ! grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST"; then
    echo "Generated shared appcast does not contain build $BUILD_NUMBER." >&2
    exit 1
fi
if [[ "$RELEASE_CHANNEL" == "dev" ]] \
    && ! grep -q '<sparkle:channel>dev</sparkle:channel>' "$APPCAST"; then
    echo "Generated shared appcast does not mark build $BUILD_NUMBER as dev." >&2
    exit 1
fi
# Losing the other channel's head would silently strand every user on it, so
# every build number that was in the base has to still be in the result.
if [[ -n "$BASE_APPCAST" ]]; then
    while IFS= read -r base_version; do
        if ! grep -q "<sparkle:version>$base_version</sparkle:version>" "$APPCAST"; then
            echo "Generated shared appcast dropped existing build $base_version." >&2
            exit 1
        fi
    done < <(
        sed -n 's|.*<sparkle:version>\([^<]*\)</sparkle:version>.*|\1|p' \
            "$BASE_APPCAST"
    )
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$APPCAST" "$OUTPUT"
echo "Shared Sparkle appcast ready: $OUTPUT"
