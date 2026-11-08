import 'dart:ui';

import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

/// How far a door's wall runs past its bar into the walls either side, in SVG
/// units, so no ray slips between them.
const _overlap = 0.5;

/// The walls [map]'s doors add to its height model on [isAttack]'s side, in
/// that model's SVG units. A wall that drops or breaks, or a door that shuts,
/// has one: solid when dropped or shut, solid until broken. A door that turns
/// has one for each pose, so a spun door blocks only what it covers and a cone
/// sees past it either side.
List<SvgDoorWall> mapDoorWalls(MapValue map, {required bool isAttack}) => [
      for (final door in mapDoorsOf(map))
        ...switch (door.kind) {
          MapDoorKind.drop || MapDoorKind.shutter => [
              _wall(door, 'dropped', isAttack,
                  changed: 1, solidWhenChanged: true),
            ],
          MapDoorKind.breakable => [
              _wall(door, 'standing', isAttack,
                  changed: 0, solidWhenChanged: false),
            ],
          MapDoorKind.spin => [
              _wall(door, 'closed', isAttack,
                  changed: 0, solidWhenChanged: false),
              _wall(door, 'spun', isAttack, changed: 1, solidWhenChanged: true),
            ],
        },
    ];

SvgDoorWall _wall(
  MapDoor door,
  String pose,
  bool isAttack, {
  required double changed,
  required bool solidWhenChanged,
}) {
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
  final (from, to) = door.worldLine(changed: changed);
  final start = inModel(from), end = inModel(to);
  final along = end - start;
  final direction = along / along.distance;
  final past = direction * _overlap;
  final side = Offset(-direction.dy, direction.dx) *
      (mapDoorBarWorldWidth / transform.scale / 2);
  return SvgDoorWall(
    id: 'door-${door.id}-$pose',
    door: door.id,
    solidWhenChanged: solidWhenChanged,
    ring: [
      start - past + side,
      end + past + side,
      end + past - side,
      start - past - side,
    ],
  );
}
