import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _secondId = 'strategy-2';

typedef View = Map<String, String>;

Object? _normal(Object? json) => switch (json) {
  JsonObject() => _normal(json.toJson()),
  JsonList() => _normal(json.toJson()),
  final Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _normal(map[key]),
  },
  final List<Object?> list => [for (final item in list) _normal(item)],
  final double value
      when value == value.truncateToDouble() &&
          value.abs() <= 9007199254740991 =>
    value.toInt(),
  _ => json,
};

String _canon(Object? json) => jsonEncode(_normal(json));

String _classify(Object row) => switch (row) {
  UnreadableStrategy() ||
  UnreadableFolder() ||
  UnreadablePage() ||
  UnreadablePageSettings() ||
  UnreadableElement() ||
  UnreadableLineupGroup() => 'unreadable',
  final Row readable => _canon(readable.toJson()),
  _ => fail('not a row: $row'),
};

String _find<T>(
  Iterable<T> rows,
  bool Function(T row) named,
  Set<StoredRowRef> unplaced,
  StoredRowRef ref,
) {
  for (final row in rows) {
    if (named(row)) return _classify(row!);
  }
  return unplaced.contains(ref) ? 'unplaced' : 'missing';
}

Future<View> viewOf(
  LibraryStore store,
  Map<String, StrategyRowSet> strategies,
  List<String> folders,
) async {
  final view = <String, String>{};
  final list = listOf(store);
  final listed = {
    for (final summary in list.strategies)
      summary.publicId: _canon(summary.toJson()),
  };
  for (final id in strategies.keys) {
    view['summary $id'] = listed[id] ?? 'missing';
  }
  final libraryUnplaced = {for (final row in list.unplaced) row.ref};
  for (final folder in folders) {
    view['folder $folder'] = _find(
      list.folders,
      (row) => row.publicId == folder,
      libraryUnplaced,
      StoredRowRef('library', folderName(folder)),
    );
  }
  for (final MapEntry(key: id, value: rows) in strategies.entries) {
    final area = strategyArea(id);
    final content = strategyOf(await store.readStrategy(id));
    final unplaced = {for (final row in content.unplaced) row.ref};
    view['$id strategy'] = _classify(content.strategy);
    for (final page in rows.pages) {
      final pageId = page.publicId;
      view['$id page $pageId'] = _find(
        content.pages,
        (row) => row.publicId == pageId,
        unplaced,
        StoredRowRef(area, pageName(pageId)),
      );
      view['$id settings $pageId'] = _find(
        content.settings.values,
        (row) => row.pagePublicId == pageId,
        unplaced,
        StoredRowRef(area, settingsName(pageId)),
      );
      final elementsHere = rows.elements.where(
        (row) => row.pagePublicId == pageId,
      );
      final groupsHere = rows.lineupGroups.where(
        (row) => row.pagePublicId == pageId,
      );
      switch (await store.readPage(id, pageId)) {
        case Found(value: final onPage):
          final onPageUnplaced = {for (final row in onPage.unplaced) row.ref};
          for (final element in elementsHere) {
            view['$id element ${element.publicId}'] = _find(
              onPage.elements,
              (row) => row.publicId == element.publicId,
              onPageUnplaced,
              StoredRowRef(area, elementName(pageId, element.publicId)),
            );
          }
          for (final group in groupsHere) {
            view['$id lineup ${group.publicId}'] = _find(
              onPage.lineupGroups,
              (row) => row.publicId == group.publicId,
              onPageUnplaced,
              StoredRowRef(area, lineupName(pageId, group.publicId)),
            );
          }
        case InUnreadableStrategy(:final listing):
          fail('$id is unreadable: ${listing.header}');
        case NotFound():
          for (final element in elementsHere) {
            view['$id element ${element.publicId}'] = 'unreachable';
          }
          for (final group in groupsHere) {
            view['$id lineup ${group.publicId}'] = 'unreachable';
          }
        case NotRead(:final failure):
          fail('$id $pageId: $failure');
      }
    }
  }
  return view;
}

Map<(String, String), String> namesOfRows(
  Map<String, StrategyRowSet> strategies,
  List<String> folders,
) => {
  for (final folder in folders)
    ('library', folderName(folder)): 'folder $folder',
  for (final MapEntry(key: id, value: rows) in strategies.entries) ...{
    ('library', summaryName(id)): 'summary $id',
    (strategyArea(id), 'strategy'): '$id strategy',
    for (final page in rows.pages) ...{
      (strategyArea(id), pageName(page.publicId)): '$id page ${page.publicId}',
      (strategyArea(id), settingsName(page.publicId)):
          '$id settings ${page.publicId}',
    },
    for (final row in rows.elements)
      (strategyArea(id), elementName(row.pagePublicId, row.publicId)):
          '$id element ${row.publicId}',
    for (final row in rows.lineupGroups)
      (strategyArea(id), lineupName(row.pagePublicId, row.publicId)):
          '$id lineup ${row.publicId}',
  },
};

typedef Corruption = ({String name, String text, Outcome outcome});

sealed class Outcome {
  const Outcome();
}

final class Readable extends Outcome {
  const Readable(this.json);

  final Object? json;
}

final class Unreadable extends Outcome {
  const Unreadable({this.newer = false});

  final bool newer;
}

final class NoId extends Outcome {
  const NoId();
}

final class Rebuilt extends Outcome {
  const Rebuilt();
}

enum Field { id, parent, string, whole, number, boolean, object, payload, kept }

const _fields = <String, Map<String, Field>>{
  'folder': {
    'publicId': Field.id,
    'name': Field.string,
    'parentFolderPublicId': Field.string,
  },
  'strategy': {
    'publicId': Field.id,
    'name': Field.string,
    'mapData': Field.string,
    'revision': Field.whole,
    'createdAt': Field.whole,
    'updatedAt': Field.whole,
  },
  'page': {
    'publicId': Field.id,
    'strategyPublicId': Field.parent,
    'name': Field.string,
    'sortIndex': Field.whole,
    'isAttack': Field.boolean,
    'revision': Field.whole,
    'deleted': Field.boolean,
    'createdAt': Field.kept,
  },
  'settings': {
    'pagePublicId': Field.id,
    'revision': Field.whole,
    'settings': Field.object,
    'createdAt': Field.kept,
  },
  'element': {
    'publicId': Field.id,
    'pagePublicId': Field.parent,
    'sortIndex': Field.whole,
    'revision': Field.whole,
    'deleted': Field.boolean,
    'payload': Field.payload,
    'createdAt': Field.kept,
  },
  'lineup': {
    'publicId': Field.id,
    'strategyPublicId': Field.parent,
    'pagePublicId': Field.parent,
    'sortIndex': Field.whole,
    'revision': Field.whole,
    'deleted': Field.boolean,
    'payload': Field.payload,
  },
};

const _optional = {'parentFolderPublicId', 'settings'};

bool _fits(Field field, Object? value) => switch (field) {
  Field.string => value is String,
  Field.whole =>
    value is num &&
        value.abs() <= 9007199254740991 &&
        value == value.roundToDouble(),
  Field.number => value is num,
  Field.boolean => value is bool,
  Field.kept => true,
  Field.id || Field.parent || Field.object || Field.payload => false,
};

Outcome _noId(String kind) =>
    kind == 'strategy' ? const Unreadable() : const NoId();

Outcome _either(bool readable, Object? replaced) =>
    readable ? Readable(replaced) : const Unreadable();

bool _isTime(Object? value) =>
    value is num &&
    value.isFinite &&
    value == value.truncate() &&
    value.abs() <= 8640000000000000;

bool _isTally(Object? json) =>
    json is Map<String, Object?> &&
    _fits(Field.whole, json['items']) &&
    _fits(Field.whole, json['damaged']) &&
    _fits(Field.whole, json['newer']) &&
    json['agents'] is Map<String, Object?> &&
    (json['agents']! as Map<String, Object?>).values.every(
      (count) => _fits(Field.whole, count),
    ) &&
    json['order'] is List<Object?> &&
    (json['order']! as List<Object?>).every((agent) => agent is String);

bool _readsAsSummaryOf(Object? json, Object? id) =>
    json is Map<String, Object?> &&
    json['summaryVersion'] == 6 &&
    json['publicId'] == id &&
    json['name'] is String &&
    json['mapData'] is String &&
    (!json.containsKey('folderPublicId') || json['folderPublicId'] is String) &&
    _isTime(json['createdAt']) &&
    _isTime(json['updatedAt']) &&
    _fits(Field.whole, json['pageCount']) &&
    const ['attack', 'defend', 'mixed'].contains(json['sides']) &&
    json['agents'] is List<Object?> &&
    (json['agents']! as List<Object?>).every((agent) => agent is String) &&
    json['agentsInOrder'] is List<Object?> &&
    (json['agentsInOrder']! as List<Object?>).every(
      (agent) => agent is String,
    ) &&
    (!json.containsKey('firstPageIsAttack') ||
        json['firstPageIsAttack'] is bool) &&
    _fits(Field.whole, json['itemCount']) &&
    _fits(Field.whole, json['damagedRows']) &&
    _fits(Field.whole, json['newerRows']) &&
    _isTally(json['elsewhere']) &&
    json['tallies'] is Map<String, Object?> &&
    (json['tallies']! as Map<String, Object?>).values.every(_isTally);

Outcome expected(String kind, Object? json, List<Object> at, Object? value) {
  final replaced = _replaced(json, at, value);
  if (kind == 'summary') {
    return _readsAsSummaryOf(
          replaced,
          (json! as Map<String, Object?>)['publicId'],
        )
        ? Readable(replaced)
        : const Rebuilt();
  }
  if (at.isEmpty) return _noId(kind);
  final field = _fields[kind]![at.first]!;
  if (at.length == 1) {
    return switch (field) {
      Field.id => _noId(kind),
      Field.parent => const Unreadable(),
      _ when value == null && _optional.contains(at.first) => Readable(
        _without(json, at),
      ),
      _ => _either(_fits(field, value), replaced),
    };
  }
  final rest = at.sublist(1);
  return switch ((kind, rest)) {
    ('settings', ['agentSize' || 'abilitySize']) => _either(
      _fits(Field.number, value),
      replaced,
    ),
    ('settings', ['useNeutralTeamColors']) => _either(
      _fits(Field.boolean, value),
      replaced,
    ),
    ('element', ['kind']) => _either(value == 'text', replaced),
    ('element', ['payloadVersion']) when value == 1 => Readable(replaced),
    ('element', ['payloadVersion']) => Unreadable(newer: value == 7),
    ('element', ['data']) => const Unreadable(),
    ('element', ['data', ...]) => Readable(replaced),
    ('lineup', ['payloadVersion']) when value == 1 => Readable(replaced),
    ('lineup', ['kind'] || ['payloadVersion'] || ['data']) =>
      const Unreadable(),
    ('lineup', ['data', 'id']) => const Unreadable(),
    ('lineup', ['data', 'origins' || 'landings' || 'links']) =>
      const Unreadable(),
    ('lineup', ['data', 'origins' || 'landings' || 'links', _]) =>
      const Unreadable(),
    ('lineup', ['data', 'origins', _, 'id' || 'agent']) => const Unreadable(),
    ('lineup', ['data', 'landings', _, 'id' || 'ability']) =>
      const Unreadable(),
    ('lineup', ['data', 'links', _, 'originId' || 'landingId']) =>
      const Unreadable(),
    ('lineup', ['data', 'links', _, 'notes']) => _either(
      value == null || value is String,
      replaced,
    ),
    ('lineup', ['data', 'links', _, 'id']) => _either(
      value is String,
      replaced,
    ),
    ('lineup', ['data', ...]) => Readable(replaced),
    _ => fail('no expectation for $kind ${at.join('/')}'),
  };
}

Iterable<(List<Object>, Object?)> _positions(
  Object? json,
  List<Object> at,
) sync* {
  yield (at, json);
  switch (json) {
    case final Map<String, Object?> map:
      for (final MapEntry(:key, :value) in map.entries) {
        yield* _positions(value, [...at, key]);
      }
    case final List<Object?> list:
      for (final (index, item) in list.take(2).indexed) {
        yield* _positions(item, [...at, index]);
      }
    case _:
      break;
  }
}

Object? _without(Object? json, List<Object> at) {
  final [first, ...rest] = at;
  return switch (json) {
    final Map<String, Object?> map when rest.isEmpty => {
      for (final MapEntry(:key, :value) in map.entries)
        if (key != first) key: value,
    },
    final Map<String, Object?> map => {
      ...map,
      first as String: _without(map[first], rest),
    },
    final List<Object?> list => [
      for (final (index, item) in list.indexed)
        index == first ? _without(item, rest) : item,
    ],
    _ => json,
  };
}

Object? _replaced(Object? json, List<Object> at, Object? value) {
  if (at.isEmpty) return value;
  final [first, ...rest] = at;
  return switch (json) {
    final Map<String, Object?> map => {
      ...map,
      first as String: _replaced(map[first], rest, value),
    },
    final List<Object?> list => [
      for (final (index, item) in list.indexed)
        index == first ? _replaced(item, rest, value) : item,
    ],
    _ => json,
  };
}

List<Object?> _otherTypes(Object? value) => [
  if (value is! String) 'text',
  if (value is! num) 7,
  if (value is! bool) true,
  if (value != null) null,
  if (value is! List) const <Object?>[],
  if (value is! Map) const <String, Object?>{},
];

const _marker = 'NUMBER_GOES_HERE';

const _unholdable = [
  '1e400',
  '-1e400',
  '1e309',
  '-1.8e308',
  '9223372036854775808',
  '-9223372036854775809',
  '9007199254740993',
  '123456789012345678901234567890',
];

List<Corruption> corruptionsOf(String kind, String text, Random random) {
  final json = jsonDecode(text);
  final whole = kind == 'summary' ? const Rebuilt() : _noId(kind);
  final corruptions = <Corruption>[
    (name: 'empty', text: '', outcome: whole),
    (
      name: 'cut at a third',
      text: text.substring(0, text.length ~/ 3),
      outcome: whole,
    ),
    (
      name: 'cut before the end',
      text: text.substring(0, text.length - 1),
      outcome: whole,
    ),
    (
      name: 'arbitrary characters',
      text: String.fromCharCodes([
        for (var i = 0; i < 40; i++) random.nextInt(0x10000),
      ]),
      outcome: whole,
    ),
    (
      name: 'nested too deep',
      text: '${'[' * 300}$text${']' * 300}',
      outcome: whole,
    ),
  ];
  var longNumbers = true;
  for (final (at, value) in _positions(json, const [])) {
    final where = at.isEmpty ? 'the row' : at.join('/');
    for (final other in _otherTypes(value)) {
      if (at.isEmpty && other is Map) continue;
      corruptions.add((
        name: '$where as ${jsonEncode(other)}',
        text: jsonEncode(_replaced(json, at, other)),
        outcome: expected(kind, json, at, other),
      ));
    }
    if (value is num) {
      final template = jsonEncode(_replaced(json, at, _marker));
      for (final number in _unholdable) {
        corruptions.add((
          name: '$where as $number',
          text: template.replaceFirst('"$_marker"', number),
          outcome: whole,
        ));
      }
      corruptions
        ..add((
          name: '$where as 1e308',
          text: template.replaceFirst('"$_marker"', '1e308'),
          outcome: expected(kind, json, at, 1e308),
        ))
        ..add((
          name: '$where as 1152921504606847000, as JavaScript writes 2^60',
          text: template.replaceFirst('"$_marker"', '1152921504606847000'),
          outcome: expected(kind, json, at, 1152921504606846976.0),
        ));
      if (longNumbers) {
        longNumbers = false;
        corruptions
          ..add((
            name: '$where as 0. and 120,000 zeros, then 1e1100000',
            text: template.replaceFirst(
              '"$_marker"',
              '0.${'0' * 120000}1e1100000',
            ),
            outcome: whole,
          ))
          ..add((
            name: '$where as 1 and 120,000 zeros, then e-120000',
            text: template.replaceFirst(
              '"$_marker"',
              '1${'0' * 120000}e-120000',
            ),
            outcome: whole,
          ))
          ..add((
            name: '$where as 0. and 98 zeros, then 1e1100000',
            text: template.replaceFirst('"$_marker"', '0.${'0' * 98}1e1100000'),
            outcome: whole,
          ))
          ..add((
            name: '$where as 1 and 99 zeros, then e-99',
            text: template.replaceFirst('"$_marker"', '1${'0' * 99}e-99'),
            outcome: expected(kind, json, at, 1.0),
          ))
          ..add((
            name: '$where as 1 and 99 zeros, then e-1100000',
            text: template.replaceFirst('"$_marker"', '1${'0' * 99}e-1100000'),
            outcome: whole,
          ))
          ..add((
            name: '$where as 0. and 93 zeros, then 1e401',
            text: template.replaceFirst('"$_marker"', '0.${'0' * 93}1e401'),
            outcome: whole,
          ))
          ..add((
            name: '$where as 0. and 93 zeros, then 1e400',
            text: template.replaceFirst('"$_marker"', '0.${'0' * 93}1e400'),
            outcome: expected(kind, json, at, 1e306),
          ))
          ..add((
            name: '$where as 1e-401',
            text: template.replaceFirst('"$_marker"', '1e-401'),
            outcome: whole,
          ))
          ..add((
            name: '$where as 1 and 500 zeros, then e-400',
            text: template.replaceFirst('"$_marker"', '1${'0' * 500}e-400'),
            outcome: expected(kind, json, at, 1e100),
          ))
          ..add((
            name: '$where as 1 and 400 zeros, then .0',
            text: template.replaceFirst('"$_marker"', '1${'0' * 400}.0'),
            outcome: whole,
          ))
          ..add((
            name: '$where as 9.99e308',
            text: template.replaceFirst('"$_marker"', '9.99e308'),
            outcome: whole,
          ));
      }
    }
  }
  return corruptions;
}

void main() {
  late Contents populated;
  late View baseline;
  late Map<(String, String), String> rowAt;
  late Map<String, StrategyRowSet> fixture;
  late Map<String, String> baselineSummaries;
  const folderIds = ['f-root', 'f-child'];

  setUpAll(() async {
    final storage = MemoryStorage();
    final store = await openStore(MemoryEngine(storage));
    savedValue(
      await store.editLibrary([
        PutFolder(ReadableFolder(publicId: 'f-root', name: 'Retakes')),
        PutFolder(
          ReadableFolder(
            publicId: 'f-child',
            name: 'Bind',
            parentFolderPublicId: 'f-root',
          ),
        ),
        AddStrategy(sampleStrategy()),
        AddStrategy(sampleStrategy(id: _secondId, prefix: 'x-')),
      ]),
    );
    await store.close();
    populated = storage.contents;
    fixture = {
      strategyId: sampleStrategy(),
      _secondId: sampleStrategy(id: _secondId, prefix: 'x-'),
    };
    rowAt = namesOfRows(fixture, folderIds);
    final first = await openOn(populated);
    baseline = await viewOf(first, fixture, folderIds);
    baselineSummaries = {
      for (final summary in listOf(first).strategies)
        summary.publicId: _canon(summary.toJson()),
    };
  });

  test(
    'every corruption of a stored row reads as stated, and leaves every other row and summary as it was',
    () async {
      final random = Random(624);
      var cases = 0;
      final summaryOutcomes = <Type>{};
      for (final MapEntry(key: area, value: values) in populated.entries) {
        for (final MapEntry(:key, :value) in values.entries) {
          final viewKey = rowAt[(area, key)];
          if (viewKey == null) continue;
          final words = viewKey.split(' ');
          final kind = words.first == 'folder' || words.first == 'summary'
              ? words.first
              : words[1];
          final owner = words.first == 'folder'
              ? null
              : words.first == 'summary'
              ? words[1]
              : words.first;
          for (final corruption in corruptionsOf(kind, value, random)) {
            cases++;
            if (kind == 'summary') {
              summaryOutcomes.add(corruption.outcome.runtimeType);
            }
            final where = '$area $key: ${corruption.name}';
            final opening = await LibraryStore.open(
              MemoryEngine(
                MemoryStorage({
                  ...populated,
                  area: {...values, key: corruption.text},
                }),
              ),
              canRead: readsKnownKinds,
              clock: fixedClock,
            );
            final store = switch (opening) {
              StoreOpened(:final store) => store,
              StoreNotOpened(:final problem) => fail('$where: $problem'),
            };
            final view = await viewOf(store, fixture, folderIds);
            final orphaned = kind == 'page' && corruption.outcome is NoId;
            final unreachable = orphaned
                ? {
                    for (final row in fixture[owner]!.elements)
                      if (row.pagePublicId == words[2])
                        '$owner element ${row.publicId}',
                    for (final row in fixture[owner]!.lineupGroups)
                      if (row.pagePublicId == words[2])
                        '$owner lineup ${row.publicId}',
                  }
                : const <String>{};
            for (final MapEntry(key: row, value: before) in baseline.entries) {
              final now = view[row];
              if (row == viewKey) {
                expect(now, switch (corruption.outcome) {
                  Readable(:final json) => _canon(json),
                  Unreadable() => 'unreadable',
                  NoId() => 'unplaced',
                  Rebuilt() => before,
                }, reason: where);
              } else if (row ==
                      '$owner settings ${words.length > 2 ? words[2] : ''}' &&
                  unreachable.isNotEmpty) {
                expect(now, 'unplaced', reason: '$where: orphaned settings');
              } else if (unreachable.contains(row)) {
                expect(now, 'unreachable', reason: where);
              } else {
                expect(now, before, reason: '$where changed $row');
              }
            }
            final summaries = {
              for (final summary in listOf(store).strategies)
                summary.publicId: summary,
            };
            for (final id in fixture.keys) {
              final ownRowUnreadable =
                  id == owner &&
                  kind == 'strategy' &&
                  corruption.outcome is! Readable;
              expect(
                await store.rebuildSummary(id),
                ownRowUnreadable
                    ? isA<Refused<StrategySummary, CommitRefusal>>()
                    : anyOf(
                        isA<NothingToSave<StrategySummary, CommitRefusal>>(),
                        isA<Saved<StrategySummary, CommitRefusal>>().having(
                          (saved) => _canon(saved.value.toJson()),
                          'rebuilt',
                          _canon(summaries[id]!.toJson()),
                        ),
                      ),
                reason:
                    '$where: rebuilding $id disagrees with the summary its reads kept',
              );
            }
            for (final id in fixture.keys) {
              if (id == owner && kind != 'summary') continue;
              expect(
                _canon(summaries[id]!.toJson()),
                baselineSummaries[id],
                reason: '$where changed the summary of $id',
              );
            }
            if (owner != null && kind != 'summary' && kind != 'strategy') {
              expect(
                summaries[owner]!.readability,
                switch (corruption.outcome) {
                  Readable() || Rebuilt() => isA<AllReadable>(),
                  Unreadable(newer: true) =>
                    isA<SomeUnreadable>()
                        .having((some) => some.damaged, 'damaged', 0)
                        .having((some) => some.newer, 'newer', 1),
                  Unreadable() || NoId() =>
                    isA<SomeUnreadable>()
                        .having(
                          (some) => some.damaged,
                          'damaged',
                          orphaned ? 2 + unreachable.length : 1,
                        )
                        .having((some) => some.newer, 'newer', 0),
                },
                reason: '$where: the summary readability',
              );
            }
          }
        }
      }
      expect(cases, greaterThan(500));
      expect(summaryOutcomes, {Readable, Rebuilt});
    },
  );

  test('a folder of 20,000 nested arrays is read as unreadable', () async {
    final store = await openOn({
      ...populated,
      'library': {
        ...populated['library']!,
        folderName('f-root'): '${'[' * 20000}${']' * 20000}',
      },
    });
    expect(listOf(store).folders.map((folder) => folder.publicId), ['f-child']);
    expect(
      listOf(store).unplaced.single.ref,
      StoredRowRef('library', folderName('f-root')),
    );
  });
}
