import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'random_page_server.dart';

ShownRow _loaded(ShownRow row) => ShownRow(
  page: row.page,
  revision: row.revision,
  digest: row.digest,
  life: row.life,
);

Shown fromScratch(Shown shown) => Shown(
  strategy: switch (shown.strategy) {
    final row? => _loaded(row),
    null => null,
  },
  pages: {
    for (final MapEntry(:key, :value) in shown.pages.entries)
      key: _loaded(value),
  },
  settings: {
    for (final MapEntry(:key, :value) in shown.settings.entries)
      key: _loaded(value),
  },
  content: shown.content,
  rows: {
    for (final MapEntry(:key, :value) in shown.rows.entries)
      key: _loaded(value),
  },
  list: shown.list,
  pageReads: shown.pageReads,
  goneThisSession: shown.goneThisSession,
  highest: shown.highest,
  fresh: shown.fresh,
  listTaken: shown.listTaken,
  pagesTaken: shown.pagesTaken,
  fence: shown.fence,
);

Map<String, int> runSeed(int seed, int steps) {
  final server = RandomServer(Random(seed));
  var cached = Shown.nothing;
  var scratch = Shown.nothing;
  for (var step = 0; step < steps; step++) {
    if (server.random.nextBool()) server.change();
    final read = server.read();
    cached = cached.take(read, started: null);
    scratch = fromScratch(scratch).take(read, started: null);
    if (cached != scratch) {
      fail(
        'seed $seed step $step: taking ${read.page.publicId} with this '
        'run\'s digests differs from taking it from scratch',
      );
    }
    for (final MapEntry(key: target, value: row) in cached.rows.entries) {
      expect(row.digestedThisRun, isTrue, reason: 'seed $seed $target');
    }
  }
  return server.reached;
}

void main() {
  final environment = Platform.environment;
  final seeds = int.tryParse(environment['SHOWN_MODEL_SEEDS'] ?? '') ?? 300;
  final steps = int.tryParse(environment['SHOWN_MODEL_STEPS'] ?? '') ?? 120;

  test('a page taken with this run\'s digests is the page taken from '
      'scratch, whatever the server did between results', () {
    final checked = shownTakesChecked;
    shownTakesChecked = false;
    addTearDown(() => shownTakesChecked = checked);
    final reached = <String, int>{};
    for (var seed = 1; seed <= seeds; seed++) {
      for (final MapEntry(:key, :value) in runSeed(seed, steps).entries) {
        reached[key] = (reached[key] ?? 0) + value;
      }
    }
    for (final what in const [
      'payload changed',
      'moved between pages',
      'deleted',
      'restored',
      'life changed at the same revision',
      'reordered',
      'page trashed or restored',
      'stale read',
      'rows left out of a read',
    ]) {
      expect(reached[what] ?? 0, greaterThan(100), reason: what);
    }
  });
}
