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
  ArrivedBase base,
  ResultPoint from, {
  required bool reuse,
}) async {
  shownTakesReuse = reuse;
  try {
    final result = await store.record(testAccount, strategyId, [
      arrivedAs(base, session: await sessionOf(store), asked: from),
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
  final observed = Observed();
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
  void count(String what) => applied[what] = (applied[what] ?? 0) + 1;
  final sources = <int, ResultPoint>{};
  final withheld = <(ServerResult, ResultPoint)>[];
  ResultPoint? lastFresh;
  String? lastSubject;
  var lastPage = 0;
  var lastList = 0;
  String? subjectOf(ArrivedBase base) => switch (base) {
    PageRead(:final page) => page.publicId,
    PageGone(:final pagePublicId) => pagePublicId,
    HeaderRead() || StrategyGone() => null,
  };
  for (var step = 0; step < steps; step++) {
    final changed = server.random.nextBool();
    if (changed) server.change();
    final ServerResult result;
    final ResultPoint asked;
    final bool late;
    if (withheld.isNotEmpty && server.random.nextInt(3) == 0) {
      (result, asked) = withheld.removeAt(
        server.random.nextInt(withheld.length),
      );
      late = true;
    } else {
      result = server.random.nextInt(6) == 0
          ? server.pageList()
          : server.read();
      late = false;
      final tie =
          !result.stale &&
          !changed &&
          lastFresh != null &&
          subjectOf(result.base) != lastSubject &&
          server.random.nextInt(5) == 0;
      if (result.stale) {
        asked = sources[result.read]!;
      } else if (tie) {
        asked = lastFresh;
        count('started with the read before it');
      } else {
        asked = tick();
      }
      if (!result.stale) {
        lastFresh = asked;
        lastSubject = subjectOf(result.base);
        sources[result.read] = asked;
        if (server.random.nextInt(5) == 0) {
          withheld.add((result, asked));
          continue;
        }
      }
    }
    final from = [asked, asked];
    final queue = (await syncOf(stores.first)).queue;
    final fits = resultFit(
      queue.shown,
      result.base,
      Arrival(
        order: queue.session.orderOf(from[0]),
        point: from[0],
      ),
    );
    final kept = await takeInto(
      stores.first,
      result.base,
      from[0],
      reuse: true,
    );
    final scratch = await takeInto(
      stores.last,
      result.base,
      from[1],
      reuse: false,
    );
    expect(kept, scratch, reason: 'seed $seed step $step');
    if (fits == ResultFit.older) count('dropped as older');
    if (fits == ResultFit.same) count('the same result again');
    if (fits == ResultFit.applies || fits == ResultFit.adopts) {
      for (final what in result.cases) {
        count(what);
      }
      if (late) {
        count(result.base is HeaderRead ? 'late list' : 'late read');
      }
      observed.see(result.base);
      switch (result.base) {
        case HeaderRead() when late && lastPage > result.read:
          count('older list after a newer page');
        case PageRead() when late && lastList > result.read:
          count('older page after a newer list');
        case _:
          break;
      }
      switch (result.base) {
        case HeaderRead():
          lastList = max(lastList, result.read);
        case PageRead() || PageGone():
          lastPage = max(lastPage, result.read);
        case StrategyGone():
          break;
      }
      if (!result.stale && !late) {
        await expectWhatTheServerSent(
          stores.first,
          result.base,
          'seed $seed step $step',
        );
      }
    }
    await expectAgree(stores.first);
    for (final store in stores) {
      if (await refusedFor(store) case final reason?) {
        fail(
          'seed $seed step $step: the store refused the strategy, and '
          'nothing seeded a disagreement: $reason',
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
  return (
    applied: {...applied, ...observed.counts},
    generated: server.generated,
  );
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
      'an item seen on another page',
      'an item seen with another payload on its page in its life',
      'a trashed page row delivered',
      'deleted',
      'restored',
      'life changed at the same revision',
      'reordered',
      'page trashed',
      'page restored',
      'trashed page read',
      'late read',
      'rows left out of a read',
      'late list',
      'the same result again',
      'purged',
      'added',
      'older list after a newer page',
      'older page after a newer list',
      'started with the read before it',
      'dropped as older',
    ]) {
      expect(applied[what] ?? 0, greaterThan(20), reason: what);
    }
  });
}
