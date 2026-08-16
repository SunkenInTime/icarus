# Proposal: Interactive map elements (Lotus and Summit doors)

Status: research proposal, no implementation yet.

## The request

Users asked for clickable, stateful map elements, "like valoplant":

- Clicking a Lotus door makes it spin (rotate open/closed).
- Clicking a Summit door turns it black to show it has been dropped.
- Related asks in the same list: a clickable Sage Wall whose blocks can be
  broken, and clickable smokes / Viper Wall that fade when clicked to show
  they are down.

## What the game and valoplant actually do

In-game mechanics (what we are modeling):

- **Lotus** has two rotating doors (A Main ↔ A Tree, and C Mound ↔ B Main).
  A toggle on either side rotates the door 180° over ~8–10 seconds, briefly
  opening an otherwise blocked hallway. Doors are also breakable, which
  leaves the passage permanently open.
- **Summit** (June 2026) has three droppable walls (A Art ↔ A Garden,
  Mid Window ↔ Mid Bottom, B Tower ↔ B Site). Each is connected to a 125 HP
  switch; when the switch is destroyed the wall crashes down and
  **permanently blocks that route for the rest of the round**.

valoplant.gg's planner mirrors this: door markers are drawn on top of the
map artwork and are directly clickable. Clicking a Lotus door toggles it
between closed and open (the door graphic rotates), and clicking a Summit
door toggles it between "up" (passable) and "dropped" (drawn as a solid
dark/black bar reading as a permanent obstacle). Per their announcement,
Summit's "toggle-able doors also affect intelligent agent pathing and
vision cones" — door state feeds their vision/pathing model, not just the
visuals. The core interaction is a plain single click on the element, with
an immediate visual state change; no menus.

Sources:
- https://valoplant.gg/
- Lotus doors: https://wiki.playvalorant.com/en-us/Lotus,
  https://mobalytics.gg/blog/valorant/lotus-map-guide-layout-tip-tricks/
- Summit walls: https://wiki.playvalorant.com/en-us/Summit,
  https://www.thespike.gg/valorant/maps/summit
- valoplant Summit announcement (toggle-able doors + pathing/vision):
  https://x.com/ValoPlant

## Where Icarus is today

- `lib/interactive_map.dart` (`InteractiveMap` / `_InteractiveMapState`)
  renders the canvas as a `Stack` inside an `InteractiveViewer`: dot grid →
  map SVG (`SvgPicture.asset`, recolored by `_MapSvgColorMapper` from
  `effectiveMapThemePaletteProvider`) → optional overlays (spawn walls,
  callouts, ult orbs — each its own per-map SVG asset) → `PlacedWidgetBuilder`
  → drawing layer. Defense side is handled by swapping `*_defense.svg`
  assets and `Transform.flip`-ping overlay layers.
- Per-map facts live as code constants in `lib/const/maps.dart` (`MapValue`,
  `Maps.mapNames`, `Maps.mapScale`, `Maps.mapViewBox`,
  `Maps.visionGeometryPadding`…). Per-map vision data ships as
  `assets/maps/<map>_vision.json`.
- Map view state lives in `lib/providers/map_provider.dart` (`MapState`:
  `currentMap`, `isAttack`, `showSpawnBarrier`, `showUltOrbs`,
  `showRegionNames`).
- A strategy's content is per **page**: `StrategyPage`
  (`lib/providers/strategy_page.dart`) holds `drawingData`, `agentData`,
  `abilityData`, `textData`, `imageData`, `utilityData`, `isAttack`,
  `settings`, `lineUpGroups`, each serialized through its provider's
  `objectToJson` / `fromJson` into the page JSON that Hive and .ica export
  both consume. `Settings.versionNumber` (currently 94) gates migrations.
- There is already precedent for lightweight per-element visual state:
  `AbilityVisualState` on `PlacedAbility` (`lib/const/placed_classes.dart`)
  stores `showRangeOutline` / `showRangeFill` / … as additive JSON fields
  with defaults, edited via `ability_visibility_context_menu.dart`.
- Positions are normalized world coordinates via
  `CoordinateSystem.instance` (`lib/const/coordinate_system.dart`,
  world = 1777.8 × 1000 with the map inset by
  `mapPaddingNormalizedX ≈ 268.9`), so anything authored in attack-frame
  coordinates can be mirrored with the same 180° world rotation
  (`Transform.flip(flipX: !isAttack, flipY: !isAttack)`) the spawn-wall,
  ult-orb, and drawing layers use. Note the base map itself is *swapped*
  (`_map.svg` ↔ `_map_defense.svg`), not flipped.
- `MouseWatch` (`lib/widgets/mouse_watch.dart`) is the existing primitive
  that gives a placed element a hover cursor, an optional `onTap`, and a
  `ShadContextMenuRegion` — ready-made for a clickable door.

There is currently no concept of a map-owned, clickable element: everything
interactive is something the user placed.

## Proposed design

### 1. Data model: `MapInteractable` (static, per map)

New file `lib/const/map_interactables.dart`, in the same style as
`maps.dart` — code constants, not runtime JSON:

```dart
enum MapInteractableKind { rotatingDoor, droppableDoor }

class MapInteractable {
  final String id;              // stable, e.g. "lotus_door_a"
  final MapInteractableKind kind;
  final Offset position;        // normalized world coords, attack frame
  final Size size;              // normalized door footprint
  final double angle;           // door orientation on the map, radians
}

class MapInteractables {
  static const Map<MapValue, List<MapInteractable>> byMap = {
    MapValue.lotus:  [ /* 2 rotating doors */ ],
    MapValue.summit: [ /* 3 droppable doors */ ],
  };
}
```

Maps without entries get no layer at all; adding a future map is purely
additive data.

### 2. State: per page, persisted

Door state is part of the plan ("on this step, the Mid wall is already
down"), so it belongs on `StrategyPage`, not on `MapState`:

- Add `Map<String, int> interactableStates` to `StrategyPage`
  (interactable id → state index; 0 = default/closed/up). Absent id means
  default, so the field is `{}` for every existing strategy and old .ica
  files round-trip untouched — same additive-with-default pattern as
  `AbilityVisualState`. A new page slice touches `StrategyPage` in five
  places: the field, the constructor, `copyWith` (which deep-copies via the
  JSON codec), `toJson`, and `fromJson`.
- Bump `Settings.versionNumber` and regenerate Hive adapters
  (`dart run build_runner build --delete-conflicting-outputs`) since
  `StrategyPage` is a Hive model. No data migration needed — only a new
  optional field with a safe default; .ica export/import go through
  `page.toJson`, so they pick the field up for free.
- New `lib/providers/interactable_state_provider.dart`
  (`NotifierProvider<InteractableStateProvider, Map<String, int>>`) with
  `toggle(String id)`, `fromHive(...)`, and `objectToJson`/`fromJson`
  statics matching the other page-slice codecs. Wire it into
  `StrategyProvider._syncCurrentPageToHive()` and `setActivePage()` next to
  the existing providers so page switching flushes/hydrates it; route
  toggles through `actionProvider.notifier.performTransaction` (the same
  path `updateVisualState` uses) so door clicks are undoable and mark the
  strategy dirty for auto-save.

Because state is per page, video export naturally shows doors changing
between steps. Animating a door *during* a page transition would need it
represented in `_snapshotAllPlaced()` / `TransitionPlanner.diff`; initially
door state simply snaps with the page (like `isAttack` does today).

### 3. Rendering and interaction: `MapInteractableLayer`

New widget `lib/widgets/map_interactable_layer.dart`, inserted in
`interactive_map.dart`'s stack directly after the map SVG (below callouts
and `PlacedWidgetBuilder`, so placed widgets and drags keep priority):

- Positioned with the same `mapLeft`/`mapWidth` frame as the map SVG and
  wrapped in the same `Transform.flip` used by the drawing layer, so
  attack-frame coordinates work on both sides for free.
- Each interactable is a small `Positioned` child using `MouseWatch`
  (hover cursor + `onTap` + optional right-click menu for free), with the
  hit area padded slightly beyond the visual — doors are only a few px at
  min zoom — and a subtle hover highlight so it's discoverable as
  clickable.
- **Lotus (`rotatingDoor`)**: a slim rounded bar in the theme highlight
  color. Tap toggles closed ↔ open; presentation is an `AnimatedRotation`
  (90° visual turn around the door center, ~450 ms, `Curves.easeInOutCubic`)
  echoing the in-game spin without holding the user up ("the user is
  mid-thought"). Open state renders the bar perpendicular to the doorway,
  reading as a gap.
- **Summit (`droppableDoor`)**: same bar; tap toggles up ↔ dropped.
  Dropped is drawn as a solid near-black bar (a fixed dark neutral, e.g.
  `#0a0a0a` with a faint outline — *not* palette-derived, since map themes
  vary and "black = blocked" must read in every palette), animated with a
  short color/opacity tween. Up state is drawn hollow/outlined in the
  detail color so the route reads as open.

Door colors otherwise follow `effectiveMapThemePaletteProvider` so themed
maps stay coherent (DESIGN.md palette).

Screenshot and video export render the same stack, so exports show door
state with no extra work.

### 4. Extensibility: Sage Wall and smokes

These are *placed* elements, so they ride the existing
`AbilityVisualState` rail rather than the map layer:

- Add `isFaded` (or `expiredOpacity`) to `AbilityVisualState` — additive
  JSON field, default false, committed through
  `abilityProvider.notifier.updateVisualState` inside
  `actionProvider.performTransaction` exactly like the existing outline/fill
  toggles in `ability_visibility_context_menu.dart`, so it is persisted and
  undoable. Smokes (`CircleAbility`) and walls
  (`ResizableSquareAbility(isWall: true)` — Viper, Harbor, Neon) render at
  ~30% opacity when faded, communicating "this util is down" without
  deleting it from the page.
- Sage Wall (`RotatableImageAbility` in `lib/const/agents.dart:779`,
  rendered by `RotatableImageWidget`) gets a per-segment
  `List<bool> brokenSegments` on `PlacedAbility` (same additive pattern as
  `armLengthsMeters` for Deadlock's mesh); broken segments render as
  gaps/cracked tint. Clicking a segment toggles it.

Nothing in the `MapInteractable` design is coupled to doors: a future
`kind` (e.g. destructible Lotus door → stuck-open state) is one enum value
and one renderer branch.

### 5. Files that change

| File | Change |
| --- | --- |
| `lib/const/map_interactables.dart` | new — static door definitions for Lotus and Summit |
| `lib/widgets/map_interactable_layer.dart` | new — rendering + tap handling |
| `lib/interactive_map.dart` | insert layer into the stack |
| `lib/providers/interactable_state_provider.dart` | new — per-page state + toggle |
| `lib/providers/strategy_page.dart` | `interactableStates` field + (de)serialization |
| `lib/providers/strategy_provider.dart` | wire new provider into `_syncCurrentPageToHive` / `setActivePage` / page copy |
| `lib/const/settings.dart` | bump `versionNumber` |
| `lib/hive/*` (generated) | regenerate adapters via build_runner |
| `lib/const/placed_classes.dart` | Phase 3: `AbilityVisualState.isFaded`, `brokenSegments` |

### 6. Phased plan

1. **Phase 1 — Summit doors (simplest visual):** data model, per-page
   state, layer, tap-to-toggle with black "dropped" rendering. Calibrate
   the three door positions against `assets/maps/summit_map.svg`
   (`Maps.mapViewBox[MapValue.summit]` = 435×473). Verify .ica round-trip
   and old-file import.
2. **Phase 2 — Lotus doors:** add the two rotating doors with the spin
   animation; verify defense-side mirroring.
3. **Phase 3 — placed-element states:** smoke/Viper Wall fade toggle and
   Sage Wall segment breaking on `AbilityVisualState` / `PlacedAbility`.
4. **Phase 4 (stretch) — systems integration:** feed door state into the
   view-cone geometry (`lib/view_cone/`, `*_vision.json`) so a dropped
   Summit wall blocks vision cones — the part of valoplant's feature users
   don't see but feel — and animate door state changes during page
   transitions in video export.

### 7. Open questions / risks

- **Door coordinates** need hand-calibration against our cropped SVGs
  (same process as `visionGeometryAlignment` tuning). Small, but fiddly.
- **Gesture priority:** the layer sits above the map SVG's
  tap-clears-ability-bar `GestureDetector`; door taps must not also clear
  the ability bar, and must lose to drags of placed widgets. Keeping the
  layer below `PlacedWidgetBuilder` and using opaque hit-test only on the
  door rects handles this, but needs testing at high zoom.
- **Vision integration (Phase 4)** requires editable wall segments in the
  vision geometry, which today is static per map — scoped out of the
  initial phases deliberately.
- **Server-readiness:** `interactableStates` is a flat `Map<String, int>`
  keyed by stable ids with defaults on absence — trivially readable by
  code that has never seen our widgets, per the data-layer philosophy.
