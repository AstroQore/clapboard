---
name: Bug report
about: Report a problem with capture, mixing, Auto Sync, sessions, or the build
title: "[Bug]: "
labels: bug
---

**What happened?**

A clear description of the problem, and what you expected instead.

**Steps to reproduce**

1.
2.
3.

**Environment**

- macOS version:
- Xcode / Swift version (`swift --version`):
- Clapboard commit or version:
- Built with `CLAPBOARD_CODESIGN_IDENTITY` set, or ad-hoc signed?

**Device list**

Paste the output of:

```sh
.build/Clapboard.app/Contents/MacOS/Clapboard --list-devices
```

**Engine test summary**

If the problem involves capture, dropouts, or silence, paste the last few
lines of an `--engine-test` run (see `CONTRIBUTING.md` for the exact
command), including:

- Overload count
- Callback count
- Watchdog age

```
(paste here)
```

**Other HAL drivers installed**

Are any of the following installed on this machine? (Loopback, Audio Hijack,
BlackHole, or any other virtual/HAL audio driver.) These can interact with
aggregate device creation in ways a plain hardware setup does not.

- [ ] Loopback
- [ ] Audio Hijack
- [ ] Other (name it):
- [ ] None

**Additional context**

Screenshots, `--sync-test` output, or session file excerpts (redact anything
you'd rather not share — see `SECURITY.md`).
