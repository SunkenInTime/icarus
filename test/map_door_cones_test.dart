import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/map_door_walls.dart';
import 'package:icarus/view_cone/svg_height_cone_cache.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// Door walls against the real bundled models. See docs/vision-model.md,
/// "Map doors".
Map<String, dynamic> _json(MapValue map, bool isAttack) =>
    jsonDecode(utf8.decode(gzip.decode(File(
                'assets/maps/${map.name}_svg_height_${isAttack ? 'attack' : 'defense'}.json.gz')
            .readAsBytesSync())))
        as Map<String, dynamic>;

final _models = <(MapValue, bool, bool), SvgHeightVisibility>{};

/// The model of [map] on a side, with or without its doors.
SvgHeightVisibility _model(MapValue map, bool isAttack, {bool doors = true}) =>
    _models[(map, isAttack, doors)] ??= SvgHeightVisibility.fromJson(
      _json(map, isAttack),
      doorWalls: doors ? mapDoorWalls(map, isAttack: isAttack) : const [],
    );

/// [door]'s rest line in the model of its map on a side.
(Offset, Offset) _lineInModel(MapDoor door, bool isAttack) {
  final transform = SvgHeightMapTransform.forMap(door.map);
  Offset inModel(Offset world) => transform.sourceFromSideWorld(
        isAttack
            ? world
            : Offset(
                SvgHeightMapTransform.worldWidth - world.dx,
                SvgHeightMapTransform.worldHeight - world.dy,
              ),
        isAttack: isAttack,
      );
  final (from, to) = door.worldLine();
  return (inModel(from), inModel(to));
}

/// A spot a player can stand on [sign]'s side of [door], square on to it.
Offset _spotBeside(
  SvgHeightVisibility model,
  (Offset, Offset) line,
  int sign, {
  double distance = 6,
}) {
  final along = line.$2 - line.$1;
  final normal = Offset(-along.dy, along.dx) / along.distance;
  final middle = (line.$1 + line.$2) / 2;
  return model.standablePointNear(middle + normal * (sign * distance))!;
}

SvgVisibilityHit? _ray(
  SvgHeightVisibility model,
  Offset from,
  Offset to, {
  Set<String> changed = const {},
}) {
  final toward = to - from;
  return model.castRay(
    origin: from,
    directionRadians: math.atan2(toward.dy, toward.dx),
    range: 60,
    supportId: model.automaticSupportAt(from)?.id,
    changedDoors: changed,
  );
}

double _distanceToSegment(Offset point, Offset a, Offset b) {
  final along = b - a;
  final t = along.distanceSquared == 0
      ? 0.0
      : (((point - a).dx * along.dx + (point - a).dy * along.dy) /
              along.distanceSquared)
          .clamp(0.0, 1.0);
  return (a + along * t - point).distance;
}

/// How far any point of [outline] is from the outline of [other]. Two equal
/// outlines can list different points along one straight edge.
double _farthestFrom(List<Offset> outline, List<Offset> other) {
  var farthest = 0.0;
  for (final point in outline) {
    var nearest = double.infinity;
    for (var i = 0; i < other.length; i++) {
      nearest = math.min(
        nearest,
        _distanceToSegment(point, other[i], other[(i + 1) % other.length]),
      );
    }
    farthest = math.max(farthest, nearest);
  }
  return farthest;
}

void main() {
  for (final door in mapDoors) {
    for (final isAttack in [true, false]) {
      final side = isAttack ? 'attack' : 'defense';
      final solidAtRest = door.kind != MapDoorKind.drop;
      final blockedState = solidAtRest ? const <String>{} : {door.id};

      test('${door.id} on $side seals its corridor when solid', () {
        final model = _model(door.map, isAttack);
        final line = _lineInModel(door, isAttack);
        final from = _spotBeside(model, line, 1);
        final across = line.$2 - line.$1;

        for (var t = -0.04; t <= 1.04; t += 0.02) {
          final hit = _ray(
            model,
            from,
            line.$1 + across * t,
            changed: blockedState,
          );
          expect(hit, isNotNull, reason: 't=$t');
          expect(
            hit!.distance,
            lessThan((from - (line.$1 + across * t)).distance + 1.5),
            reason: 't=$t stopped at ${hit.wallId}',
          );
        }
      });

      test('${door.id} on $side stops a ray at its own wall', () {
        final model = _model(door.map, isAttack);
        final line = _lineInModel(door, isAttack);
        final from = _spotBeside(model, line, 1);

        final hit = _ray(
          model,
          from,
          (line.$1 + line.$2) / 2,
          changed: blockedState,
        );

        expect(hit?.wallId, startsWith('door-${door.id}'));
      });
    }
  }

  group('a door that opens', () {
    test('Summit at rest is the model without doors, cone for cone', () {
      final bare = _model(MapValue.summit, true, doors: false);
      final withDoors = _model(MapValue.summit, true);

      for (var x = 30.0; x < 370; x += 23) {
        for (var y = 30.0; y < 300; y += 23) {
          final spot = bare.standablePointNear(Offset(x, y));
          if (spot == null) continue;
          final support = bare.automaticSupportAt(spot)?.id;
          for (final direction in [0.0, 1.57, 3.14, 4.71]) {
            List<Offset> outline(SvgHeightVisibility model) => model
                .horizontalCone(
                  origin: spot,
                  directionRadians: direction,
                  range: 70,
                  apertureRadians: 1.8,
                  supportId: support,
                )
                .polygon;
            final before = outline(bare), after = outline(withDoors);
            expect(
              math.max(
                _farthestFrom(before, after),
                _farthestFrom(after, before),
              ),
              lessThan(1e-9),
              reason: '$spot facing $direction',
            );
          }
        }
      }
    });

    test('a dropped Summit wall is gone from the other wall', () {
      final door = mapDoors.firstWhere((door) => door.id == 'summit-mid');
      final model = _model(MapValue.summit, true);
      final line = _lineInModel(door, true);
      final from = _spotBeside(model, line, 1);
      final middle = (line.$1 + line.$2) / 2;

      expect(
        _ray(model, from, middle, changed: {'summit-a'})?.wallId,
        isNot(startsWith('door-')),
      );
    });

    test('a broken A Link wall lets a ray through', () {
      final door = mapDoors.firstWhere((door) => door.id == 'lotus-a-link');
      final model = _model(MapValue.lotus, true);
      final line = _lineInModel(door, true);
      final from = _spotBeside(model, line, 1);
      final middle = (line.$1 + line.$2) / 2;

      final hit = _ray(model, from, middle, changed: {door.id});

      expect(hit?.wallId ?? '', isNot(startsWith('door-')));
      expect(
        hit?.distance ?? 60,
        greaterThan((from - middle).distance + 1),
      );
    });
  });

  group('a spun Lotus door', () {
    for (final id in ['lotus-a', 'lotus-c']) {
      final door = mapDoors.firstWhere((door) => door.id == id);

      test('$id opens the gaps either side and blocks its own line', () {
        final model = _model(MapValue.lotus, true);
        final line = _lineInModel(door, true);
        final from = _spotBeside(model, line, 1, distance: 16);
        final across = line.$2 - line.$1;
        final middle = (line.$1 + line.$2) / 2;

        expect(
          _ray(model, from, middle, changed: {id})?.wallId,
          'door-$id-spun',
        );
        for (final t in [0.2, 0.8]) {
          final gap = line.$1 + across * t;
          final hit = _ray(model, from, gap, changed: {id});
          expect(
            hit?.distance ?? 60,
            greaterThan((from - gap).distance + 1),
            reason: 'gap at $t stopped at ${hit?.wallId}',
          );
        }
      });
    }
  });

  group('nobody moves', () {
    for (final map in [MapValue.lotus, MapValue.summit]) {
      test('${map.name}: door walls change no standing spot or level', () {
        final bare = _model(map, true, doors: false);
        final withDoors = _model(map, true);
        final box = Maps.mapViewBox[map]!;
        for (var x = 2.0; x < box.width; x += 7) {
          for (var y = 2.0; y < box.height; y += 7) {
            final point = Offset(x, y);
            expect(
              withDoors.standablePointNear(point),
              bare.standablePointNear(point),
              reason: '$point',
            );
            expect(
              withDoors.automaticSupportAt(point)?.id,
              bare.automaticSupportAt(point)?.id,
              reason: '$point',
            );
          }
        }
      });

      for (final isAttack in [true, false]) {
        test(
            '${map.name} ${isAttack ? 'attack' : 'defense'} '
            "has no sightline floors a door would have to shadow", () {
          expect(_model(map, isAttack).hasSightlineFloors, isFalse);
        });
      }
    }
  });

  test('an eye inside a bar ignores that door and still sees', () {
    final door = mapDoors.firstWhere((door) => door.id == 'lotus-a');
    final model = _model(MapValue.lotus, true);
    final line = _lineInModel(door, true);
    final middle = (line.$1 + line.$2) / 2;
    expect(model.receiverContains(middle), isTrue);

    final cone = model.horizontalCone(
      origin: middle,
      directionRadians: 1.57,
      range: 40,
      apertureRadians: 1.8,
      supportId: model.automaticSupportAt(middle)?.id,
    );

    expect(cone.polygon.length, greaterThan(3));
  });

  test('a door state left by one query does not reach the next', () {
    final door = mapDoors.firstWhere((door) => door.id == 'lotus-a');
    final model = _model(MapValue.lotus, true);
    final line = _lineInModel(door, true);
    final from = _spotBeside(model, line, 1, distance: 16);
    final middle = (line.$1 + line.$2) / 2;

    final closed = _ray(model, from, middle)!.wallId;
    final spun = _ray(model, from, middle, changed: {door.id})!.wallId;
    final closedAgain = _ray(model, from, middle)!.wallId;

    expect(closed, 'door-lotus-a-closed');
    expect(spun, 'door-lotus-a-spun');
    expect(closedAgain, closed);
  });

  test('the cone cache asks again when a door changes', () {
    final door = mapDoors.firstWhere((door) => door.id == 'lotus-a-link');
    final model = _model(MapValue.lotus, true);
    final cache = SvgHeightConeCache(model);
    final line = _lineInModel(door, true);
    final from = _spotBeside(model, line, 1);
    final toward = (line.$1 + line.$2) / 2 - from;
    SvgCachedCone cone(Set<String> changed) => cache.cone(
          observerId: 'agent',
          origin: from,
          directionRadians: math.atan2(toward.dy, toward.dx),
          range: 40,
          apertureRadians: 0.6,
          supportId: model.automaticSupportAt(from)?.id,
          changedDoors: changed,
        );

    final rest = cone(const {});
    expect(cone(const {}).reused, isTrue);

    final broken = cone({door.id});
    expect(broken.reused, isFalse);
    expect(broken.cone.polygon, isNot(rest.cone.polygon));
    expect(cone({door.id}).reused, isTrue);
  });

  test('a map without doors adds no walls', () {
    for (final map in MapValue.values) {
      if (map == MapValue.lotus || map == MapValue.summit) continue;
      expect(mapDoorWalls(map, isAttack: true), isEmpty, reason: map.name);
    }
  });

  test('the native query and the Dart one agree on every door state', () {
    final library = Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'];
    if (library == null) {
      markTestSkipped('Set ICARUS_SVG_NATIVE_LIBRARY to icarus_height.dll.');
      return;
    }
    for (final map in [MapValue.lotus, MapValue.summit]) {
      final json = _json(map, true);
      final walls = mapDoorWalls(map, isAttack: true);
      final dart = SvgHeightVisibility.fromJson(json, doorWalls: walls);
      final native = SvgHeightVisibility.fromJson(json, doorWalls: walls);
      expect(native.enableNativeAcceleration(libraryPath: library), isTrue);
      addTearDown(native.closeNativeAcceleration);
      final doors = mapDoorsOf(map).map((door) => door.id).toList();
      for (final changed in [
        <String>{},
        {doors.first},
        doors.toSet(),
      ]) {
        for (final door in mapDoorsOf(map)) {
          final line = _lineInModel(door, true);
          final from = _spotBeside(dart, line, 1);
          final toward = (line.$1 + line.$2) / 2 - from;
          final support = dart.automaticSupportAt(from)?.id;
          List<Offset> outline(SvgHeightVisibility model) => model
              .horizontalCone(
                origin: from,
                directionRadians: math.atan2(toward.dy, toward.dx),
                range: 50,
                apertureRadians: 1.2,
                supportId: support,
                changedDoors: changed,
              )
              .polygon;
          final fromDart = outline(dart), fromNative = outline(native);
          expect(fromNative.length, fromDart.length, reason: '$changed');
          for (var i = 0; i < fromDart.length; i++) {
            expect(
              (fromNative[i] - fromDart[i]).distance,
              lessThan(1e-5),
              reason: '$changed point $i',
            );
          }
        }
      }
    }
  });
}
