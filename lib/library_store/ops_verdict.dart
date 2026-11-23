import 'dart:convert';

import 'package:icarus/collab/canonical_json.dart';
import 'package:icarus/library_rows/page_items.dart';
import 'package:icarus/library_store/action_ops.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';

final class ReadBackDifference {
  const ReadBackDifference(this.what, this.id, this.field);

  final String what;
  final String id;
  final String field;

  @override
  String toString() => '$what $id $field';
}

Map<String, Object?> _jsonOf(Object? value) =>
    jsonDecode(jsonEncode(value)) as Map<String, Object?>;

Iterable<String> _fieldsDiffering(
  Map<String, Object?> left,
  Map<String, Object?> right,
) =>
    {...left.keys, ...right.keys}
        .where((key) => !cloudJsonEquivalent(left[key], right[key]));

Map<String, Object?> _itemData(PageItem item) => switch (item.payload) {
      Read(value: final payload) =>
        Map<String, Object?>.from(payload.toJson()['data'] as Map),
      CouldNotRead(:final problem) => {'unencodable': problem},
    };

List<StrategyPage> _ordered(List<StrategyPage> pages) =>
    [...pages]..sort((a, b) => a.sortIndex != b.sortIndex
        ? a.sortIndex.compareTo(b.sortIndex)
        : a.id.compareTo(b.id));

List<ReadBackDifference> readBackDifferences(
  StrategyData expected,
  StrategyData read,
) {
  final differences = <ReadBackDifference>[];
  void differ(String what, String id, String field) =>
      differences.add(ReadBackDifference(what, id, field));

  final strategy = expected.id;
  if (expected.name != read.name) differ('strategy', strategy, 'name');
  if (expected.mapData != read.mapData) differ('strategy', strategy, 'map');
  if (expected.folderID != read.folderID) {
    differ('strategy', strategy, 'folder');
  }
  if (expected.themeProfileId != read.themeProfileId) {
    differ('strategy', strategy, 'themeProfile');
  }
  if (!cloudJsonEquivalent(
    expected.themeOverridePalette?.toJson(),
    read.themeOverridePalette?.toJson(),
  )) {
    differ('strategy', strategy, 'themeOverride');
  }

  final pagesExpected = _ordered(expected.pages);
  final pagesRead = _ordered(read.pages);
  final idsExpected = [for (final page in pagesExpected) page.id];
  final idsRead = [for (final page in pagesRead) page.id];
  for (final id in idsExpected.where((id) => !idsRead.contains(id))) {
    differ('page', id, 'missing');
  }
  for (final id in idsRead.where((id) => !idsExpected.contains(id))) {
    differ('page', id, 'extra');
  }
  final common = [
    for (final id in idsExpected)
      if (idsRead.contains(id)) id
  ];
  final commonRead = [
    for (final id in idsRead)
      if (idsExpected.contains(id)) id
  ];
  if (!_sameOrder(common, commonRead)) differ('pages', strategy, 'order');

  final readById = {for (final page in pagesRead) page.id: page};
  for (final page in pagesExpected) {
    final other = readById[page.id];
    if (other == null) continue;
    if (page.name != other.name) differ('page', page.id, 'name');
    if (page.isAutoNamed != other.isAutoNamed) {
      differ('page', page.id, 'isAutoNamed');
    }
    if (page.isAttack != other.isAttack) differ('page', page.id, 'isAttack');
    for (final field in _fieldsDiffering(
      _jsonOf(page.settings.toJson()),
      _jsonOf(other.settings.toJson()),
    )) {
      differ('page settings', page.id, field);
    }
    _items(page, other, differ);
    _lineups(page, other, differ);
  }
  return differences;
}

bool _sameOrder(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _items(
  StrategyPage expected,
  StrategyPage read,
  void Function(String what, String id, String field) differ,
) {
  final byKind = <String, (List<PageItem>, List<PageItem>)>{};
  for (final item in pageItemsOf(expected)) {
    (byKind[item.kind.name] ??= (<PageItem>[], <PageItem>[])).$1.add(item);
  }
  for (final item in pageItemsOf(read)) {
    (byKind[item.kind.name] ??= (<PageItem>[], <PageItem>[])).$2.add(item);
  }
  for (final MapEntry(key: kind, value: (left, right)) in byKind.entries) {
    final leftIds = [for (final item in left) item.id];
    final rightIds = [for (final item in right) item.id];
    for (final id in leftIds.where((id) => !rightIds.contains(id))) {
      differ(kind, id, 'missing');
    }
    for (final id in rightIds.where((id) => !leftIds.contains(id))) {
      differ(kind, id, 'extra');
    }
    final common = [
      for (final id in leftIds)
        if (rightIds.contains(id)) id
    ];
    final commonRight = [
      for (final id in rightIds)
        if (leftIds.contains(id)) id,
    ];
    if (!_sameOrder(common, commonRight)) {
      differ('$kind list', expected.id, 'order');
    }
    final rightById = {for (final item in right) item.id: item};
    for (final item in left) {
      final other = rightById[item.id];
      if (other == null) continue;
      for (final field in _fieldsDiffering(_itemData(item), _itemData(other))) {
        differ(kind, item.id, field);
      }
    }
  }
}

void _lineups(
  StrategyPage expected,
  StrategyPage read,
  void Function(String what, String id, String field) differ,
) {
  void compare(
    String what,
    Iterable<(String, Map<String, Object?>)> left,
    Iterable<(String, Map<String, Object?>)> right,
  ) {
    final rightById = {for (final (id, json) in right) id: json};
    final leftIds = {for (final (id, _) in left) id};
    for (final (id, json) in left) {
      final other = rightById[id];
      if (other == null) {
        differ(what, id, 'missing');
        continue;
      }
      for (final field in _fieldsDiffering(json, other)) {
        differ(what, id, field);
      }
    }
    for (final id in rightById.keys.where((id) => !leftIds.contains(id))) {
      differ(what, id, 'extra');
    }
  }

  final groupsExpected = _groupParts(expected);
  final groupsRead = _groupParts(read);
  final commonGroups = [
    for (final id in groupsExpected.keys)
      if (groupsRead.containsKey(id)) id,
  ];
  final commonGroupsRead = [
    for (final id in groupsRead.keys)
      if (groupsExpected.containsKey(id)) id,
  ];
  if (!_sameOrder(commonGroups, commonGroupsRead)) {
    differ('lineup groups', expected.id, 'order');
  }
  for (final id in commonGroups) {
    if (!_sameOrder(groupsExpected[id]!, groupsRead[id]!)) {
      differ('lineup group', id, 'order');
    }
  }
  compare(
    'lineup origin',
    [for (final o in expected.lineUpOrigins) (o.id, _jsonOf(o.toJson()))],
    [for (final o in read.lineUpOrigins) (o.id, _jsonOf(o.toJson()))],
  );
  compare(
    'lineup landing',
    [for (final l in expected.lineUpLandings) (l.id, _jsonOf(l.toJson()))],
    [for (final l in read.lineUpLandings) (l.id, _jsonOf(l.toJson()))],
  );
  compare(
    'lineup link',
    [for (final l in expected.lineUpLinks) (l.id, _jsonOf(l.toJson()))],
    [for (final l in read.lineUpLinks) (l.id, _jsonOf(l.toJson()))],
  );
}

Map<String, List<String>> _groupParts(StrategyPage page) => {
      for (final group in lineupGroupRowsOf(
        strategyId: '',
        pageId: page.id,
        graph: page.lineUpGraph,
        takenGroupIds: {},
        everyLinkId: {for (final link in page.lineUpLinks) link.id},
      ))
        group.publicId: [
          for (final collection in const ['origins', 'landings', 'links'])
            for (final id in idsIn(group.payload.data, collection))
              '$collection/$id',
        ],
    };
