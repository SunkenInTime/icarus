import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/migrations/paranoia_range_migration.dart';

/// The payload version of a row holding a Paranoia, as an ability or a
/// lineup landing, drawn at its in-game size (data version 104). Every other
/// row stays at [currentCloudPayloadVersion]: nothing else changed shape.
///
/// A Paranoia row below this version was written by a client that drew the
/// old 25 m Paranoia. It is corrected as it is read, never rewritten on the
/// server, so every client reads it the same way until someone edits it.
const paranoiaCloudPayloadVersion = 2;

/// [payload] with its Paranoia, if any, at the in-game size on [map].
/// Payloads without a Paranoia, and those already corrected, come back as
/// they are.
CloudPayload upgradeCloudPayload(CloudPayload payload, MapValue map) {
  final version = payload['payloadVersion'];
  if (version is num && version >= paranoiaCloudPayloadVersion) {
    return payload;
  }
  final data = payload['data'];
  if (data is! Map<String, dynamic>) return payload;
  final upgraded = switch (payload['kind']) {
    'ability' => _upgradeAbilityJson(data, map),
    CloudLineupKind.landing => _upgradeLandingJson(data, map),
    _ => data,
  };
  if (identical(upgraded, data)) return payload;
  return {
    ...payload,
    'payloadVersion': paranoiaCloudPayloadVersion,
    'data': upgraded,
  };
}

/// The version a client writes [data] of [kind] at.
int cloudPayloadVersionFor(String kind, Map<String, dynamic> data) {
  final ability = switch (kind) {
    'ability' => data,
    CloudLineupKind.landing => data['ability'],
    _ => null,
  };
  return ability is Map<String, dynamic> && _isParanoiaJson(ability)
      ? paranoiaCloudPayloadVersion
      : currentCloudPayloadVersion;
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
    lineups: [for (final l in page.lineups) _upgradeLineup(l, map)],
    assetsById: page.assetsById,
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
    lineupsByPage: {
      for (final MapEntry(:key, :value) in snapshot.lineupsByPage.entries)
        key: [for (final l in value) _upgradeLineup(l, map)],
    },
    assetsById: snapshot.assetsById,
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

RemoteLineup _upgradeLineup(RemoteLineup lineup, MapValue map) {
  final payload = upgradeCloudPayload(lineup.payload, map);
  if (identical(payload, lineup.payload)) return lineup;
  return RemoteLineup(
    publicId: lineup.publicId,
    strategyPublicId: lineup.strategyPublicId,
    pagePublicId: lineup.pagePublicId,
    payload: payload,
    sortIndex: lineup.sortIndex,
    revision: lineup.revision,
    deleted: lineup.deleted,
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

Map<String, dynamic> _upgradeLandingJson(
  Map<String, dynamic> landing,
  MapValue map,
) {
  final ability = landing['ability'];
  if (ability is! Map<String, dynamic>) return landing;
  final moved = _upgradeAbilityJson(ability, map);
  return identical(moved, ability) ? landing : {...landing, 'ability': moved};
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
