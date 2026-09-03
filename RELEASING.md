# Releasing Clapboard

A Clapboard release is built from a version tag by GitHub Actions and lands as
a **draft** GitHub Release. It reaches nobody until a maintainer opens that
draft, checks the assets, and publishes it — publishing is a manual, deliberate
step by design. Publishing is also what feeds the in-app updater: a second
workflow rebuilds the shared Sparkle appcast and commits it to the
machine-managed `updates` branch.

One signed appcast serves two channels:

- **Main** is Sparkle's untagged default channel and carries stable releases.
- **Dev** uses the `dev` Sparkle channel and carries previews. Dev users also
  receive Main releases, because Sparkle always includes the default channel on
  top of whatever extra channels the app allows. There is no Dev-only stream,
  and that is deliberate: a preview user must still get a stable fix.

Users pick their channel in **Clapboard › Update Channel**; the app maps it
onto Sparkle's `allowedChannels` (`Sources/ClapboardApp/AppUpdateController.swift`).

## Before the first release: what only a maintainer can do

Sparkle updates are protected by an EdDSA (ed25519) key pair. The private key
never enters this repository, this document, or any CI log. Until someone does
step 1 and 2 below, `Resources/Info.plist` carries a **placeholder** public key
and the app refuses to start its updater at all — **Clapboard › Check for
Updates…** is replaced by "This build has no Sparkle public key yet."

The full checklist is at the bottom of this file.

## Prepare a version

1. Update both values in `Resources/Info.plist`:
   - `CFBundleShortVersionString` — the user-facing version, for example `0.2.0`.
   - `CFBundleVersion` — a monotonically increasing integer build number.
     **Sparkle orders updates by this**, not by the tag, so it has to go up for
     every release on either channel or the update will not be offered.
2. Move `CHANGELOG.md`'s `Unreleased` section under a new
   `## [x.y.z] - YYYY-MM-DD` heading and start a fresh empty `Unreleased`.
3. Merge that version bump to `main` through a PR.
4. Choose the channel, then create and push the matching tag from the commit
   being released.

For Main:

```sh
git tag -a v0.1.0 -m "Clapboard 0.1.0"
git push origin v0.1.0
```

The Main tag must be exactly `v` plus `CFBundleShortVersionString`.

For Dev, keep the same user-facing version and append `CFBundleVersion`:

```sh
git tag -a v0.1.0-dev.7 -m "Clapboard 0.1.0 Dev build 7"
git push origin v0.1.0-dev.7
```

Here `CFBundleShortVersionString` is `0.1.0` and `CFBundleVersion` is `7`.
Every later release — including the eventual Main promotion of that preview —
must have a higher build number, so Sparkle never sees a downgrade. A
tag/channel mismatch fails before any asset is uploaded.

## What the two workflows do

**`.github/workflows/release.yml`** — triggered by a pushed `v*` tag, or by
`workflow_dispatch` with an explicit tag and channel (for re-running an
existing tag). It runs on GitHub's `macos-26` runner and:

1. checks out the tagged source and prints the toolchain;
2. resolves the channel — `workflow_dispatch` input if given, otherwise `dev`
   for a `v…-dev.N` tag and `main` for anything else;
3. downloads the current shared appcast from the `updates` branch, if there is
   one, so this release's appcast asset still contains the *other* channel's
   head;
4. runs `./Scripts/release_app.sh`, which runs the test suite, builds and
   ad-hoc signs the app, verifies the signature and refuses a sandboxed
   bundle, zips it with `ditto`, writes a `.sha256`, and generates the
   EdDSA-signed appcast item;
5. re-checks the entitlements and runs `./Scripts/check_repo_hygiene.sh`;
6. creates or updates a **draft** release with
   `gh release create --draft --generate-notes --verify-tag`, attaching the
   ZIP, the checksum and `appcast.xml`. A Dev draft is also marked
   `--prerelease --latest=false`.

`--verify-tag` makes the job fail rather than release from the wrong commit if
the tag was force-moved after the run started. `--generate-notes` seeds the
draft from merged PRs; edit it before publishing — `CHANGELOG.md` is the better
source of truth. Re-running for the same tag replaces a draft's assets and
refuses to touch a release that is already published.

**`.github/workflows/publish-update-feed.yml`** — triggered when a release is
**published**. It queries the published releases, picks the newest Main
(`vX.Y.Z`, not a prerelease) and the newest Dev (`vX.Y.Z-dev.N`), downloads
each one's ZIP, and rebuilds the shared feed from those two channel heads with
`Scripts/generate_update_feed.sh` before committing `appcast.xml` to the
`updates` branch.

It reconstructs rather than appends on purpose. Workflow concurrency only
serializes writes to the branch; it is not an event queue. A run that replaces
a pending run still sees every published release and still produces the
complete two-channel feed, so a lost or superseded run cannot silently drop an
entry.

Draft releases are not in the feed. The `updates` branch is workflow-owned —
never edit its `appcast.xml` by hand.

## Release assets, locally

The workflow's entry point is a script you can run yourself:

```sh
./Scripts/release_app.sh --channel main v0.1.0
./Scripts/release_app.sh --channel dev v0.1.0-dev.7
```

It writes architecture-labelled files under `.build/release/`:

```text
Clapboard-0.1.0-macOS-arm64.zip
Clapboard-0.1.0-macOS-arm64.zip.sha256
appcast.xml
```

Pass `--base-appcast <path>` (or set `CLAPBOARD_BASE_APPCAST`) to merge into an
existing shared feed; CI does this automatically from the `updates` branch.
Do not publish a single-release appcast as the shared feed unless it was
generated from that base — it would drop the other channel's head.
`CLAPBOARD_SKIP_TESTS=1` skips the test run for a quick local rehearsal.

`Scripts/generate_update_feed.sh` is the narrower publication-time companion:
it takes one already-published release ZIP, reads the version pair out of the
archive itself, refuses a tag that disagrees with it, adds the item to the base
appcast without pruning anything, and re-checks afterwards that no build number
present in the base has gone missing. It never rebuilds or replaces a release
asset.

## Signing: what a user actually sees

Release builds are **ad-hoc signed** and **not notarized**. Clapboard has no
Apple Developer Program membership, and this is the honest consequence:

- **Gatekeeper blocks the first launch.** A user has to right-click the app and
  choose *Open* (or approve it in System Settings › Privacy & Security) the
  first time. A plain double-click will refuse.
- **Every update re-prompts for the microphone.** An ad-hoc signature's
  designated requirement is the binary's own `cdhash`, so a new build is a new
  identity as far as TCC is concerned, even though the bundle identifier never
  changes. After an in-app update, macOS either asks for microphone access
  again or — if there is a stale denied entry — refuses silently and the engine
  captures digital silence. `docs/PERMISSIONS.md` covers this, including
  `tccutil reset Microphone com.astroqore.Clapboard`.

None of that weakens the *update* path: the EdDSA signature in the appcast is
independent of Apple's signing, and Sparkle verifies it before extracting
anything (`SUVerifyUpdateBeforeExtraction`). An attacker who could replace a
release asset still could not produce a signature the installed app accepts.

Adding Developer ID signing and notarization later is a change to
`Scripts/build_app.sh` and `release.yml` only; the appcast machinery does not
change. Note that Clapboard cannot adopt the *hardened runtime* on the app
itself — library validation would block the third-party AUv2 plug-ins it hosts
in-process — so a notarization setup has to request the
`com.apple.security.cs.disable-library-validation` entitlement. That is a
decision to make deliberately, not a step to copy from a sibling app.

## Sparkle update signing

Generate one key pair, once, on a trusted maintainer Mac:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account astroqore-clapboard
```

It prints the public key and stores the private key in that Mac's login
Keychain. Put the public key in `Resources/Info.plist` as `SUPublicEDKey`,
replacing `REPLACE_ME_WITH_SPARKLE_PUBLIC_ED_KEY`; the public key is safe to
commit, and is *supposed* to be committed — it is what pins the feed to your
key.

For GitHub Actions, export the private key to a temporary
permission-restricted file, paste its contents into the repository Actions
secret `SPARKLE_ED_PRIVATE_KEY`, and delete the file immediately:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account astroqore-clapboard -x ~/sparkle-private-key.txt
# paste the contents into the GitHub secret, then:
rm -P ~/sparkle-private-key.txt
```

Never commit or print the private key, and never paste it into an issue, a PR,
a chat window or an agent session. If it ever leaks: generate a new pair,
update `SUPublicEDKey`, replace the secret, and ship a Main release — existing
installs will only accept updates signed by the key they were built with, so
anyone on an older build has to reinstall by hand.

Both workflows fail before packaging if `SPARKLE_ED_PRIVATE_KEY` is missing.
The secret is exposed to one step, passed to Sparkle over standard input, and
never written to the checkout, a command line, a release asset or the log.
`Scripts/release_app.sh` additionally refuses to release a bundle that still
carries the placeholder public key, and rejects an appcast without an EdDSA
signature or without the expected build number.

Locally, the scripts read the key from the Keychain account named by
`CLAPBOARD_SPARKLE_KEY_ACCOUNT` (default `astroqore-clapboard`) whenever
`SPARKLE_ED_PRIVATE_KEY` is not set.

The feed URL compiled into every build is:

```text
https://raw.githubusercontent.com/AstroQore/clapboard/updates/appcast.xml
```

## Maintainer checklist

Everything above, in order, for the person holding the keys. Steps 1–3 happen
once; 4–7 happen per release.

1. **Generate the key pair** on your own Mac:
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account astroqore-clapboard`
   (build once first — `swift build` — so the tool exists).
2. **Paste the printed public key into `Resources/Info.plist`** as
   `SUPublicEDKey`, replacing `REPLACE_ME_WITH_SPARKLE_PUBLIC_ED_KEY`. Commit
   that; it belongs in the repository.
3. **Store the private key as the repository secret `SPARKLE_ED_PRIVATE_KEY`**
   (GitHub → Settings → Secrets and variables → Actions → New repository
   secret). Export it with `generate_keys -x <file>`, paste, then delete the
   file. Never commit it.
4. **Push** the version bump and the public key to `main` through a PR.
5. **Tag** the merged commit — `v0.1.0` for Main, `v0.1.0-dev.7` for Dev — and
   push the tag.
6. **Review the draft release** that `release.yml` creates: the notes, the
   `.zip`, the `.sha256`, and that `appcast.xml` still contains the other
   channel's item.
7. **Publish the draft.** That is what makes it downloadable and what triggers
   `publish-update-feed.yml` to rebuild the `updates` branch. Check that the
   run finished and that `updates/appcast.xml` now lists both channel heads.

The very first Main release is the one that seeds the `updates` branch; until
it is published, in-app update checks find no feed.
