# Icarus — Valorant Strategies & Line ups

A Flutter desktop app for creating interactive Valorant game strategies. See `README.md` for features and architecture.

## Cursor Cloud specific instructions

### Services

| Service | How to run |
|---------|-----------|
| Icarus (Flutter Linux desktop app) | `fvm flutter run -d linux` |

### Key caveats

- **FVM is required.** Flutter is pinned to `3.38.4` via `.fvmrc`. Always prefix Flutter/Dart commands with `fvm` (e.g. `fvm flutter run`, `fvm dart run`).
- **`xdg-user-dirs` must be initialized.** The `path_provider` plugin needs XDG user directories. Run `sudo apt-get install -y xdg-user-dirs && xdg-user-dirs-update` if the app crashes with `MissingPlatformDirectoryException`.
- **Linux build deps.** `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-14-dev` must be installed for Linux desktop builds.
- **Code generation.** After changing Hive models, Riverpod providers, or JSON-serializable classes, regenerate with: `fvm flutter pub run build_runner build --delete-conflicting-outputs`.
- **No automated tests exist** in this codebase. `flutter test` will find nothing.
- **Lint.** `fvm flutter analyze` — expect ~70 pre-existing warnings/infos (unused imports, deprecated APIs). No errors.
- **Build.** `fvm flutter build linux --debug` produces the binary at `build/linux/x64/debug/bundle/icarus`.
