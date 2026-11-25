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

String differences(Contents left, Contents right) => [
  for (final area in {...left.keys, ...right.keys})
    for (final key in {...?left[area]?.keys, ...?right[area]?.keys})
      if (left[area]?[key] != right[area]?[key]) '$area $key',
].join('; ');

Future<Map<String, int>> runSeed(int seed, int steps) async {
  final server = RandomServer(Random(seed));
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
    final base = server.random.nextInt(8) == 0
        ? headerReadOf(server.rows())
        : server.read();
    final kept = await takeInto(stores.first, base, reuse: true);
    final scratch = await takeInto(stores.last, base, reuse: false);
    expect(kept, scratch, reason: 'seed $seed step $step');
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
  return server.reached;
}

void main() {
  final environment = Platform.environment;
  final seeds = int.tryParse(environment['TAKE_MODEL_SEEDS'] ?? '') ?? 60;
  final steps = int.tryParse(environment['TAKE_MODEL_STEPS'] ?? '') ?? 80;

  test('a store that reuses this run\'s digests and stored rows writes what '
      'a store taking every result from scratch writes', () async {
    final checked = shownTakesChecked;
    shownTakesChecked = false;
    addTearDown(() => shownTakesChecked = checked);
    final reached = <String, int>{};
    for (var seed = 1; seed <= seeds; seed++) {
      for (final MapEntry(:key, :value) in (await runSeed(
        seed,
        steps,
      )).entries) {
        reached[key] = (reached[key] ?? 0) + value;
      }
    }
    for (final what in const [
      'payload changed',
      'moved between pages',
      'deleted',
      'restored',
      'life changed at the same revision',
      'page trashed or restored',
      'stale read',
      'rows left out of a read',
    ]) {
      expect(reached[what] ?? 0, greaterThan(20), reason: what);
    }
  });
}
