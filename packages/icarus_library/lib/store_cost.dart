import 'dart:io';

import 'icarus_library.dart';
import 'sqlite_storage.dart';
import 'src/store/store.dart' show storeWork;
import 'take_cost.dart';

const storeCostSizes = [300, 3000];
const _warmups = 5;
const _runs = 31;
const _openRuns = 15;
const _build = 'store-cost';

bool _any(Object payload) => true;

const _readsAll = CanRead(element: _any, lineupGroup: _any);

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];

String _ms(num micros) => (micros / 1000).toStringAsFixed(2);

final class StepCost {
  final _wall = <int>[];
  final _disk = <int>[];
  final _decided = <int>[];
  final _rows = <int>[];
  final _groups = <int>[];
  final _chars = <int>[];
  final _visible = <int>[];
  final _tallied = <int>[];

  Future<T> measure<T>(EngineClock clock, Future<T> Function() step) async {
    storeWork.reset();
    clock.reset();
    final watch = Stopwatch()..start();
    final value = await step();
    _wall.add(watch.elapsedMicroseconds);
    _disk.add(clock.waited);
    _decided.add(storeWork.rowsDecided);
    _rows.add(storeWork.rowsWritten);
    _groups.add(storeWork.groupsWritten);
    _chars.add(storeWork.groupCharsWritten);
    _visible.add(storeWork.rowsMadeVisible);
    _tallied.add(storeWork.rowsTallied);
    return value;
  }

  String get row =>
      '${_ms(_median(_wall))} | ${_ms(_median(_disk))} | '
      '${_median(_decided)} | ${_median(_rows)} | ${_median(_groups)} | '
      '${_median(_chars)} | ${_median(_visible)} | ${_median(_tallied)}';
}

Future<Map<String, StepCost>> writeCosts(Directory folder, int items) async {
  final bench = await Bench.open(folder, items, 'write-$items');
  final commit = StepCost();
  final claim = StepCost();
  final answer = StepCost();
  final landing = StepCost();
  final teammate = StepCost();
  final ignored = StepCost();
  for (var run = 0; run < _warmups + _runs; run++) {
    final counted = run >= _warmups;
    StepCost or(StepCost step) => counted ? step : ignored;
    final move = bench.server.nextMove();
    final opId = 'store-cost-move-$run';
    final seen = switch (await bench.store.readStrategy(takeStrategyId)) {
      Found(:final value) => value,
      final other => throw StateError('the strategy could not be read: $other'),
    };
    saved(
      await or(commit).measure(
        bench.clock,
        () => bench.store.commitAs(
          takeAccount,
          takeStrategyId,
          ElementPatchOp(
            opId: opId,
            elementPublicId: move.id,
            pagePublicId: takePageId,
            expectedElementRevision: move.revision,
            payload: move.payload,
          ),
          seen: seen,
        ),
      ),
      'an own move',
    );
    final claimed = saved(
      await or(claim).measure(
        bench.clock,
        () => bench.store.record(takeAccount, takeStrategyId, [
          BatchClaimed(
            clientId: 'store-cost-client',
            opIds: [opId],
            at: DateTime.now().toUtc(),
          ),
        ]),
      ),
      'claiming the move',
    );
    final attempt = switch ([
      for (final outcome in claimed.outcomes)
        if (outcome case ReportApplied(:final effects))
          ...effects.whereType<SendBatch>(),
    ]) {
      [final sent] => sent.attempt,
      final other => throw StateError('claiming the move sent $other'),
    };
    applied(
      saved(
        await or(answer).measure(
          bench.clock,
          () => bench.store.record(takeAccount, takeStrategyId, [
            OpAnswered(
              attempt,
              AppliedAnswer(opId, revision: move.revision + 1, life: itemLife),
              point: nextStamp(),
            ),
          ]),
        ),
        'the applied answer',
      ),
      'the applied answer',
    );
    await or(
      landing,
    ).measure(bench.clock, () => bench.take(bench.server.landed(move)));
    await or(
      teammate,
    ).measure(bench.clock, () => bench.take(bench.server.moved()));
  }
  await bench.checkStored();
  await bench.close();
  return {
    'commit (an edit into the store)': commit,
    'claim': claim,
    'applied answer': answer,
    'its page result landing': landing,
    'a teammate\'s move arriving': teammate,
  };
}

JsonObject get _born => jsonObject(const {'createdAt': itemLife});

({HeaderRead header, List<PageRead> pages}) _strategyOf(int items, int pages) {
  final source = ServerPage(items ~/ pages, Seeded(items)).read();
  final pageRows = [
    for (var index = 0; index < pages; index++)
      LivePage(
        publicId: 'page-$index',
        strategyPublicId: takeStrategyId,
        name: 'Page ${index + 1}',
        sortIndex: index,
        isAttack: true,
        revision: 1,
        unknownFields: _born,
      ),
  ];
  return (
    header: HeaderRead(
      strategy: ReadableStrategy(
        publicId: takeStrategyId,
        name: 'Store cost',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.utc(2026, 1, 2, 3),
        updatedAt: DateTime.utc(2026, 1, 2, 3),
        unknownFields: _born,
      ),
      pages: pageRows,
      settings: [
        for (final page in pageRows)
          ReadablePageSettings(
            pagePublicId: page.publicId,
            settings: const PageSettings(
              agentSize: 1,
              abilitySize: 1,
              useNeutralTeamColors: false,
            ),
            revision: 1,
            unknownFields: _born,
          ),
      ],
    ),
    pages: [
      for (final page in pageRows)
        PageRead(
          page: page,
          elements: [
            for (final row in source.elements.cast<LiveElement>())
              LiveElement(
                publicId: '${page.publicId}-${row.publicId}',
                pagePublicId: page.publicId,
                payload: row.payload,
                sortIndex: row.sortIndex,
                revision: row.revision,
                unknownFields: row.unknownFields,
              ),
          ],
          lineupGroups: const [],
        ),
    ],
  );
}

Future<(LibraryStore, SqliteEngine, EngineClock)> _opened(String path) async {
  final engine = SqliteEngine(path);
  final clock = EngineClock();
  final store = switch (await LibraryStore.open(
    TimedEngine(engine, clock),
    canRead: _readsAll,
    clock: () => DateTime.now().toUtc(),
    build: _build,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => throw StateError('$problem'),
  };
  return (store, engine, clock);
}

typedef ReadCost = ({
  int open,
  int strategy,
  int firstPage,
  int wholeStrategy,
  int warmPage,
  int disk,
});

Future<ReadCost> readCosts(Directory folder, int items, int pages) async {
  final path =
      '${folder.path}${Platform.pathSeparator}read-$items-$pages.sqlite';
  final made = _strategyOf(items, pages);
  final (store, engine, _) = await _opened(path);
  saved(
    await store.addCloudStrategy(
      takeAccount,
      StampedRead(made.header, nextStamp()),
      [for (final page in made.pages) StampedRead(page, nextStamp())],
    ),
    'adding the strategy',
  );
  await store.close();
  await engine.close();
  final open = <int>[];
  final strategy = <int>[];
  final firstPage = <int>[];
  final whole = <int>[];
  final warm = <int>[];
  final disk = <int>[];
  for (var run = 0; run < 2 + _openRuns; run++) {
    final watch = Stopwatch()..start();
    final (opened, openedEngine, clock) = await _opened(path);
    final openIn = watch.elapsedMicroseconds;
    watch
      ..reset()
      ..start();
    if (await opened.readStrategy(takeStrategyId) case final other
        when other is! Found<StrategyContent>) {
      throw StateError('the strategy could not be read: $other');
    }
    final strategyIn = watch.elapsedMicroseconds;
    watch
      ..reset()
      ..start();
    if (await opened.readPage(takeStrategyId, 'page-0') case final other
        when other is! Found<PageContent>) {
      throw StateError('the first page could not be read: $other');
    }
    final firstIn = watch.elapsedMicroseconds;
    for (var index = 1; index < pages; index++) {
      await opened.readPage(takeStrategyId, 'page-$index');
    }
    final wholeIn = watch.elapsedMicroseconds + strategyIn;
    watch
      ..reset()
      ..start();
    await opened.readPage(takeStrategyId, 'page-0');
    final warmIn = watch.elapsedMicroseconds;
    final waited = clock.waited;
    await opened.close();
    await openedEngine.close();
    if (run >= 2) {
      open.add(openIn);
      strategy.add(strategyIn);
      firstPage.add(firstIn);
      whole.add(wholeIn);
      warm.add(warmIn);
      disk.add(waited);
    }
  }
  return (
    open: _median(open),
    strategy: _median(strategy),
    firstPage: _median(firstPage),
    wholeStrategy: _median(whole),
    warmPage: _median(warm),
    disk: _median(disk),
  );
}

Future<void> measureStoreCosts() async {
  final folder = await Directory.systemTemp.createTemp('store-cost-');
  try {
    stdout
      ..writeln('Writes, one moved item on one page, median of $_runs:')
      ..writeln()
      ..writeln(
        '| Items | Step | ms | SQLite ms | Rows decided | Rows '
        'written | Groups written | Group chars | Rows made visible | Rows '
        'tallied |',
      )
      ..writeln('|---|---|---|---|---|---|---|---|---|---|');
    for (final items in storeCostSizes) {
      for (final MapEntry(key: step, value: cost) in (await writeCosts(
        folder,
        items,
      )).entries) {
        stdout.writeln('| $items | $step | ${cost.row} |');
      }
    }
    stdout
      ..writeln()
      ..writeln('Reads after the store reopens, median of $_openRuns:')
      ..writeln()
      ..writeln(
        '| Items | Pages | Store open | readStrategy cold | First page '
        'cold | Open to first page | Whole strategy cold | A page warm | '
        'SQLite ms |',
      )
      ..writeln('|---|---|---|---|---|---|---|---|---|');
    for (final items in storeCostSizes) {
      for (final pages in [1, 10]) {
        final cost = await readCosts(folder, items, pages);
        stdout.writeln(
          '| $items | $pages | ${_ms(cost.open)} | ${_ms(cost.strategy)} | '
          '${_ms(cost.firstPage)} | '
          '${_ms(cost.open + cost.strategy + cost.firstPage)} | '
          '${_ms(cost.wholeStrategy)} | ${_ms(cost.warmPage)} | '
          '${_ms(cost.disk)} |',
        );
      }
    }
  } finally {
    await folder.delete(recursive: true);
  }
}
