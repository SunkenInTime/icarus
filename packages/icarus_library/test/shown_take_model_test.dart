import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart'
    show liveContentOn, rowDigest;
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

void expectWhatTheServerSent(Shown shown, ArrivedBase base, String where) {
  switch (base) {
    case PageRead(:final page, :final elements, :final lineupGroups):
      final pageId = page.publicId;
      final sent = <Row>[...elements, ...lineupGroups];
      expect(
        shown.content[pageId],
        liveContentOn(sent, pageId),
        reason: '$where: content of $pageId',
      );
      for (final row in sent) {
        final target = switch (row) {
          ElementRow(:final publicId) => ElementTarget(publicId) as Target,
          LineupGroupRow(:final publicId) => LineupTarget(publicId),
          _ => throw StateError('not page content'),
        };
        expect(shown.rows[target]?.page, pageId, reason: '$where: $target');
        expect(
          shown.rows[target]?.digest,
          rowDigest(row),
          reason: '$where: $target',
        );
      }
      final targets = {for (final row in sent) row.key};
      expect(
        [
          for (final MapEntry(:key, :value) in shown.rows.entries)
            if (value.page == pageId) key,
        ].length,
        targets.length,
        reason: '$where: rows shown on $pageId',
      );
    case PageGone(:final pagePublicId):
      expect(shown.content.containsKey(pagePublicId), isFalse, reason: where);
      expect(
        shown.rows.values.where((row) => row.page == pagePublicId),
        isEmpty,
        reason: where,
      );
    case HeaderRead() || StrategyGone():
      break;
  }
}

Map<String, int> runSeed(int seed, int steps) {
  final server = RandomServer(Random(seed));
  final delivered = <String, int>{};
  var cached = Shown.nothing;
  var scratch = Shown.nothing;
  for (var step = 0; step < steps; step++) {
    if (server.random.nextBool()) server.change();
    final result = server.read();
    cached = cached.take(result.base, started: null);
    scratch = fromScratch(scratch).take(result.base, started: null);
    if (cached != scratch) {
      fail(
        'seed $seed step $step: taking ${result.base} with this '
        'run\'s digests differs from taking it from scratch',
      );
    }
    for (final what in result.cases) {
      delivered[what] = (delivered[what] ?? 0) + 1;
    }
    if (!result.cases.contains('stale read')) {
      expectWhatTheServerSent(cached, result.base, 'seed $seed step $step');
    }
    for (final MapEntry(key: target, value: row) in cached.rows.entries) {
      expect(row.digestedThisRun, isTrue, reason: 'seed $seed $target');
    }
  }
  return delivered;
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
    final delivered = <String, int>{};
    for (var seed = 1; seed <= seeds; seed++) {
      for (final MapEntry(:key, :value) in runSeed(seed, steps).entries) {
        delivered[key] = (delivered[key] ?? 0) + value;
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
      expect(delivered[what] ?? 0, greaterThan(100), reason: what);
    }
  });
}
