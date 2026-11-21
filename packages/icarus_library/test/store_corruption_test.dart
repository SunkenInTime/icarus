import 'dart:convert';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

const _secondId = 'strategy-2';

typedef View = Map<String, String>;

Object? _normal(Object? json) => switch (json) {
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

String _find<T>(Iterable<T> rows, bool Function(T row) named) {
  for (final row in rows) {
    if (named(row)) return _classify(row!);
  }
  return 'missing';
}

Future<View> viewOf(
  LibraryStore store,
  Map<String, StrategyRowSet> strategies,
  List<String> folders,
) async {
  final view = <String, String>{};
  final list = listOf(store);
  for (final folder in folders) {
    view['folder $folder'] = _find(
      list.folders,
      (row) => row.publicId == folder || row.publicId == folderName(folder),
    );
  }
  for (final summary in list.strategies) {
    view['summary ${summary.publicId}'] = _canon(summary.toJson());
  }
  for (final MapEntry(key: id, value: rows) in strategies.entries) {
    final content = strategyOf(await store.readStrategy(id));
    view['$id strategy'] = _classify(content.strategy);
    for (final page in rows.pages) {
      final pageId = page.publicId;
      view['$id page $pageId'] = _find(
        content.pages,
        (row) => row.publicId == pageId || row.publicId == pageName(pageId),
      );
      view['$id settings $pageId'] = _find(
        content.settings.values,
        (row) =>
            row.pagePublicId == pageId ||
            row.pagePublicId == settingsName(pageId),
      );
      final onPage = pageOf(await store.readPage(id, pageId));
      for (final element in rows.elements.where(
        (row) => row.pagePublicId == pageId,
      )) {
        view['$id element ${element.publicId}'] = _find(
          onPage.elements,
          (row) =>
              row.publicId == element.publicId ||
              row.publicId == elementName(pageId, element.publicId),
        );
      }
      for (final group in rows.lineupGroups.where(
        (row) => row.pagePublicId == pageId,
      )) {
        view['$id lineup ${group.publicId}'] = _find(
          onPage.lineupGroups,
          (row) =>
              row.publicId == group.publicId ||
              row.publicId == lineupName(pageId, group.publicId),
        );
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

typedef Corruption = ({String name, String text, List<String> allowed});

const _anything = <String>[];

const _unreadable = ['unreadable'];

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

const _numbers = [
  '1e400',
  '-1e400',
  '9223372036854775808',
  '-9223372036854775809',
  '123456789012345678901234567890',
  '1e308',
];

List<Corruption> corruptionsOf(String text, Random random) {
  final json = jsonDecode(text);
  final corruptions = <Corruption>[
    (name: 'empty', text: '', allowed: _unreadable),
    (
      name: 'cut at a third',
      text: text.substring(0, text.length ~/ 3),
      allowed: _unreadable,
    ),
    (
      name: 'cut before the end',
      text: text.substring(0, text.length - 1),
      allowed: _unreadable,
    ),
    (
      name: 'arbitrary characters',
      text: String.fromCharCodes([
        for (var i = 0; i < 40; i++) random.nextInt(0x10000),
      ]),
      allowed: _unreadable,
    ),
    (
      name: 'nested too deep',
      text: '${'[' * 300}$text${']' * 300}',
      allowed: _unreadable,
    ),
  ];
  for (final (at, value) in _positions(json, const [])) {
    final opaque = at.length >= 2 && at[0] == 'payload' && at[1] == 'data';
    final where = at.isEmpty ? 'the row' : at.join('/');
    for (final other in _otherTypes(value)) {
      if (at.isEmpty && other is Map) continue;
      corruptions.add((
        name: '$where as ${jsonEncode(other)}',
        text: jsonEncode(_replaced(json, at, other)),
        allowed: opaque
            ? _anything
            : [
                'unreadable',
                if (other == null && at.isNotEmpty && at.last is String)
                  _canon(_without(json, at)),
              ],
      ));
    }
    if (value is num) {
      final template = jsonEncode(_replaced(json, at, _marker));
      for (final number in _numbers) {
        corruptions.add((
          name: '$where as $number',
          text: template.replaceFirst('"$_marker"', number),
          allowed: switch (number) {
            _ when opaque => _anything,
            '1e400' || '-1e400' => _unreadable,
            _ => [
              'unreadable',
              _canon(jsonDecode(template.replaceFirst('"$_marker"', number))),
            ],
          },
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
    baseline = await viewOf(await openOn(populated), fixture, folderIds);
  });

  test(
    'every corruption of a stored row leaves that row unreadable and the rest as they were',
    () async {
      final random = Random(624);
      var cases = 0;
      for (final MapEntry(key: area, value: values) in populated.entries) {
        for (final MapEntry(:key, :value) in values.entries) {
          final viewKey = rowAt[(area, key)];
          if (viewKey == null) continue;
          for (final corruption in corruptionsOf(value, random)) {
            cases++;
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
            for (final MapEntry(key: row, value: before) in baseline.entries) {
              final now = view[row];
              if (row == viewKey && !row.startsWith('summary')) {
                if (corruption.allowed.isNotEmpty) {
                  expect(corruption.allowed, contains(now), reason: where);
                }
                continue;
              }
              expect(now, before, reason: '$where changed $row');
            }
            for (final id in [strategyId, _secondId]) {
              final rebuilt = await store.rebuildSummary(id);
              expect(
                rebuilt,
                isNot(isA<NotSaved<StrategySummary, CommitRefusal>>()),
                reason: where,
              );
            }
            final damaged = viewKey.split(' ').first;
            final kind = viewKey.split(' ')[1];
            if (view[viewKey] == 'unreadable' &&
                fixture.containsKey(damaged) &&
                kind != 'strategy') {
              final summary = listOf(
                store,
              ).strategies.firstWhere((summary) => summary.publicId == damaged);
              expect(
                summary.readability,
                isA<SomeUnreadable>(),
                reason: '$where: the summary does not say a row is unreadable',
              );
            }
          }
        }
      }
      expect(cases, greaterThan(500));
    },
  );

  test('a last-save slot holding anything still lets the store open', () async {
    final readings = <String, int?>{
      '1': 1,
      '42': 42,
      '9007199254740991': 9007199254740991,
      '9007199254740992': null,
      '0': null,
      '-3': null,
      '042': null,
      '+5': null,
      ' 5': null,
      '5.0': null,
      '': null,
      'x': null,
      '1e400': null,
      '{}': null,
      'a' * 32: null,
      '[' * 20000: null,
    };
    for (final MapEntry(key: text, value: attempt) in readings.entries) {
      final opening = await LibraryStore.open(
        MemoryEngine(
          MemoryStorage({
            ...populated,
            'library': {...populated['library']!, 'last-save': text},
          }),
        ),
        canRead: readsKnownKinds,
      );
      expect(
        opening,
        isA<StoreOpened>().having(
          (opened) => opened.lastSave,
          'last save',
          switch (attempt) {
            final attempt? => isA<LastSaveWas>().having(
              (was) => was.attempt,
              'attempt',
              attempt,
            ),
            null => isA<LastSaveUnreadable>().having(
              (unreadable) => unreadable.text,
              'text',
              text,
            ),
          },
        ),
        reason: text.length > 40 ? text.substring(0, 40) : text,
      );
    }
  });

  test('a folder of 20,000 nested arrays is read as unreadable', () async {
    final store = await openOn({
      ...populated,
      'library': {
        ...populated['library']!,
        folderName('f-root'): '${'[' * 20000}${']' * 20000}',
      },
    });
    expect(
      listOf(
        store,
      ).folders.firstWhere((folder) => folder.publicId != 'f-child'),
      isA<UnreadableFolder>(),
    );
  });
}
