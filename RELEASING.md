# Releasing Clapboard

Clapboard has not cut a release yet. This document describes the intended
flow so the first tag doesn't have to invent it from scratch.

A release is built from a version tag by CI and lands as a **draft** GitHub
Release. It reaches nobody until a maintainer opens that draft, checks the
asset, and publishes it — publishing is a manual, deliberate step by design.

There is no update channel and no in-app updater today (see "Not yet: an
update channel" below): a release is a signed `.app` a user downloads and
replaces by hand.

## What the workflow does

`.github/workflows/release.yml` runs on push of a `v*` tag, or on
`workflow_dispatch` for re-running an existing tag. It:

1. checks out the tagged source and prints the toolchain (`sw_vers`,
   `xcode-select -p`, `swift --version`);
2. runs `swift test`;
3. builds and ad-hoc signs the release app with
   `./Scripts/build_app.sh release` — the same script and the same signing
   behavior described in `AGENTS.md` and `docs/PERMISSIONS.md`, nothing
   release-specific;
4. verifies the entitlements are still an empty `<dict/>`
   (`codesign -d --entitlements -`), the same check `CONTRIBUTING.md` asks of
   every PR;
5. zips the app with `ditto -c -k --keepParent` (this preserves the bundle
   structure correctly, unlike a plain `zip -r`) and computes a SHA-256
   checksum of the archive;
6. creates or updates a **draft** release for the tag with
   `gh release create --draft --generate-notes --verify-tag`, attaching the
   zip and the checksum file.

`--verify-tag` makes the job fail rather than release from the wrong commit
if the tag was force-moved after the workflow started. `--generate-notes`
seeds the draft from merged PRs since the previous tag; edit it by hand
before publishing — `CHANGELOG.md`'s `Unreleased` section is the better
source of truth for what actually changed.

No repository secrets are required. The workflow needs only the default
`GITHUB_TOKEN` (already scoped for release creation) and does not import a
signing certificate.

## Cutting a release

1. Update `CFBundleShortVersionString` (and, if you're tracking build
   numbers deliberately, `CFBundleVersion`) in `Resources/Info.plist`.
2. Move `CHANGELOG.md`'s `Unreleased` section under a new `## [x.y.z] -
   YYYY-MM-DD` heading, and start a fresh empty `Unreleased`.
3. Merge that version bump to `main` through a PR.
4. Tag the merged commit and push the tag:

   ```sh
   git tag -a v0.1.0 -m "Clapboard 0.1.0"
   git push origin v0.1.0
   ```

   The tag must be exactly `v` plus `CFBundleShortVersionString`.
5. Watch the `release.yml` run, then open the draft release it created,
   review the notes and the attached `.zip`/`.sha256`, and publish it.

## Signing status today

Release builds are **ad-hoc signed**, exactly like a local
`./Scripts/build_app.sh release` — see `AGENTS.md` and `docs/PERMISSIONS.md`
for what that means for the Microphone permission (it does not survive a
rebuild unless `CLAPBOARD_CODESIGN_IDENTITY` is set to a stable identity).
Released builds are **not notarized**. Gatekeeper will require a user to
right-click → Open, or approve the app in System Settings, the first time
they run it.

### Future: Developer ID signing and notarization

Once the project has an Apple Developer Program membership, the release
workflow can be extended to import a Developer ID Application certificate,
sign with the hardened runtime, and notarize/staple the build — the same
shape `vibe-bar`'s and `auspex`'s `release.yml` already implement, gated on
optional secrets (`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) so an unsigned build keeps
working if they're absent. Not implemented yet; tracked here rather than
silently assumed.

## Not yet: an update channel

Clapboard has no Sparkle integration and no in-app "check for updates". Every
release today is a manual download-and-replace. An update channel (most
likely Sparkle, matching the sibling AstroQore apps) is future work, not
committed to a timeline — this section exists so a reader doesn't wonder
whether it was forgotten.
