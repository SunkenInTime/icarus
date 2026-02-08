# Icarus: Valorant Strategies & Line ups

Icarus is an interactive strategy creation tool for Valorant players. It focuses on a robust map drawing system that lets teams create, save, and iterate on strategies locally.

Download: https://apps.microsoft.com/detail/9PBWHHZRQFW6?hl=en-us&gl=US&ocid=pdpshare
Dev log: https://youtu.be/dDn2rafvjMQ?si=mm1Sz-XrjvNQiRWE

<img src="https://l7y6qjyp5m.ufs.sh/f/usun6XPoM0UCpB9qMageWNaYX3kSziMD5UmKObA6uIe7wB0Z">

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

## Build
```bash
flutter build <platform>
```

## Versioning (Windows MSIX)
There is a helper script for bumping versions across `pubspec.yaml` and `lib/const/settings.dart`.
```powershell
powershell -ExecutionPolicy Bypass -File scripts/bump_version.ps1 -Bump patch
```

## Contributing
If you would like to contribute, please fork the repository and submit a pull request with your proposed changes.

## Support
This project is completely free and open source. Your support helps maintain it.

<a href="https://www.buymeacoffee.com/daradoescode" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" style="height: 60px !important;width: 217px !important;" ></a>
