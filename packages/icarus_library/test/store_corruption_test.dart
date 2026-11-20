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

Future<View> viewOf(LibraryStore store, List<String> strategies) async {
  final view = <String, String>{};
  final list = listOf(store);
  for (final folder in list.folders) {
    view['folder ${folder.publicId}'] = _classify(folder);
  }
  for (final summary in list.strategies) {
    view['summary ${summary.publicId}'] = _canon(summary.toJson());
  }
  for (final id in strategies) {
    final content = strategyOf(await store.readStrategy(id));
    view['$id strategy'] = _classify(content.strategy);
    for (final page in content.pages) {
      view['$id page ${page.publicId}'] = _classify(page);
    }
    for (final MapEntry(:key, :value) in content.settings.entries) {
      view['$id settings $key'] = _classify(value);
    }
    for (final page in content.pages) {
      final rows = pageOf(await store.readPage(id, page.publicId));
      for (final row in rows.elements) {
        view['$id element ${row.publicId}'] = _classify(row);
      }
      for (final row in rows.lineupGroups) {
        view['$id lineup ${row.publicId}'] = _classify(row);
      }
    }
  }
  return view;
}

String? _viewKeyOf(String area, String key, Map<String, String> areas) {
  if (area == 'library') {
    if (key.startsWith('folder/')) return 'folder ${key.substring(7)}';
    if (key.startsWith('summary/')) return 'summary ${key.substring(8)}';
    return null;
  }
  final id = areas[area]!;
  if (key == 'strategy') return '$id strategy';
  if (key.startsWith('page/')) return '$id page ${key.substring(5)}';
  if (key.startsWith('settings/')) return '$id settings ${key.substring(9)}';
  final parts = key.split('/');
  if (parts.length == 4 && parts[2] == 'element') {
    return '$id element ${parts[3]}';
  }
  if (parts.length == 4 && parts[2] == 'lineup') {
    return '$id lineup ${parts[3]}';
  }
  return null;
}

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
  late Map<String, String> areas;

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
    areas = {
      strategyArea(strategyId): strategyId,
      strategyArea(_secondId): _secondId,
    };
    baseline = await viewOf(await openOn(populated), [strategyId, _secondId]);
  });

  test(
    'every corruption of a stored row leaves that row unreadable and the rest as they were',
    () async {
      final random = Random(624);
      var cases = 0;
      for (final MapEntry(key: area, value: values) in populated.entries) {
        if (area == 'journal') continue;
        for (final MapEntry(:key, :value) in values.entries) {
          final viewKey = _viewKeyOf(area, key, areas);
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
            final view = await viewOf(store, [strategyId, _secondId]);
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
          }
        }
      }
      expect(cases, greaterThan(500));
    },
  );

  test(
    'every corruption of the saved edit is refused at open, never thrown',
    () async {
      final disk = MemoryStorage(populated);
      final store = await openStore(crashing(MemoryEngine(disk), Cut(1)));
      await store.commit(strategyId, moveJett);
      final record = disk.contents['journal']!['edit']!;
      var refused = 0;
      for (final corruption in corruptionsOf(record, Random(637))) {
        final opening = await LibraryStore.open(
          MemoryEngine(
            MemoryStorage({
              ...disk.contents,
              'journal': {'edit': corruption.text},
            }),
          ),
          canRead: readsKnownKinds,
          clock: fixedClock,
        );
        switch (opening) {
          case StoreNotOpened(problem: SavedEditUnreadable()):
            refused++;
          case StoreOpened():
            break;
          case StoreNotOpened(:final problem):
            fail('${corruption.name}: $problem');
        }
      }
      expect(refused, greaterThan(20));
    },
  );

  test(
    'a recovery marker holding anything still lets the store open',
    () async {
      for (final text in ['', 'x', '1e400', '{}', '-9223372036854775809']) {
        await openOn({
          ...populated,
          'journal': {'recovered/${'a' * 32}': text},
        });
      }
    },
  );
}
