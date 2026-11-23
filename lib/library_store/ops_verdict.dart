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

enum ImageRowClass {
  number,
  lineupRegrouping,
  headerTime,
  derivedId,
  deletedRow,
  trashedPage,
  real;

  String get words => switch (this) {
        number => 'number only',
        lineupRegrouping => 'lineup regrouping',
        headerTime => 'header time only',
        derivedId => 'duplicate-id derived row',
        deletedRow => 'row the ops deleted',
        trashedPage => 'trashed page or its rows',
        real => 'real',
      };
}

final class ImageRowWrite {
  const ImageRowWrite(this.kind, this.id, this.rowClass, this.fields);

  final String kind;
  final String id;
  final ImageRowClass rowClass;
  final Set<String> fields;

  @override
  String toString() =>
      '$kind $id ${rowClass.words}${fields.isEmpty ? '' : ': ${fields.join(', ')}'}';
}

Set<String> _strategyFields(ReadableStrategy a, ReadableStrategy b) => {
      if (!a.updatedAt.isAtSameMomentAs(b.updatedAt)) 'updatedAt',
      if (!a.createdAt.isAtSameMomentAs(b.createdAt)) 'createdAt',
      if (a.name != b.name) 'name',
      if (a.mapData != b.mapData) 'mapData',
      if (a.folderPublicId != b.folderPublicId) 'folder',
      if (a.themeProfileId != b.themeProfileId) 'themeProfileId',
      if (a.themeOverridePalette != b.themeOverridePalette) 'themeOverride',
    };

Set<String> _pageFields(LivePage a, LivePage b) => {
      if (a.name != b.name) 'name',
      if (a.isAutoNamed != b.isAutoNamed) 'isAutoNamed',
      if (a.isAttack != b.isAttack) 'isAttack',
      if (a.sortIndex != b.sortIndex) 'sortIndex',
    };

Set<String> _payloadFields(
    Map<String, Object?> left, Map<String, Object?> right) {
  final dataLeft = Map<String, Object?>.from(left['data'] as Map? ?? {});
  final dataRight = Map<String, Object?>.from(right['data'] as Map? ?? {});
  return {
    ..._fieldsDiffering(dataLeft, dataRight),
    for (final key in {...left.keys, ...right.keys})
      if (key != 'data' && !cloudJsonEquivalent(left[key], right[key])) key,
  };
}

ImageRowClass _classOf(Set<String> fields, {required String numberField}) =>
    fields.length == 1 && fields.single == numberField
        ? ImageRowClass.number
        : ImageRowClass.real;

List<ImageRowWrite> imageRowWrites(
  StrategyRowSet image,
  StrategyRowSet stored,
) {
  final writes = <ImageRowWrite>[];
  final header = _strategyFields(image.strategy, stored.strategy);
  if (header.isNotEmpty) {
    writes.add(ImageRowWrite(
      'strategy',
      image.strategy.publicId,
      header.length == 1 && header.single == 'updatedAt'
          ? ImageRowClass.headerTime
          : ImageRowClass.real,
      header,
    ));
  }

  final storedPages = {for (final page in stored.pages) page.publicId: page};
  final imagePages = {for (final page in image.pages) page.publicId: page};
  for (final MapEntry(key: id, value: page) in imagePages.entries) {
    final other = storedPages[id];
    if (page is! LivePage) continue;
    if (other is! LivePage) {
      writes.add(ImageRowWrite('page', id, ImageRowClass.real, {'missing'}));
      continue;
    }
    final fields = _pageFields(page, other);
    if (fields.isEmpty) continue;
    writes.add(ImageRowWrite(
      'page',
      id,
      _classOf(fields, numberField: 'sortIndex'),
      fields,
    ));
  }
  for (final MapEntry(key: id, value: page) in storedPages.entries) {
    if (imagePages.containsKey(id)) continue;
    writes.add(ImageRowWrite(
      'page',
      id,
      page is LivePage ? ImageRowClass.real : ImageRowClass.trashedPage,
      {'not in the image'},
    ));
  }

  final storedSettings = {
    for (final row in stored.settings) row.pagePublicId: row,
  };
  for (final row in image.settings) {
    final other = storedSettings[row.pagePublicId];
    if (row is! ReadablePageSettings) continue;
    if (other is ReadablePageSettings && other.settings == row.settings) {
      continue;
    }
    if (other == null && !imagePages.containsKey(row.pagePublicId)) continue;
    writes.add(ImageRowWrite(
      'page settings',
      row.pagePublicId,
      ImageRowClass.real,
      {other == null ? 'missing' : 'settings'},
    ));
  }

  final storedElements = {for (final row in stored.elements) row.publicId: row};
  final imageElements = {for (final row in image.elements) row.publicId: row};
  bool hasTwin(LiveElement row, Map<String, ElementRow> elsewhere) =>
      elsewhere.values.any((other) =>
          other is LiveElement &&
          other.pagePublicId == row.pagePublicId &&
          _sameApartFromId(other.payload, row.payload));
  final storedTwins = {
    for (final MapEntry(:key, :value) in storedElements.entries)
      if (!imageElements.containsKey(key)) key: value,
  };
  final imageTwins = {
    for (final MapEntry(:key, :value) in imageElements.entries)
      if (!storedElements.containsKey(key)) key: value,
  };
  for (final MapEntry(key: id, value: row) in imageElements.entries) {
    if (row is! LiveElement) continue;
    final other = storedElements[id];
    if (other is! LiveElement) {
      writes.add(ImageRowWrite(
        'element',
        id,
        hasTwin(row, storedTwins)
            ? ImageRowClass.derivedId
            : ImageRowClass.real,
        {'missing'},
      ));
      continue;
    }
    final fields = {
      ..._payloadFields(row.payload.toJson(), other.payload.toJson()),
      if (row.sortIndex != other.sortIndex) 'sortIndex',
      if (row.pagePublicId != other.pagePublicId) 'page',
    };
    if (fields.isEmpty) continue;
    writes.add(ImageRowWrite(
      'element',
      id,
      _classOf(fields, numberField: 'sortIndex'),
      fields,
    ));
  }
  final trashedPages = {
    for (final page in stored.pages)
      if (page is TrashedPage) page.publicId,
  };
  for (final MapEntry(key: id, value: row) in storedElements.entries) {
    if (imageElements.containsKey(id)) continue;
    writes.add(ImageRowWrite(
      'element',
      id,
      switch (row) {
        _ when trashedPages.contains(row.pagePublicId) =>
          ImageRowClass.trashedPage,
        LiveElement() when hasTwin(row, imageTwins) => ImageRowClass.derivedId,
        LiveElement() => ImageRowClass.real,
        _ => ImageRowClass.deletedRow,
      },
      {'not in the image'},
    ));
  }

  for (final row in stored.settings) {
    if (trashedPages.contains(row.pagePublicId)) {
      writes.add(ImageRowWrite(
        'page settings',
        row.pagePublicId,
        ImageRowClass.trashedPage,
        {'not in the image'},
      ));
    }
  }
  writes.addAll(_groupWrites(image, stored, trashedPages));
  return writes;
}

bool _sameApartFromId(ElementPayload left, ElementPayload right) {
  Map<String, Object?> withoutId(ElementPayload payload) => {
        ...payload.toJson(),
        'data': {...payload.data.toJson()}..remove('id'),
      };
  return cloudJsonEquivalent(withoutId(left), withoutId(right));
}

Set<String> _linksOf(LineupGroupRow row) => switch (row) {
      LiveLineupGroup(:final payload) => idsIn(payload.data, 'links').toSet(),
      _ => const {},
    };

Map<String, Object?> _partsOf(Iterable<LineupGroupRow> rows) => {
      for (final row in rows)
        if (row case LiveLineupGroup(:final payload))
          for (final collection in const ['origins', 'landings', 'links'])
            if (payload.data[collection] case final Iterable<Object?> parts)
              for (final part in parts)
                if (part case final JsonObject object)
                  if (object['id'] case final String id)
                    '$collection/$id': object.toJson(),
    };

Set<String> _partsDiffering(
  LineupGroupRow row,
  Map<String, Object?> otherSide,
) {
  final own = _partsOf([row]);
  return {
    for (final MapEntry(:key, :value) in own.entries)
      if (!otherSide.containsKey(key) ||
          !cloudJsonEquivalent(otherSide[key], value))
        key,
  };
}

List<ImageRowWrite> _groupWrites(
  StrategyRowSet image,
  StrategyRowSet stored,
  Set<String> trashedPages,
) {
  final writes = <ImageRowWrite>[];
  final storedGroups = {
    for (final row in stored.lineupGroups) row.publicId: row,
  };
  final imageGroups = {
    for (final row in image.lineupGroups) row.publicId: row,
  };
  final storedParts = _partsOf(storedGroups.values);
  final imageParts = _partsOf(imageGroups.values);
  ImageRowWrite regroupedOrReal(
    String id,
    LineupGroupRow row,
    Map<String, Object?> otherSide,
    Set<String> fields,
  ) {
    final differing = _partsDiffering(row, otherSide);
    return ImageRowWrite(
      'lineup group',
      id,
      differing.isEmpty ? ImageRowClass.lineupRegrouping : ImageRowClass.real,
      differing.isEmpty ? fields : differing,
    );
  }

  for (final MapEntry(key: id, value: row) in imageGroups.entries) {
    if (row is! LiveLineupGroup) continue;
    final other = storedGroups[id];
    if (other is! LiveLineupGroup) {
      writes.add(regroupedOrReal(id, row, storedParts, {'missing'}));
      continue;
    }
    final fields = {
      ..._payloadFields(row.payload.toJson(), other.payload.toJson()),
      if (row.sortIndex != other.sortIndex) 'sortIndex',
    };
    if (fields.isEmpty) continue;
    writes.add(_sameSet(_linksOf(row), _linksOf(other))
        ? ImageRowWrite(
            'lineup group',
            id,
            _classOf(fields, numberField: 'sortIndex'),
            fields,
          )
        : regroupedOrReal(id, row, storedParts, fields));
  }
  for (final MapEntry(key: id, value: row) in storedGroups.entries) {
    if (imageGroups.containsKey(id)) continue;
    writes.add(switch (row) {
      _ when trashedPages.contains(row.pagePublicId) => ImageRowWrite(
          'lineup group',
          id,
          ImageRowClass.trashedPage,
          {'not in the image'},
        ),
      LiveLineupGroup() =>
        regroupedOrReal(id, row, imageParts, {'not in the image'}),
      _ => ImageRowWrite(
          'lineup group',
          id,
          ImageRowClass.deletedRow,
          {'not in the image'},
        ),
    });
  }
  return writes;
}

bool _sameSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
