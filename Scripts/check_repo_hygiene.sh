#!/usr/bin/env bash
# Scans tracked (and would-be-tracked) files for things that should never
# ship in a public repo: developer machine home paths, personal email
# addresses, and device UIDs that only make sense on the machine that
# captured them.
#
# This script only reports; it never edits the files it flags. Fix hits in
# the branch that owns the offending file.
#
# Usage: ./Scripts/check_repo_hygiene.sh
# Exit status: 0 when clean, 1 when it found something.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# This script itself, deliberately: its own patterns and examples below would
# otherwise flag itself.
SELF="Scripts/check_repo_hygiene.sh"

# Files that would be tracked if `git add -A` were run right now — i.e.
# respects .gitignore, and also catches new files before they're staged.
mapfile -t FILES < <(git ls-files --cached --others --exclude-standard -- . ":!:$SELF")

violations=0

report() {
    local rule="$1" file="$2" line="$3" text="$4"
    echo "[$rule] $file:$line: $text"
    violations=$((violations + 1))
}

# All three loops below read `grep -n` output ("lineno:match") with plain
# parameter expansion instead of `IFS=: read`, because the matched text can
# itself contain colons (a device UID, a path) and splitting on `:` with
# `read` is not reliable once that happens.

# --- 1. Developer machine home paths --------------------------------------
# /Users/example is the documented placeholder and is allowed everywhere.
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lineno="${line%%:*}"
        text="${line#*:}"
        [[ "$text" == *"/Users/example"* ]] && continue
        report "home-path" "$f" "$lineno" "$text"
    done < <(grep -n "/Users/" "$f" 2>/dev/null)
done

# --- 2. Personal email addresses -------------------------------------------
# Allowed: noreply@anthropic.com (agent co-author trailer) and any
# *@users.noreply.github.com address (GitHub's own privacy-preserving email).
#
# Resources/ThirdPartyLicenses/ is exempt: those files are upstream license
# texts copied verbatim (Sparkle's, for one, carries the orlp/ed25519 author's
# copyright line). Editing an author out of a copyright notice to satisfy a
# lint rule is the one fix that is worse than the hit.
EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    case "$f" in
        Resources/ThirdPartyLicenses/*) continue ;;
    esac
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lineno="${line%%:*}"
        match="${line#*:}"
        [[ "$match" == "noreply@anthropic.com" ]] && continue
        [[ "$match" == *"@users.noreply.github.com" ]] && continue
        report "email" "$f" "$lineno" "$match"
    done < <(grep -nEo "$EMAIL_RE" "$f" 2>/dev/null)
done

# --- 3. Hard-coded machine-specific device UIDs -----------------------------
# Core Audio UIDs like "AppleUSBAudioEngine:DJI:Mic:1" or
# "com.rogueamoeba.Loopback:1" only make sense on the machine that captured
# them. They're fine as illustrative examples in docs and test fixtures;
# they should never appear in production Sources/ code or scripts.
UID_RE='AppleUSBAudioEngine:|AppleHDAEngine:|BuiltIn(Speaker|Microphone)Device:|com\.rogueamoeba\.[A-Za-z]+:|com\.apple\.audio\.[A-Za-z]+:|BlackHole[0-9A-Za-z]*:|com\.kulakowski\.|com\.izotope\.'
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    case "$f" in
        docs/*|Tests/*|*.md) continue ;;
    esac
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lineno="${line%%:*}"
        match="${line#*:}"
        report "device-uid" "$f" "$lineno" "$match"
    done < <(grep -nEo "$UID_RE" "$f" 2>/dev/null)
done

echo "---"
if [[ "$violations" -eq 0 ]]; then
    echo "check_repo_hygiene: clean (0 hits, $(printf '%s\n' "${FILES[@]}" | wc -l | tr -d ' ') files scanned)"
    exit 0
else
    echo "check_repo_hygiene: $violations hit(s) — see above. This script only reports; fix hits in the branch that owns the file."
    exit 1
fi
