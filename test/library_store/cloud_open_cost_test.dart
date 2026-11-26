import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/library_rows/strategy_as_rows.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:icarus_library/take_cost.dart';

import '../library_rows/library_sources.dart';
import 'shadow_copy_corpus_test.dart' show corpusVariable;

const _build = 'cloud-open-cost';
const _life = 1767326400000;
final _account = Account('cloud-open-account');

bool _any(Object payload) => true;

const _readsAll = CanRead(element: _any, lineupGroup: _any);

int _items(StrategyData strategy) => strategy.pages.fold(
      0,
      (sum, page) =>
          sum +
          page.agentData.length +
          page.abilityData.length +
          page.drawingData.length +
          page.textData.length +
          page.imageData.length +
          page.utilityData.length +
          page.lineUpLinks.length,
    );

StrategyRowSet _born(StrategyRowSet rows) => StrategyRowSet(
      strategy: bornIn(rows.strategy, _life) as ReadableStrategy,
      pages: [for (final row in rows.pages) bornIn(row, _life) as PageRow],
      settings: [
        for (final row in rows.settings) bornIn(row, _life) as PageSettingsRow,
      ],
      elements: [
        for (final row in rows.elements) bornIn(row, _life) as ElementRow,
      ],
      lineupGroups: [
        for (final row in rows.lineupGroups)
          bornIn(row, _life) as LineupGroupRow,
      ],
    );

StrategyRowSet _twentyPages() {
  const strategyId = 'cloud-open-twenty';
  final pages = [
    for (var page = 0; page < 20; page++)
      LivePage(
        publicId: '$strategyId-page-$page',
        strategyPublicId: strategyId,
        name: 'Page ${page + 1}',
        sortIndex: page,
        isAttack: true,
        revision: 1,
      ),
  ];
  return _born(
    StrategyRowSet(
      strategy: ReadableStrategy(
        publicId: strategyId,
        name: 'Twenty pages',
        mapData: 'ascent',
        revision: 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(_life, isUtc: true),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(_life, isUtc: true),
      ),
      pages: pages,
      settings: const [],
      elements: [
        for (final page in pages)
          for (var item = 0; item < 300; item++)
            LiveElement(
              publicId: '${page.publicId}-agent-$item',
              pagePublicId: page.publicId,
              payload: ElementPayload(
                kind: ElementKind.agent,
                payloadVersion: 1,
                data: {
                  'id': '${page.publicId}-agent-$item',
                  'type': 'jett',
                  'position': {'dx': item * 3.0, 'dy': 7.5},
                },
              ),
              sortIndex: item,
              revision: 1,
            ),
      ],
      lineupGroups: const [],
    ),
  );
}

Future<(LibraryStore, EngineClock, SqliteEngine)> _open(String path) async {
  final engine = SqliteEngine(path);
  final clock = EngineClock();
  final store = switch (await LibraryStore.open(
    TimedEngine(engine, clock),
    canRead: _readsAll,
    clock: () => DateTime.now().toUtc(),
    build: _build,
  )) {
    StoreOpened(:final store) => store,
    StoreNotOpened(:final problem) => fail('store did not open: $problem'),
  };
  store.takeCloudResultsFrom(CloudResults.liveQueries);
  return (store, clock, engine);
}

Future<String> _measured(StrategyRowSet rows, String label) async {
  final folder = await Directory.systemTemp.createTemp('cloud_open_cost');
  addTearDown(() => folder.delete(recursive: true));
  final path = '${folder.path}/library.sqlite';
  final id = rows.strategy.publicId;
  final firstPage = rows.pages.first.publicId;
  {
    final (store, _, engine) = await _open(path);
    final added = await store.addCloudStrategy(
      _account,
      HeaderRead(
        strategy: rows.strategy,
        pages: rows.pages.toList(),
        settings: rows.settings.toList(),
      ),
      [
        for (final page in rows.pages)
          PageRead(
            page: page,
            elements: rows.elementsOn(page.publicId).toList(),
            lineupGroups: rows.lineupGroupsOn(page.publicId).toList(),
          ),
      ],
    );
    expect(added, isA<Saved<Object?, Object?>>());
    await store.close();
    await engine.close();
  }
  final opens = <int>[];
  final pageReads = <int>[];
  final lists = <int>[];
  final pageResults = <int>[];
  final counts = <String>{};
  for (var run = 0; run < 3 + 21; run++) {
    final watch = Stopwatch()..start();
    final (store, clock, engine) = await _open(path);
    clock.reset();
    expect(await store.readStrategy(id), isA<Found<StrategyContent>>());
    final opened = watch.elapsedMicroseconds;
    final openReads = clock.reads;
    final openCommits = clock.commits;
    watch.reset();
    expect(await store.readPage(id, firstPage), isA<Found<PageContent>>());
    final paged = watch.elapsedMicroseconds;
    final pageReadsDone = clock.reads;
    final session = switch (await store.readStrategy(id)) {
      Found(value: StrategyContent(sync: final CloudStrategy cloud)) =>
        cloud.queue.session.number,
      final other => fail('no cloud strategy: $other'),
    };
    final beforeList = clock.reads;
    watch.reset();
    await store.record(_account, id, [
      BaseArrived(
        HeaderRead(
          strategy: rows.strategy,
          pages: rows.pages.toList(),
          settings: rows.settings.toList(),
        ),
        session: session,
        from: const LiveResult(),
      ),
    ]);
    final listed = watch.elapsedMicroseconds;
    final listReads = clock.reads - beforeList;
    final lastPage = rows.pages.last.publicId;
    final beforePage = clock.reads;
    watch.reset();
    await store.record(_account, id, [
      BaseArrived(
        PageRead(
          page: rows.pages.last,
          elements: rows.elementsOn(lastPage).toList(),
          lineupGroups: rows.lineupGroupsOn(lastPage).toList(),
        ),
        session: session,
        from: const LiveResult(),
      ),
    ]);
    final pageTaken = watch.elapsedMicroseconds;
    counts.add(
      'open: $openReads reads, $openCommits commits; first page: '
      '${pageReadsDone - openReads} reads; a list that keeps every page: '
      '$listReads reads; a page result: ${clock.reads - beforePage} reads',
    );
    if (run >= 3) {
      opens.add(opened);
      pageReads.add(paged);
      lists.add(listed);
      pageResults.add(pageTaken);
    }
    await store.close();
    await engine.close();
  }
  int median(List<int> values) => (values..sort())[values.length ~/ 2];
  String ms(int micros) => (micros / 1000).toStringAsFixed(2);
  return 'CLOUDOPEN $label: open and read the strategy '
      '${ms(median(opens))} ms (worst ${ms(opens.reduce((a, b) => a > b ? a : b))}), '
      'then the first page ${ms(median(pageReads))} ms, a list that keeps '
      'every page ${ms(median(lists))} ms, a page result '
      '${ms(median(pageResults))} ms, medians of 21; ${counts.join(' | ')}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final corpus = Platform.environment[corpusVariable];
  if (Platform.environment['CLOUD_OPEN_CHECKED'] == '0') {
    final checked = shownTakesChecked;
    setUp(() => shownTakesChecked = false);
    tearDown(() => shownTakesChecked = checked);
  }

  test('opening a cloud strategy of 20 pages of 300 items', () async {
    // ignore: avoid_print
    print(await _measured(_twentyPages(), '20 pages of 300 items'));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test(
    'opening the corpus strategy with the most items as a cloud strategy',
    skip: corpus == null ? 'set $corpusVariable to a corpus folder' : false,
    () async {
      StrategyData? largest;
      for (final store in hiveStoresUnder(Directory(corpus!))) {
        for (final strategy in (await loadHiveStore(store)).strategies) {
          if (largest == null || _items(strategy) > _items(largest)) {
            largest = strategy;
          }
        }
      }
      final big = largest!;
      final rows = switch (strategyToRows(big)) {
        StrategyRowsMade(:final rows) => _born(rows),
        final other => fail('the largest strategy has no rows: $other'),
      };
      // ignore: avoid_print
      print(
        await _measured(
          rows,
          'the corpus strategy with the most items '
          '(${_items(big)} items, ${big.pages.length} pages)',
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
