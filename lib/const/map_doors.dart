import 'dart:math' as math;
import 'dart:ui';

import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';

/// What changing a door does, and so how it's drawn.
enum MapDoorKind {
  /// Open at rest. Summit's walls drop and stay down for the round.
  drop,

  /// Closed at rest. Lotus's doors turn side-on; both ends of the spin are
  /// closed in the game, so "changed" means "being spun on this step".
  spin,

  /// Closed at rest. Lotus's A Link wall breaks and stays broken for the round.
  breakable,
}

/// A part of a map a player can change. Lines come from the game's level files
/// and the art, in attack SVG units, so a layout patch moves a door here and
/// saved doors follow: a changed door's row names it and never places it.
class MapDoor {
  const MapDoor({
    required this.id,
    required this.map,
    required this.kind,
    required this.start,
    required this.end,
    required this.replayActor,
  });

  final String id;
  final MapValue map;
  final MapDoorKind kind;
  final Offset start;
  final Offset end;

  /// The name a decoded replay files this door's moves under.
  final String replayActor;

  /// Tells a user what a click does.
  String tag({required bool changed}) => switch ((kind, changed)) {
        (MapDoorKind.drop, false) => 'Drop the wall',
        (MapDoorKind.drop, true) => 'Raise the wall',
        (MapDoorKind.spin, false) => 'Spin the door',
        (MapDoorKind.spin, true) => 'Close the door',
        (MapDoorKind.breakable, false) => 'Break the wall',
        (MapDoorKind.breakable, true) => 'Repair the wall',
      };

  /// The door's line turned by [changed], 0 at rest and 1 changed, in canonical
  /// world units. Only a spin moves.
  (Offset, Offset) worldLine({double changed = 0}) {
    final from = _svgToWorld(map, start);
    final to = _svgToWorld(map, end);
    if (kind != MapDoorKind.spin || changed == 0) return (from, to);
    final center = (from + to) / 2;
    final angle = changed * math.pi / 2;
    Offset turned(Offset point) {
      final offset = point - center;
      return center +
          Offset(
            offset.dx * math.cos(angle) - offset.dy * math.sin(angle),
            offset.dx * math.sin(angle) + offset.dy * math.cos(angle),
          );
    }

    return (turned(from), turned(to));
  }

  /// The row that saves this door as changed. It's a real rectangle in the
  /// changed pose, so a build that doesn't know doors shows a mark on the door.
  /// A broken wall is the floor's colour: a rectangle's border is solid, so
  /// any other colour on a bar this thin reads as a wall, the opposite of what
  /// happened.
  PlacedUtility row({required String id}) {
    final (from, to) = worldLine(changed: 1);
    final along = to - from;
    final worldPerMeter = CoordinateSystem.virtualLengthInWorld(
      AgentData.inGameMetersDiameter * (Maps.mapScale[map] ?? 1),
    );
    final lengthMeters = along.distance / worldPerMeter;
    final widthMeters = mapDoorBarWorldWidth / worldPerMeter;
    final center = (from + to) / 2;
    return PlacedUtility(
      id: id,
      type: UtilityType.customRectangle,
      position: center -
          Offset(along.distance, mapDoorBarWorldWidth) / 2,
      customWidth: widthMeters,
      customLength: lengthMeters,
      customColorValue: switch (kind) {
        MapDoorKind.drop => 0xFF000000,
        MapDoorKind.spin => _mapWallColor,
        MapDoorKind.breakable => _mapFloorColor,
      },
      customOpacityPercent: 100,
      mapDoor: this.id,
    )..rotation = along.direction;
  }
}

/// The walls' colour in the map art, for a row a build draws as a plain shape.
const _mapWallColor = 0xFFB27C40;

/// The floor's colour in the map art.
const _mapFloorColor = 0xFF271406;

/// How thick a door's bar is, in world units: about the map art's walls.
const mapDoorBarWorldWidth = 4.0;

const mapDoors = <MapDoor>[
  MapDoor(
    id: 'summit-a',
    map: MapValue.summit,
    kind: MapDoorKind.drop,
    start: Offset(337.5, 154.2),
    end: Offset(359.8, 154.2),
    replayActor: 'DescentBox_v12',
  ),
  MapDoor(
    id: 'summit-mid',
    map: MapValue.summit,
    kind: MapDoorKind.drop,
    start: Offset(191.3, 166.4),
    end: Offset(213.0, 166.4),
    replayActor: 'DescentBox_v9',
  ),
  MapDoor(
    id: 'summit-b',
    map: MapValue.summit,
    kind: MapDoorKind.drop,
    start: Offset(34.3, 117.2),
    end: Offset(56.0, 117.2),
    replayActor: 'DescentBox_v5',
  ),
  MapDoor(
    id: 'lotus-a',
    map: MapValue.lotus,
    kind: MapDoorKind.spin,
    start: Offset(423.7, 241.2),
    end: Offset(448.2, 241.2),
    replayActor: 'Drawbridge6',
  ),
  MapDoor(
    id: 'lotus-c',
    map: MapValue.lotus,
    kind: MapDoorKind.spin,
    start: Offset(158.1, 259.8),
    end: Offset(158.1, 283.8),
    replayActor: 'Drawbridge5',
  ),
  MapDoor(
    id: 'lotus-a-link',
    map: MapValue.lotus,
    kind: MapDoorKind.breakable,
    start: Offset(338.4, 200.9),
    end: Offset(338.4, 210.7),
    replayActor: 'RespawningWallPlate',
  ),
];

/// The doors of [map].
List<MapDoor> mapDoorsOf(MapValue map) =>
    [for (final door in mapDoors) if (door.map == map) door];

/// The door of [map] that [utility] changes. Null for an ordinary shape, which
/// includes a row naming a door this build doesn't know or one on another map:
/// those draw as the rectangles they are, so a door added in a later release
/// doesn't vanish on a build one version behind.
MapDoor? mapDoorOfRow(PlacedUtility utility, MapValue map) {
  final id = utility.mapDoor;
  if (id == null) return null;
  for (final door in mapDoors) {
    if (door.id == id && door.map == map) return door;
  }
  return null;
}

/// [utilities] without the ones that are doors of [map]: what's drawn and
/// handled as an item.
Iterable<PlacedUtility> withoutMapDoors(
  Iterable<PlacedUtility> utilities,
  MapValue map,
) =>
    utilities.where((utility) => mapDoorOfRow(utility, map) == null);

/// The doors of [map] that [utilities] change, by id.
Set<String> changedMapDoors(Iterable<PlacedUtility> utilities, MapValue map) =>
    {
      for (final utility in utilities)
        if (mapDoorOfRow(utility, map) case final door?) door.id,
    };

/// Where an attack SVG point of [map] lands in canonical world units, as the
/// map art draws it: fitted inside the map's box, centred.
Offset _svgToWorld(MapValue map, Offset svg) {
  final viewBox = Maps.mapViewBox[map]!;
  const height = CoordinateSystem.worldHeight;
  const mapWidth = height * CoordinateSystem.defaultMapAspectRatio;
  const worldWidth = height * (16 / 9);
  final scale = math.min(mapWidth / viewBox.width, height / viewBox.height);
  return Offset(
    (worldWidth - mapWidth) / 2 +
        (mapWidth - viewBox.width * scale) / 2 +
        svg.dx * scale,
    (height - viewBox.height * scale) / 2 + svg.dy * scale,
  );
}
