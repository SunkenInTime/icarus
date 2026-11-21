import 'dart:convert';

import 'package:icarus/collab/cloud_lineup_rows.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:uuid/uuid.dart';

const _collections = ['origins', 'landings', 'links'];

List<Map<String, Object?>> _items(
        Map<String, Object?> data, String collection) =>
    switch (data[collection]) {
      final List<Object?> items => [
          for (final item in items)
            if (item is Map<String, Object?>) item,
        ],
      _ => const [],
    };

final _clearable = {
  pictureIdField,
  for (final later in laterElementFields) later.field,
};

Object? _keeping(Object? wanted, Object? stored) => switch ((wanted, stored)) {
      (final Map<String, Object?> w, final Map<String, Object?> s) => {
          for (final MapEntry(:key, :value) in w.entries)
            key: _keeping(value, s[key]),
          for (final MapEntry(:key, :value) in s.entries)
            if (!w.containsKey(key) && !_clearable.contains(key)) key: value,
        },
      (final List<Object?> w, final List<Object?> s) => _keepingItems(w, {
          for (final item in s)
            if (item case {'id': final Object id}) id: item,
        }),
      _ => wanted,
    };

List<Object?> _keepingItems(List<Object?> wanted, Map<Object, Object?> byId) =>
    [
      for (final item in wanted)
        if (item case {'id': final Object id})
          _keeping(item, byId[id])
        else
          item,
    ];

String _newId(Set<String> taken, List<Object> seed) {
  for (var attempt = 0;; attempt++) {
    final id = const Uuid().v5(
      Namespace.url.value,
      jsonEncode(['save', ...seed, attempt]),
    );
    if (!taken.contains(id)) return id;
  }
}

List<int> _keptPlaces(Iterable<int?> stored) {
  final places = <int>[];
  int? previous;
  for (final place in stored) {
    final next = place != null && (previous == null || place > previous)
        ? place
        : (previous ?? -1) + 1;
    places.add(next);
    previous = next;
  }
  return places;
}

String? _itemIdOf(ElementPayload payload) => switch (payload.data['id']) {
      final String id => id,
      _ => null,
    };

bool _drawsSame(ElementPayload stored, ElementPayload wanted, MapValue map) {
  if (stored.payloadVersion == wanted.payloadVersion &&
      sameJsonTree(stored.data, wanted.data)) {
    return true;
  }
  return switch (PageItem.decode(stored, map)) {
    Read(value: final item) => switch (item.payload) {
        Read(value: final drawn) =>
          drawn.payloadVersion == wanted.payloadVersion &&
              sameJsonTree(drawn.data, wanted.data),
        CouldNotRead() => false,
      },
    CouldNotRead() => false,
  };
}

ElementPayload _elementKeeping(ElementPayload stored, ElementPayload wanted) =>
    ElementPayload(
      kind: wanted.kind,
      payloadVersion: wanted.payloadVersion,
      data: _keeping(wanted.data.toJson(), stored.data.toJson())!
          as Map<String, Object?>,
      unknownFields: {
        ...stored.unknownFields.toJson(),
        ...wanted.unknownFields.toJson(),
      },
    );

Map<String, Object?> _groupData(LineupGroupPayload payload) =>
    payload.data.toJson();

Map<String, Object?> _drawnGroupData(LiveLineupGroup group) {
  final graph = lineUpGraphFromCloudRows([
    CloudLineupRow(publicId: group.publicId, payload: group.payload.toJson()),
  ]).graph;
  final ids = {
    for (final origin in graph.origins) origin.id: group.publicId,
    for (final landing in graph.landings) landing.id: group.publicId,
    for (final link in graph.links) link.id: group.publicId,
  };
  final row = cloudLineupRows(graph, groupOf: ids).rows.single;
  return Map<String, Object?>.from(row.payload['data'] as Map);
}

Map<String, Object?> _groupKeeping(
  Map<String, Object?> wanted,
  LiveLineupGroup? stored,
  Map<String, Map<Object, Object?>> storedItems,
) =>
    {
      for (final MapEntry(:key, :value) in wanted.entries)
        key: switch (value) {
          final List<Object?> items when storedItems.containsKey(key) =>
            _keepingItems(items, storedItems[key]!),
          _ => value,
        },
      if (stored != null)
        for (final MapEntry(:key, :value) in _groupData(stored.payload).entries)
          if (!wanted.containsKey(key)) key: value,
    };

StrategyToRows strategyToRowsOver(StrategyRowSet stored, StrategyData model) {
  final pageIds = {for (final page in model.pages) page.id};
  final StrategyRowsMade made;
  switch (strategyToRows(
    model,
    carried: [
      for (final row in stored.elements)
        if (row case UnreadableElement(:final pagePublicId)
            when pageIds.contains(pagePublicId))
          row,
    ],
  )) {
    case final StrategyRowsMade converted:
      made = converted;
    case final StrategyRowsRefused refused:
      return refused;
  }
  final map = model.mapData;

  final storedItems = <String, LiveElement>{};
  for (final row in stored.elements) {
    if (row case LiveElement(:final pagePublicId, :final payload)) {
      if (_itemIdOf(payload) case final itemId?) {
        storedItems.putIfAbsent('$pagePublicId/$itemId', () => row);
      }
    }
  }
  final takenElements = {for (final row in stored.elements) row.publicId};
  final elements = <ElementRow>[];
  final storedPlaces = <String, int?>{};
  for (final row in made.rows.elements) {
    switch (row) {
      case LiveElement(:final pagePublicId, :final payload, :final sortIndex):
        final itemId = _itemIdOf(payload)!;
        final match = storedItems.remove('$pagePublicId/$itemId');
        final String id;
        final ElementPayload written;
        if (match != null) {
          id = match.publicId;
          written = _drawsSame(match.payload, payload, map)
              ? match.payload
              : _elementKeeping(match.payload, payload);
        } else {
          id = takenElements.contains(itemId)
              ? _newId(takenElements, [model.id, pagePublicId, itemId])
              : itemId;
          written = payload;
        }
        takenElements.add(id);
        storedPlaces[id] = match?.sortIndex;
        elements.add(
          LiveElement(
            publicId: id,
            pagePublicId: pagePublicId,
            payload: written,
            sortIndex: sortIndex,
            revision: 1,
          ),
        );
      case _:
        elements.add(row);
    }
  }

  final placed = <ElementRow>[];
  final byKind = <String, List<LiveElement>>{};
  for (final row in elements) {
    if (row case LiveElement(:final pagePublicId, :final payload)) {
      (byKind['$pagePublicId/${payload.kind.name}'] ??= []).add(row);
    } else {
      placed.add(row);
    }
  }
  for (final rows in byKind.values) {
    final places = _keptPlaces([
      for (final row in rows) storedPlaces[row.publicId],
    ]);
    for (final (index, row) in rows.indexed) {
      placed.add(row.rewritten(deleted: false, sortIndex: places[index]));
    }
  }

  final takenGroups = {for (final row in stored.lineupGroups) row.publicId};
  final groups = <LineupGroupRow>[
    for (final row in stored.lineupGroups)
      if (row case UnreadableLineupGroup(:final pagePublicId)
          when pageIds.contains(pagePublicId))
        row,
  ];
  for (final page in model.pages) {
    final onPage = [
      for (final row in stored.lineupGroups)
        if (row case LiveLineupGroup(:final pagePublicId)
            when pagePublicId == page.id)
          row,
    ];
    final storedItemsOnPage = <String, Map<Object, Object?>>{
      for (final collection in _collections) collection: {},
    };
    final groupOf = <String, String>{};
    for (final group in onPage) {
      final data = _groupData(group.payload);
      for (final collection in _collections) {
        for (final item in _items(data, collection)) {
          if (item['id'] case final String id) {
            storedItemsOnPage[collection]![id] = item;
            groupOf[id] = group.publicId;
          }
        }
      }
    }
    final rows = cloudLineupRows(
      page.lineUpGraph,
      groupOf: groupOf,
      takenGroupIds: takenGroups,
    ).rows;
    final matches = [
      for (final row in rows)
        onPage.where((group) => group.publicId == row.publicId).firstOrNull,
    ];
    final places = _keptPlaces([for (final match in matches) match?.sortIndex]);
    for (final (index, row) in rows.indexed) {
      final match = matches[index];
      final sortIndex = places[index];
      final data = Map<String, Object?>.from(row.payload['data'] as Map);
      final linkIds = [
        for (final link in _items(data, 'links'))
          if (link['id'] case final String id) id,
      ];
      final groupId = match != null || linkIds.contains(row.publicId)
          ? row.publicId
          : _newId(takenGroups, [model.id, page.id, ...linkIds]);
      takenGroups.add(groupId);
      data['id'] = groupId;
      final LineupGroupPayload payload;
      if (match != null &&
          sameJsonTree(jsonValue(_drawnGroupData(match)), data)) {
        payload = match.payload;
      } else {
        payload = LineupGroupPayload(
          payloadVersion: lineupGroupPayloadVersion,
          data: _groupKeeping(data, match, storedItemsOnPage),
          unknownFields: match?.payload.unknownFields.toJson() ?? const {},
        );
      }
      groups.add(
        LiveLineupGroup(
          publicId: groupId,
          strategyPublicId: model.id,
          pagePublicId: page.id,
          payload: payload,
          sortIndex: sortIndex,
          revision: 1,
        ),
      );
    }
  }

  final settings = [
    for (final row in made.rows.settings)
      switch ((row, stored.settingsOf(row.pagePublicId))) {
        (
          ReadablePageSettings(settings: final wanted?),
          ReadablePageSettings(settings: final have?) && final kept,
        )
            when wanted.agentSize == have.agentSize &&
                wanted.abilitySize == have.abilitySize &&
                wanted.useNeutralTeamColors == have.useNeutralTeamColors =>
          kept,
        _ => row,
      },
  ];

  return StrategyRowsMade(
    rows: StrategyRowSet(
      strategy: made.rows.strategy,
      pages: made.rows.pages,
      settings: settings,
      elements: placed,
      lineupGroups: groups,
    ),
    summary: made.summary,
    supersededLegacyItems: made.supersededLegacyItems,
  );
}
