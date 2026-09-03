# CLAUDE.md

Auto-loaded by Claude Code at the start of every session in this repository.

The operating manual — layout and build, git conventions, and the real-time
audio and Core Audio rules that govern `Sources/ClapboardCore` — lives in
[AGENTS.md](AGENTS.md). `AGENTS.md` is self-contained and authoritative. Read
it before touching any code, resource, or script here.

Three things that cause silent failures or public-repo accidents:

1. **Never run `swift run` to test audio behavior.** It produces a bare
   executable with no bundle identifier, so macOS grants it no Microphone
   permission, and the HAL silently hands back digitally silent input instead
   of an error. Always run `.build/Clapboard.app` — see `AGENTS.md` and
   `docs/PERMISSIONS.md`.
2. **The render thread (`Sources/ClapboardCore/RT/`) has hard real-time
   rules**: no allocation, no locks, no logging, no class references, no
   `Task`/Dispatch. `AGENTS.md` § "Real-time audio rules" is not optional
   guidance — a violation there is a dropout or a crash on someone else's
   machine, not a test failure on this one.
3. **Key every Core Audio device by UID, never by `AudioObjectID`.** Object
   IDs are not stable across a hot-plug; `AGENTS.md` § "Core Audio rules" has
   the aggregate-device rebuild implications.

Work in `.agents/worktrees/<branch>`, never on the main tree.
