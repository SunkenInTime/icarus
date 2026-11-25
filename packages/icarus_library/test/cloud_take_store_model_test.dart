import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'random_page_server.dart';
import 'store_support.dart';
import 'support.dart';

Future<String> takeInto(
  LibraryStore store,
  ArrivedBase base, {
  required bool reuse,
}) async {
  shownTakesReuse = reuse;
  try {
    final result = await store.record(testAccount, strategyId, [
      BaseArrived(
        base,
        session: await sessionOf(store),
        from: await readStartOf(store),
      ),
    ]);
    return switch (result) {
      Saved(:final value) => [
        for (final outcome in value.outcomes) outcome.runtimeType,
      ].join(', '),
      final other => describeSaving(other),
    };
  } finally {
    shownTakesReuse = true;
  }
}

List<Object?> liveRows(
  Iterable<ElementRow> elements,
  Iterable<LineupGroupRow> lineupGroups,
) => [
  for (final row in <Row>[
    ...elements,
    ...lineupGroups,
  ]..sort((a, b) => '${a.key}'.compareTo('${b.key}')))
    if (row is LiveElement || row is LiveLineupGroup) row.toJson(),
];

Future<void> expectWhatTheServerSent(
  LibraryStore store,
  ArrivedBase base,
  String where,
) async {
  switch (base) {
    case PageRead(:final page, :final elements, :final lineupGroups):
      final stored = pageOf(await store.readPage(strategyId, page.publicId));
      expect(
        liveRows(stored.elements, stored.lineupGroups),
        liveRows(elements, lineupGroups),
        reason: '$where: page ${page.publicId}',
      );
    case PageGone(:final pagePublicId):
      final stored = await store.readPage(strategyId, pagePublicId);
      if (stored case Found(:final value)) {
        expect(
          liveRows(value.elements, value.lineupGroups),
          isEmpty,
          reason: '$where: gone page $pagePublicId',
        );
      }
    case HeaderRead(:final pages):
      final stored = strategyOf(await store.readStrategy(strategyId));
      expect(
        [
          for (final row in stored.pages)
            if (row is LivePage) (row.publicId, row.sortIndex),
        ],
        [
          for (final row in pages)
            if (row is LivePage) (row.publicId, row.sortIndex),
        ],
        reason: '$where: page list',
      );
    case StrategyGone():
      break;
  }
}

String differences(Contents left, Contents right) => [
  for (final area in {...left.keys, ...right.keys})
    for (final key in {...?left[area]?.keys, ...?right[area]?.keys})
      if (left[area]?[key] != right[area]?[key]) '$area $key',
].join('; ');

typedef Counts = ({Map<String, int> applied, Map<String, int> generated});

Future<Counts> runSeed(int seed, int steps) async {
  final server = RandomServer(Random(seed));
  final applied = <String, int>{};
  final reusing = MemoryStorage();
  final fresh = MemoryStorage();
  final stores = [
    await openCloudStore(MemoryEngine(reusing)),
    await openCloudStore(MemoryEngine(fresh)),
  ];
  for (final store in stores) {
    await addCloud(store, server.rows());
  }
  for (var step = 0; step < steps; step++) {
    if (server.random.nextBool()) server.change();
    final result = server.random.nextInt(8) == 0
        ? server.pageList()
        : server.read();
    final queue = (await syncOf(stores.first)).queue;
    final fits = resultFit(
      queue.shown,
      queue.session,
      result.base,
      readFrom(queue),
    );
    final kept = await takeInto(stores.first, result.base, reuse: true);
    final scratch = await takeInto(stores.last, result.base, reuse: false);
    expect(kept, scratch, reason: 'seed $seed step $step');
    if (fits == ResultFit.applies || fits == ResultFit.adopts) {
      for (final what in result.cases) {
        applied[what] = (applied[what] ?? 0) + 1;
      }
      if (!result.cases.contains('stale read')) {
        await expectWhatTheServerSent(
          stores.first,
          result.base,
          'seed $seed step $step',
        );
      }
    }
    final apart = differences(reusing.contents, fresh.contents);
    if (apart.isNotEmpty) {
      fail(
        'seed $seed step $step: the store reusing this run\'s work holds '
        'different rows from the one taking every result from scratch: '
        '$apart',
      );
    }
  }
  for (final store in stores) {
    await store.close();
  }
  return (applied: applied, generated: server.generated);
}

void main() {
  final environment = Platform.environment;
  final seeds = int.tryParse(environment['TAKE_MODEL_SEEDS'] ?? '') ?? 100;
  final steps = int.tryParse(environment['TAKE_MODEL_STEPS'] ?? '') ?? 80;

  test('a store that reuses this run\'s digests and stored rows writes what '
      'a store taking every result from scratch writes', () async {
    final checked = shownTakesChecked;
    shownTakesChecked = false;
    addTearDown(() => shownTakesChecked = checked);
    final applied = <String, int>{};
    final generated = <String, int>{};
    for (var seed = 1; seed <= seeds; seed++) {
      final counts = await runSeed(seed, steps);
      for (final (into, from) in [
        (applied, counts.applied),
        (generated, counts.generated),
      ]) {
        for (final MapEntry(:key, :value) in from.entries) {
          into[key] = (into[key] ?? 0) + value;
        }
      }
    }
    if (environment['TAKE_MODEL_COUNTS'] == '1') {
      for (final what in {...generated.keys, ...applied.keys}) {
        stdout.writeln(
          '$what: ${applied[what] ?? 0} applied of ${generated[what] ?? 0} '
          'generated',
        );
      }
    }
    for (final what in const [
      'payload changed',
      'moved between pages',
      'deleted',
      'restored',
      'life changed at the same revision',
      'reordered',
      'page trashed',
      'page restored',
      'trashed page read',
      'stale read',
      'rows left out of a read',
    ]) {
      expect(applied[what] ?? 0, greaterThan(20), reason: what);
    }
  });
}
