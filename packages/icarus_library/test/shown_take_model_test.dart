import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart'
    show liveContentOn, rowDigest;
import 'package:test/test.dart';

import 'cloud_support.dart';
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
  trashed: {
    for (final MapEntry(:key, :value) in shown.trashed.entries)
      key: _loaded(value),
  },
  tombstones: shown.tombstones,
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
        page is TrashedPage ? isNull : liveContentOn(sent, pageId),
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

void expectNoRowGoesBack(
  Shown before,
  Shown after,
  ArrivedBase base,
  String where,
) {
  bool mayRemove(String page) => switch (base) {
    PageRead(page: final read) => read.publicId == page,
    PageGone(:final pagePublicId) => pagePublicId == page,
    HeaderRead(:final pages) => !pages.any((row) => row.publicId == page),
    StrategyGone() => false,
  };
  for (final MapEntry(key: target, value: was) in before.rows.entries) {
    if (!after.rows.containsKey(target)) {
      expect(
        mayRemove(was.page),
        isTrue,
        reason: '$where: $target left without a result of its page',
      );
    }
    if ((was.version, after.rows[target]?.version) case (
      final was?,
      final now?,
    )) {
      expect(now < was, isFalse, reason: '$where: $target went back');
    }
  }
}

String? decisionCase(RowDecision decision) => switch (decision) {
  RowKept(because: KeptBecause.heldIsNewer) => 'kept: the held row is newer',
  RowKept(because: KeptBecause.leftByANewerResult) =>
    'kept out: removed by a newer result',
  ItemLeft() => 'item left',
  PageLeft() => 'page left',
  RowUnchanged() => 'unchanged',
  _ => null,
};

Map<String, int> runSeed(int seed, int steps) {
  final observed = Observed();
  final server = RandomServer(Random(seed));
  final delivered = <String, int>{};
  void count(String what) => delivered[what] = (delivered[what] ?? 0) + 1;
  var cached = Shown.nothing;
  var scratch = Shown.nothing;
  var lastPage = 0;
  var lastList = 0;
  Arrival? lastFresh;
  final firstStart = <int, Arrival>{};
  for (var step = 0; step < steps; step++) {
    final where = 'seed $seed step $step';
    if (server.random.nextBool()) server.change();
    final result = server.random.nextInt(6) == 0
        ? server.pageList()
        : server.read();
    final tie =
        !result.stale && lastFresh != null && server.random.nextInt(5) == 0;
    final started = firstStart[result.read] ??= tie
        ? lastFresh
        : arrivalAt(result.read * 2);
    if (!result.stale) lastFresh = started;
    if (tie) count('started with the read before it');
    if (cached.takenFor(result.base) case final mark?
        when started.order.isBefore(mark.order)) {
      count('dropped as older');
      continue;
    }
    switch (result.base) {
      case HeaderRead() when result.stale && lastPage > result.read:
        count('older list after a newer page');
      case PageRead() when result.stale && lastList > result.read:
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
    final before = cached;
    final taken = cached.taken(result.base, arrival: started);
    final fromNothing = fromScratch(
      scratch,
    ).taken(result.base, arrival: started);
    if (taken.shown != fromNothing.shown) {
      fail(
        '$where: taking ${result.base} with this run\'s digests differs '
        'from taking it from scratch',
      );
    }
    expect(taken.decisions, fromNothing.decisions, reason: where);
    cached = taken.shown;
    scratch = fromNothing.shown;
    for (final what in result.cases) {
      count(what);
    }
    observed.see(result.base);
    for (final decision in taken.decisions) {
      if (decisionCase(decision) case final what?) count(what);
    }
    if (result.stale) {
      expectNoRowGoesBack(before, cached, result.base, where);
    } else {
      expectWhatTheServerSent(cached, result.base, where);
    }
    for (final MapEntry(key: target, value: row) in cached.rows.entries) {
      expect(row.digestedThisRun, isTrue, reason: '$where $target');
    }
  }
  return {...delivered, ...observed.counts};
}

Arrival arrivalAt(int snapshot) => Arrival(
  order: ResultOrder(session: 1, client: testClient, snapshot: snapshot),
  point: ResultPoint(
    client: testClient,
    connection: 1,
    snapshot: snapshot,
    serverTime: snapshot * 1000,
  ),
);

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
      'stale read',
      'rows left out of a read',
      'stale list',
      'purged',
      'added',
      'older list after a newer page',
      'older page after a newer list',
      'started with the read before it',
      'dropped as older',
      'kept: the held row is newer',
      'kept out: removed by a newer result',
      'item left',
      'page left',
      'unchanged',
    ]) {
      expect(delivered[what] ?? 0, greaterThan(100), reason: what);
    }
    if (environment['SHOWN_MODEL_COUNTS'] == '1') {
      for (final MapEntry(:key, :value) in delivered.entries) {
        stdout.writeln('$key: $value');
      }
    }
  });
}
