![Icarus VALORANT strategy planner](https://icarusstrats.com/og-image.png)

# Icarus

Icarus is a free, open-source VALORANT strategy and lineup planner for Windows, macOS, and the web beta. You can draw plans, place agents and abilities, and build a tactical library on your own machine with no account. When you want to work with a team, optional cloud sync and live rooms let everyone edit together.

[Website](https://icarusstrats.com) | [Web Beta](https://beta.icarusstrats.com) | [Microsoft Store](https://apps.microsoft.com/detail/9PBWHHZRQFW6) | [Latest Release](https://github.com/SunkenInTime/icarus/releases/latest) | [Discord](https://discord.gg/PN2uKwCqYB) | [X](https://x.com/icarusstrats) | [Dev log](https://youtu.be/dDn2rafvjMQ?si=mm1Sz-XrjvNQiRWE)

## Features

![Icarus strategy board preview](https://icarusstrats.com/board-preview.png)

- Interactive map canvas with agents, abilities, freehand drawings, shapes, text notes, and reference images.
- Live view cones cut by map height, smokes, and walls.
- Multi-page strategies with animated page transitions, PNG screenshot export, and MP4 video export.
- Lineups with standing spots, landing positions, notes, screenshots, and video links.
- VALORANT replay viewer on desktop that captures match moments straight into strategy pages.
- Local-first library with `.ica` import and export, full library backups, and no account required.
- Optional cloud sync, live collaborative editing with shared cursors, share codes and links, and Community strategy sharing.
- English, Japanese, and Chinese localization.

![Icarus editor on Bind showing Sova and Brimstone lineups](https://icarusstrats.com/lineups/lineups-on-bind.png)

## Tech stack and architecture

- **App.** Flutter builds the desktop and web beta apps, using Riverpod for state management, custom GLSL shaders in `shaders/`, and three-language localization in `lib/l10n/`.
- **Storage and core library.** Local libraries currently run on Hive in `lib/hive/` and are migrating behind a switch to the pure-Dart `packages/icarus_library` store backed by SQLite on desktop and IndexedDB on web. See [ADR 0009](docs/adr/0009-one-store-for-the-library.md).
- **Cloud and live presence.** Convex in `convex/` runs accounts, sync, and shared strategies through a patched Rust and Flutter transport in `third_party/convex_rs/` and `third_party/convex_flutter/`. A standalone generator in `tool/icarus_convex_codegen/` builds the typed Dart client and checks compatibility against shipped clients. Cloudflare R2 stores uploaded media, and a Cloudflare Worker in `presence/` runs live cursor rooms.
- **Native modules.** Native C++ and Rust modules in `native/height/` and `native/replay/` connect over FFI to calculate height visibility and decode VALORANT replays.
- **Verification and tooling.** The repository includes an automated UI driver in `tool/drive/`, deterministic Convex cost budgets in `tool/convex_cost/`, randomized client-versus-server parity tests in `tool/library_parity/`, and Architecture Decision Records in `docs/adr/`.
- **Project docs.** Read [AGENTS.md](AGENTS.md), [CONTEXT.md](CONTEXT.md), [PRODUCT.md](PRODUCT.md), [DESIGN.md](DESIGN.md), and [docs/adr/](docs/adr/).

## Requirements

- Flutter SDK via FVM, pinned to `3.44.4` in `.fvmrc` with Dart `>= 3.4.3`.
- Node.js, if you run Convex tooling or backend tests.

## Getting started

Install Dart dependencies and run the app:

```bash
fvm flutter pub get
fvm flutter run
```

If you work on `convex/` or the Node scripts, install npm dependencies too:

```bash
npm install
```

### Windows dev OAuth callbacks

Discord OAuth redirects back into the desktop app through the `icarus://auth/callback` protocol. On Windows, the installed app normally owns that protocol handler, so a dev build may not receive the browser callback.

For a temporary dev session, run the Windows build with the force protocol registration flag:

```powershell
fvm flutter run -d windows --dart-define=ICARUS_FORCE_PROTOCOL_REGISTER=true
```

This rewrites the current user's `icarus://` handler to the debug executable. After testing OAuth, launch the installed Icarus app once to restore the handler back to the installed build.

### Isolated Hive store

Desktop builds accept an absolute `--hive-store-dir` path. It moves every Hive box, including the library, preferences, and anonymous analytics, without touching the normal Hive files.

Pass the option through Flutter with one Dart entrypoint argument:

```bash
fvm flutter run -d macos -a "--hive-store-dir=/Users/your-name/Library/Containers/xyz.icarus-strats/Data/Library/Application Support/xyz.icarus-strats-demo"
```

The macOS app sandbox limits this path to Icarus's container unless the user selects another directory through a native picker. The container lives at `~/Library/Containers/xyz.icarus-strats/Data`.

Or pass it directly to a built executable:

```bash
./icarus --hive-store-dir "/absolute/path/to/icarus-demo-hive"
```

An instance started this way is separate from the installed app, in any build. In that folder it keeps every Hive box, its strategy pictures, its replays, its debug log, its WebView data, its sightline reports, and its own sign-in, so you sign it in by itself and signing it out signs out only that instance. It never registers itself as the `icarus:` link handler, never runs the desktop updater, and never sets Discord presence. Use a different absolute directory for each instance.

An instance made before this kept its pictures and replays in the installed app's application support folder, and shared the installed app's sign-in. It no longer reads that folder, so it starts signed out and without those pictures. To bring one across, copy from the support folder into the instance folder each folder named after one of that instance's strategy ids, and `replays` and `replay_cache` if it uses replays. Then sign the instance in. The support folder is `%APPDATA%\xyz.icarus-strats\icarus` on Windows, `~/Library/Containers/xyz.icarus-strats/Data/Library/Application Support/xyz.icarus-strats` on macOS, and `~/.local/share/com.example.icarus` on Linux. Copy, do not move: the installed app still uses its own.

## Build

```bash
flutter build <platform> --dart-define=ICARUS_CLOUD_ENVIRONMENT=development
```

That command makes an internal build against the named development Convex deployment. Use the release scripts in `docs/release_process.md` for stable or Store artifacts. They require explicit production cloud configuration.

## Versioning for Windows MSIX

Run this helper script to bump versions across `pubspec.yaml` and `lib/const/settings.dart`:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bump_version.ps1 -Bump patch
```

## Local prerelease publish

To test the desktop auto-updater without waiting for the full GitHub Actions build, build and publish the prerelease updater payload locally:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/publish_prerelease_local.ps1
```

This command does the following:

- Bumps the app version by `patch` by default.
- Builds the desktop prerelease package locally.
- Stages the same GitHub Pages content under `release/out/gh-pages`.
- Force-pushes that staged content to the `gh-pages` branch.
- Relies on GitHub Pages serving the `gh-pages` branch directly.

## Contributing

Fork the repository and open a pull request with your changes. Read [AGENTS.md](AGENTS.md) and [CONTEXT.md](CONTEXT.md) first so your work matches the domain terms and data safety rules.

## License and support

Icarus is free, open-source software under the [Apache 2.0 License](LICENSE). Join the [Discord](https://discord.gg/PN2uKwCqYB) for feedback, bug reports, and strategy sharing.
