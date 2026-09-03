## Summary

<!-- What does this change do, and why? -->

## Checklist

- [ ] `swift build`, `swift test`, and `./Scripts/build_app.sh release` all
      pass locally.
- [ ] `codesign -d --entitlements - .build/Clapboard.app` prints an empty
      `<dict/>`.
- [ ] Changes to `Sources/ClapboardCore/RT/` or the IOProc path respect the
      real-time rules in `AGENTS.md` (no allocation, no locks, no logging, no
      class references on the render thread) — call this out below if
      applicable.
- [ ] Changes to Core Audio device handling key devices by UID, not
      `AudioObjectID`, and account for the aggregate-device rebuild rules in
      `AGENTS.md`.
- [ ] New behavior has a test in `Tests/ClapboardCoreTests`, or a headless
      command repro described below.
- [ ] `CHANGELOG.md` has an `Unreleased` entry if this is user-visible.

## Real-time / Core Audio impact

<!-- If this PR touches Core/RT or the IOProc path, describe what changed and
     why it still satisfies AGENTS.md's real-time rules. Otherwise: N/A. -->

## Test plan

<!-- Commands you ran, headless-command output, or manual steps you followed. -->
