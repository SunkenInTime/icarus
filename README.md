# Icarus: Valorant Strategies & Line ups

Icarus is an interactive strategy creation tool for Valorant players. It focuses on a robust map drawing system that lets teams create, save, and iterate on strategies locally.

Download: [https://apps.microsoft.com/detail/9PBWHHZRQFW6?hl=en-us&gl=US&ocid=pdpshare](https://apps.microsoft.com/detail/9PBWHHZRQFW6?hl=en-us&gl=US&ocid=pdpshare)
Dev log: [https://youtu.be/dDn2rafvjMQ?si=mm1Sz-XrjvNQiRWE](https://youtu.be/dDn2rafvjMQ?si=mm1Sz-XrjvNQiRWE)



## Features

- Interactive map drawing and annotations
- Save, load, and organize strategies locally
- Agent and ability helpers
- Desktop-focused UX for planning sessions

## Tech Stack

- Flutter (Dart)
- Riverpod for state management
- Hive for local storage

## Architecture

- `lib/main.dart` bootstraps app startup, initializes Hive, and wires Riverpod.
- State lives in Riverpod notifiers under `lib/providers/`.
- Strategies, folders, and supporting data are stored in Hive boxes defined in `lib/const/hive_boxes.dart`.
- Hive adapters are generated from `lib/hive/hive_adapters.dart`.
- Core strategy workflow is coordinated by `lib/providers/strategy_provider.dart`.
- UI is composed from screens in `lib/` and shared components under `lib/widgets/`.

## Requirements

- Flutter SDK (Dart >= 3.4.3)

## Getting Started

```bash
flutter pub get
flutter run
```

### Isolated Hive store

Desktop builds accept an absolute `--hive-store-dir` path. It moves every
Hive box, including the library, preferences, and anonymous analytics, without
touching the normal Hive files.

Pass the option through Flutter with one Dart entrypoint argument:

```bash
fvm flutter run -d macos -a "--hive-store-dir=/Users/your-name/Library/Containers/xyz.icarus-strats/Data/Library/Application Support/xyz.icarus-strats-demo"
```

The macOS app sandbox limits this path to Icarus's container unless the user
selects another directory through a native picker. The container lives at
`~/Library/Containers/xyz.icarus-strats/Data`.

Or pass it directly to a built executable:

```bash
./icarus --hive-store-dir "/absolute/path/to/icarus-demo-hive"
```

Strategy media, debug logs, and WebView data still use the normal application
support directory. Use a different absolute Hive directory for each instance.

## Build

```bash
flutter build <platform>
```

## Versioning (Windows MSIX)

There is a helper script for bumping versions across `pubspec.yaml` and `lib/const/settings.dart`.

```powershell
powershell -ExecutionPolicy Bypass -File scripts/bump_version.ps1 -Bump patch
```

## Local Prerelease Publish

To test the desktop auto-updater without waiting for the full GitHub Actions build, build and publish the prerelease updater payload locally:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/publish_prerelease_local.ps1
```

This command:

- bumps the app version by `patch` by default
- builds the desktop prerelease package locally
- stages the same GitHub Pages content under `release/out/gh-pages`
- force-pushes that staged content to the `gh-pages` branch
- relies on GitHub Pages serving the `gh-pages` branch directly

## Contributing

If you would like to contribute, please fork the repository and submit a pull request with your proposed changes.

## Support

This project is completely free and open source. Your support helps maintain it.
