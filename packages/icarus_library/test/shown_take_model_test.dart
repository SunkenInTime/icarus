import 'dart:io';
import 'dart:math';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'support.dart';

const _pages = ['page-a', 'page-b', 'page-c'];

final class _Held {
  _Held(
    this.id, {
    required this.lineup,
    required this.page,
    required this.life,
  });

  final String id;
  final bool lineup;
  String page;
  int life;
  int revision = 1;
  bool live = true;
  int sortIndex = 0;
  double x = 0;

  Row get row {
    final fields = jsonObject({'createdAt': life});
    if (lineup) {
      final payload = LineupGroupPayload(
        payloadVersion: 1,
        data: {
          'id': id,
          'origins': [
            {'id': '$id-origin', 'x': x},
          ],
        },
      );
      return live
          ? LiveLineupGroup(
              publicId: id,
              strategyPublicId: strategyId,
              pagePublicId: page,
              payload: payload,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: fields,
            )
          : DeletedLineupGroup(
              publicId: id,
              strategyPublicId: strategyId,
              pagePublicId: page,
              payload: payload,
              sortIndex: sortIndex,
              revision: revision,
              unknownFields: fields,
            );
    }
    final payload = agentPayload(id, {
      'position': {'dx': x, 'dy': 3.5},
    });
    return live
        ? LiveElement(
            publicId: id,
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: fields,
          )
        : DeletedElement(
            publicId: id,
            pagePublicId: page,
            payload: payload,
            sortIndex: sortIndex,
            revision: revision,
            unknownFields: fields,
          );
  }
}

final class _Server {
  _Server(this.random) {
    for (var i = 0; i < 12; i++) {
      held.add(
        _Held(
          'row-$i',
          lineup: i % 4 == 3,
          page: _pages[i % _pages.length],
          life: fixtureLife + i,
        ),
      );
    }
  }

  final Random random;
  final held = <_Held>[];
  final trashed = <String>{};
  final pageRevisions = {for (final page in _pages) page: 1};
  final snapshots = <PageRead>[];
  final reached = <String, int>{};

  void count(String what) => reached[what] = (reached[what] ?? 0) + 1;

  void change() {
    final row = held[random.nextInt(held.length)];
    switch (random.nextInt(9)) {
      case 0 || 1:
        row
          ..x = random.nextDouble() * 1000
          ..revision += 1;
        count('payload changed');
      case 2:
        row
          ..page = _pages
              .where((page) => page != row.page)
              .toList()[random.nextInt(2)]
          ..revision += 1;
        count('moved between pages');
      case 3:
        row
          ..live = !row.live
          ..revision += 1;
        count(row.live ? 'restored' : 'deleted');
      case 4:
        row
          ..life += 1000
          ..x = random.nextDouble() * 1000;
        count('life changed at the same revision');
      case 5:
        row
          ..sortIndex = random.nextInt(20)
          ..revision += 1;
        count('reordered');
      case 6:
        final page = _pages[random.nextInt(_pages.length)];
        if (!trashed.remove(page)) trashed.add(page);
        pageRevisions[page] = pageRevisions[page]! + 1;
        count('page trashed or restored');
      case _:
        break;
    }
  }

  PageRead read() {
    if (snapshots.isNotEmpty && random.nextInt(6) == 0) {
      count('stale read');
      return snapshots[random.nextInt(snapshots.length)];
    }
    final page = _pages[random.nextInt(_pages.length)];
    final leaving = random.nextInt(5) == 0;
    final rows = [
      for (final each in held)
        if (each.page == page && !(leaving && random.nextBool())) each.row,
    ];
    if (leaving) count('rows left out of a read');
    final read = PageRead(
      page: trashed.contains(page)
          ? PendingTrashedPage(
              publicId: page,
              strategyPublicId: strategyId,
              name: page,
              sortIndex: _pages.indexOf(page),
              isAttack: true,
              revision: pageRevisions[page]!,
            )
          : LivePage(
              publicId: page,
              strategyPublicId: strategyId,
              name: page,
              sortIndex: _pages.indexOf(page),
              isAttack: true,
              revision: pageRevisions[page]!,
            ),
      elements: [
        for (final row in rows)
          if (row is ElementRow) row,
      ],
      lineupGroups: [
        for (final row in rows)
          if (row is LineupGroupRow) row,
      ],
    );
    snapshots.add(read);
    return read;
  }
}

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
  final server = _Server(Random(seed));
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
