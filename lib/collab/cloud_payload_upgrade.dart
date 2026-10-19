import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/migrations/custom_circle_box_migration.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';

/// The payload version of an ability row holding a Paranoia drawn at its
/// in-game size (data version 104). Every row other than these and custom
/// circles stays at [currentCloudPayloadVersion]: nothing else changed
/// shape.
///
/// A Paranoia ability row below this version was written by a client that
/// drew the old 25 m Paranoia. It is corrected as it is read, never
/// rewritten on the server, so every client reads it the same way until
/// someone edits it.
///
/// Lineup rows are never corrected. The lineup group row (protocol 5) came
/// after the Paranoia correction, so every lineup row holds its Paranoia at
/// the in-game size already; correcting one would move it twice. Lineups
/// hold no custom circles.
const paranoiaCloudPayloadVersion = 2;

/// The payload version of a utility row holding a custom circle placed in
/// the box of the largest circle, 110 m (data version 104). A custom circle
/// row below this version was placed in the old 40 m box and is corrected as
/// it is read, as Paranoias are.
///
/// Circles around an agent are agent rows saved by the agent's position, so
/// they never change.
const customCircleCloudPayloadVersion = 3;

/// The newest payload version this build reads.
const newestReadableCloudPayloadVersion = customCircleCloudPayloadVersion;

/// Element [payload] as this build draws it on [map]: a Paranoia at its
/// in-game size, a custom circle in the 110 m box. Payloads already
/// corrected, and every other row, come back as they are.
CloudPayload upgradeCloudPayload(CloudPayload payload, MapValue map) {
  final data = payload['data'];
  if (data is! Map<String, dynamic>) return payload;
  final kind = payload['kind'];
  if (kind is! String) return payload;
  final correctedVersion = cloudPayloadVersionFor(kind, data);
  if (correctedVersion == currentCloudPayloadVersion) return payload;
  final version = payload['payloadVersion'];
  if (version is num && version >= correctedVersion) return payload;
  final upgraded = kind == 'ability'
      ? _upgradeAbilityJson(data, map)
      : _upgradeCustomCircleJson(data, map);
  if (identical(upgraded, data)) return payload;
  return {
    ...payload,
    'payloadVersion': correctedVersion,
    'data': upgraded,
  };
}

/// The version a client writes element [data] of [kind] at.
int cloudPayloadVersionFor(String kind, Map<String, dynamic> data) {
  return switch (kind) {
    'ability' when _isParanoiaJson(data) => paranoiaCloudPayloadVersion,
    'utility' when _isCustomCircleJson(data) => customCircleCloudPayloadVersion,
    _ => currentCloudPayloadVersion,
  };
}

/// [page] of a strategy on the map named [mapData], as this build draws it.
RemotePageSnapshot upgradeRemotePageSnapshot(
  RemotePageSnapshot page,
  String mapData,
) {
  final map = _mapValueOrNull(mapData);
  if (map == null) return page;
  return RemotePageSnapshot(
    page: page.page,
    content: page.content,
    elements: [for (final e in page.elements) _upgradeElement(e, map)],
    lineups: page.lineups,
    assetsById: page.assetsById,
    fromCopy: page.fromCopy,
    copiedAt: page.copiedAt,
    serverAnswer: page.serverAnswer,
    madeHere: page.madeHere,
  );
}

/// [snapshot] as this build draws it.
RemoteFullStrategySnapshot upgradeRemoteFullSnapshot(
  RemoteFullStrategySnapshot snapshot,
) {
  final map = _mapValueOrNull(snapshot.header.mapData);
  if (map == null) return snapshot;
  return RemoteFullStrategySnapshot(
    header: snapshot.header,
    pages: snapshot.pages,
    elementsByPage: {
      for (final MapEntry(:key, :value) in snapshot.elementsByPage.entries)
        key: [for (final e in value) _upgradeElement(e, map)],
    },
    lineupsByPage: snapshot.lineupsByPage,
    assetsById: snapshot.assetsById,
    serverAnswer: snapshot.serverAnswer,
  );
}

RemoteElement _upgradeElement(RemoteElement element, MapValue map) {
  final payload = upgradeCloudPayload(element.payload, map);
  if (identical(payload, element.payload)) return element;
  return RemoteElement(
    publicId: element.publicId,
    strategyPublicId: element.strategyPublicId,
    pagePublicId: element.pagePublicId,
    elementType: element.elementType,
    payload: payload,
    sortIndex: element.sortIndex,
    revision: element.revision,
    deleted: element.deleted,
  );
}

/// A map this build does not know cannot be drawn, so its rows stay as the
/// server holds them.
MapValue? _mapValueOrNull(String wireName) {
  for (final entry in Maps.mapNames.entries) {
    if (entry.value == wireName) return entry.key;
  }
  return null;
}

bool _isParanoiaJson(Map<String, dynamic> ability) {
  final info = ability['data'];
  return info is Map &&
      info['type'] == AgentType.omen.name &&
      info['index'] == 1;
}

bool _isCustomCircleJson(Map<String, dynamic> utility) {
  try {
    return PlacedUtility.fromJson(utility).type == UtilityType.customCircle;
  } on Object {
    return false;
  }
}

/// [utility], a custom circle, with only its position moved into the 110 m
/// box.
Map<String, dynamic> _upgradeCustomCircleJson(
  Map<String, dynamic> utility,
  MapValue map,
) {
  final moved = CustomCircleBoxMigration.migrateUtility(
    PlacedUtility.fromJson(utility),
    map,
  );
  return {...utility, 'position': moved.toJson()['position']};
}

/// [ability] with only its position moved, or [ability] itself when it is
/// not a Paranoia. A Paranoia this build cannot read is left as it is;
/// hydration skips it the same way.
Map<String, dynamic> _upgradeAbilityJson(
  Map<String, dynamic> ability,
  MapValue map,
) {
  if (!_isParanoiaJson(ability)) return ability;
  final PlacedAbility placed;
  try {
    placed = PlacedAbility.fromJson(ability);
  } on Object {
    return ability;
  }
  final moved = ParanoiaRangeMigration.migrateAbility(placed, map);
  return {...ability, 'position': moved.toJson()['position']};
}
