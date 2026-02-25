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

## Position Handling (Detailed)
Icarus stores object positions in a normalized coordinate system so layouts stay consistent across window sizes, zoom levels, screenshots, and saved files.

### 1) Coordinate spaces
- **Screen space (pixels):** actual rendered location on the current canvas.
- **World space (normalized):** persisted positions for all placed objects.

World-space dimensions are defined in `lib/const/coordinate_system.dart`:
- `normalizedHeight = 1000`
- `worldAspectRatio = 16/9`
- `worldNormalizedWidth = normalizedHeight * worldAspectRatio` (about `1777.78`)

Core transforms:
- `screenToCoordinate`: converts drag/drop pixel offsets into normalized world positions.
- `coordinateToScreen`: converts stored normalized positions back to on-screen pixels.

This is why one saved strategy can be reopened at different resolutions without manual re-alignment.

### 2) Drag/drop and update pipeline
For agents, abilities, utilities, text, images, and lineup placement:
1. UI drag/drop handlers get a global pointer position.
2. Position is converted to local widget coordinates (`globalToLocal`).
3. Local position is converted to normalized world space (`screenToCoordinate`).
4. Provider updates the relevant `Placed*` model with `updatePosition`.

Key references:
- Placement and drag-end conversion: `lib/widgets/draggable_widgets/placed_widget_builder.dart`
- Provider updates: `lib/providers/*_provider.dart`
- Base position/history model: `lib/const/placed_classes.dart`

### 3) Zoom-aware dragging
The map can be scaled (`Transform.scale`). To keep drag behavior correct while zoomed:
- `screen_zoom_provider.dart` adjusts drag anchor strategy and offsets.
- Feedback widgets are wrapped in `ZoomTransform`.

Without this, dropped positions would drift when zoom is not `1.0`.

### 4) Bounds checks and safe anchors
Position validity is checked in normalized space via `CoordinateSystem.isOutOfBounds(...)` with a small tolerance.

Different object types use different anchor/safe-area rules:
- **Agents:** center point check using configured agent size.
- **Abilities:** uses ability-specific anchor (`getAnchorPoint(...)`) and map scale.
- **Non-view-cone utilities, text, and images:** use safe-area/anchor approximations before deciding whether to remove an out-of-bounds object.
- **View-cone utility:** still updates in normalized space, but uses a rotation/length interaction model and currently follows different removal behavior.

### 5) Side switching (attack/defense mirror)
When switching sides, placed content is mirrored across both axes in normalized space.

General flip logic (top-left anchored widgets):
- `x' = worldNormalizedWidth - x - widgetWidthNormalized`
- `y' = normalizedHeight - y - widgetHeightNormalized`

Implementation:
- `getFlippedPosition(...)` in `lib/const/placed_classes.dart`
- Called from each model/provider switch function (`agent`, `ability`, `utility`, `text`, `image`, `lineup`)

For rotatable widgets, the Y calculation applies an extra compensation to keep perceived position stable after mirroring. Rotatable abilities/utilities also add `pi` to rotation so direction stays visually correct.

### 6) Undo/redo and persistence
- Every position change records a `PositionAction` in per-widget history stacks.
- Undo/redo replays stored normalized positions, not screen pixels.
- Positions serialize as `{dx, dy}` via `OffsetConverter` and are stored in Hive/JSON.

Because flips and migration update both current positions and action history stacks, undo/redo remains coherent after side switches and older data migrations.

### 7) Migration compatibility
`StrategyProvider.migrateToWorld16x9(...)` shifts older saved data into the current world-space layout (including agents, abilities, utilities, text, images, drawings, and lineup positions).  
This preserves relative placement from pre-16:9-world saves.

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
