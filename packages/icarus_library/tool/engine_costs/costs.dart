import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';

const strategies = 700;
const bigPages = 20;
const pageItems = 300;
const drawingPoints = 1000;
const coldRuns = 15;
const saveRuns = 60;
const burst = 200;

bool _readsAll(ElementPayload payload) => true;

ElementPayload _agent(String id, double x) => ElementPayload(
  kind: ElementKind.agent,
  payloadVersion: 1,
  data: {
    'id': id,
    'elementType': 'agent',
    'type': 'jett',
    'position': {'dx': x, 'dy': 20.5},
    'isAlly': true,
  },
);

ElementPayload _drawing(String id, double shift) => ElementPayload(
  kind: ElementKind.drawing,
  payloadVersion: 1,
  data: {
    'id': id,
    'elementType': 'drawing',
    'color': 4294967295,
    'points': [
      for (var i = 0; i < drawingPoints; i++)
        {'dx': 100 + i * 0.731 + shift, 'dy': 200 + (i % 37) * 1.913},
    ],
  },
);

StrategyRowSet _strategy(
  String id, {
  required int pages,
  required int items,
  int drawingPages = 1 << 30,
}) {
  final pageIds = [for (var page = 0; page < pages; page++) '$id-p$page'];
  return StrategyRowSet(
    strategy: ReadableStrategy(
      publicId: id,
      name: id,
      mapData: 'lotus',
      revision: 1,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    pages: [
      for (final (index, page) in pageIds.indexed)
        LivePage(
          publicId: page,
          strategyPublicId: id,
          name: 'Page ${index + 1}',
          sortIndex: index,
          isAttack: index.isEven,
          revision: 1,
        ),
    ],
    elements: [
      for (final (index, page) in pageIds.indexed)
        for (var i = 0; i < items; i++)
          LiveElement(
            publicId: '$page-$i',
            pagePublicId: page,
            payload: i.isOdd && index < drawingPages
                ? _drawing('$page-$i', 0)
                : _agent('$page-$i', i * 1.0),
            sortIndex: i,
            revision: 1,
          ),
    ],
  );
}

final class Times {
  Times(this.name);

  final String name;
  final _micros = <int>[];

  Future<T> time<T>(Future<T> Function() task) async {
    final watch = Stopwatch()..start();
    final result = await task();
    _micros.add(watch.elapsedMicroseconds);
    return result;
  }

  int _at(double fraction) {
    final sorted = [..._micros]..sort();
    return sorted[((sorted.length - 1) * fraction).round()];
  }

  void add(int micros) => _micros.add(micros);

  String get summary {
    String ms(int micros) => (micros / 1000).toStringAsFixed(2);
    return '$name: median ${ms(_at(0.5))} ms, p90 ${ms(_at(0.9))} ms, '
        'p95 ${ms(_at(0.95))} ms, n=${_micros.length}';
  }
}

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: _readsAll)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

void _saved(Object? result) {
  if (result is! Saved) throw StateError('not saved: $result');
}

typedef EngineOpener = StorageEngine Function();

typedef EngineCloser = Future<void> Function(StorageEngine engine);

Future<List<String>> measure(EngineOpener open, EngineCloser close) async {
  final seeding = open();
  final setup = await _open(seeding);
  _saved(
    await setup.editLibrary([
      AddStrategy(
        _strategy('big', pages: bigPages, items: pageItems, drawingPages: 1),
      ),
    ]),
  );
  for (var first = 1; first < strategies; first += 50) {
    _saved(
      await setup.editLibrary([
        for (var i = first; i < first + 50 && i < strategies; i++)
          AddStrategy(_strategy('s$i', pages: 2, items: 3)),
      ]),
    );
  }
  await setup.close();
  await close(seeding);

  final cold = Times(
    'cold start: open the store and list $strategies strategies',
  );
  final strategy = Times(
    'open a $bigPages-page strategy of $pageItems items a page',
  );
  final page = Times(
    'cold read of a $pageItems-item page, half $drawingPoints-point drawings',
  );
  for (var run = 0; run < coldRuns; run++) {
    final engine = open();
    final store = await cold.time(() async {
      final store = await _open(engine);
      switch (store.library) {
        case LibraryOpen(:final list) when list.strategies.length == strategies:
          return store;
        case final other:
          throw StateError('the library list: $other');
      }
    });
    switch (await strategy.time(() => store.readStrategy('big'))) {
      case Found(value: StrategyContent(:final pages))
          when pages.length == bigPages:
        break;
      case final other:
        throw StateError('strategy: $other');
    }
    final read = await page.time(() => store.readPage('big', 'big-p0'));
    if (read case Found(
      value: PageContent(:final elements),
    ) when elements.length == pageItems) {
      await store.close();
      await close(engine);
      continue;
    }
    throw StateError('page: $read');
  }

  final engine = open();
  final store = await _open(engine);
  await store.readPage('big', 'big-p0');
  final move = Times('save one moved item');
  final redraw = Times('save one $drawingPoints-point drawing');
  for (var run = 0; run < saveRuns; run++) {
    _saved(
      await move.time(
        () => store.commit(
          'big',
          ElementPatchOp(
            opId: 'move-$run',
            elementPublicId: 'big-p0-0',
            expectedElementRevision: run + 1,
            payload: _agent('big-p0-0', 500.0 + run),
          ),
        ),
      ),
    );
    _saved(
      await redraw.time(
        () => store.commit(
          'big',
          ElementPatchOp(
            opId: 'redraw-$run',
            elementPublicId: 'big-p0-1',
            expectedElementRevision: run + 1,
            payload: _drawing('big-p0-1', run + 1.0),
          ),
        ),
      ),
    );
  }
  var revision = saveRuns + 1;
  final awaited = Times(
    '$burst moves of one item, each awaited before the next',
  );
  for (var run = 0; run < burst; run++) {
    _saved(
      await awaited.time(
        () => store.commit(
          'big',
          ElementPatchOp(
            opId: 'drag-$run',
            elementPublicId: 'big-p0-0',
            expectedElementRevision: revision++,
            payload: _agent('big-p0-0', 900.0 + run),
          ),
        ),
      ),
    );
  }
  final issued = Times('$burst moves issued at once, issue to saved');
  final clock = Stopwatch()..start();
  final waiting = [
    for (var run = 0; run < burst; run++)
      store
          .commit(
            'big',
            ElementPatchOp(
              opId: 'burst-$run',
              elementPublicId: 'big-p0-0',
              expectedElementRevision: revision++,
              payload: _agent('big-p0-0', 2000.0 + run),
            ),
          )
          .then((result) {
            _saved(result);
            issued.add(clock.elapsedMicroseconds);
          }),
  ];
  await Future.wait(waiting);
  final allSaved = clock.elapsedMicroseconds;
  await store.close();
  await close(engine);

  final engineLines = await _measureCommits(open, close);
  return [
    cold.summary,
    strategy.summary,
    page.summary,
    move.summary,
    redraw.summary,
    awaited.summary,
    issued.summary,
    '$burst moves issued at once: all saved after '
        '${(allSaved / 1000).toStringAsFixed(1)} ms',
    ...engineLines,
  ];
}

String _json(Object? value) => jsonEncode(value);

final _summary = _json({
  'publicId': 'big',
  'name': 'A strategy with a long name',
  'mapData': 'lotus',
  'pages': [
    for (var page = 0; page < bigPages; page++)
      {'publicId': 'big-p$page', 'items': pageItems, 'isAttack': page.isEven},
  ],
  'agents': ['jett', 'sova', 'omen', 'killjoy', 'kayo'],
});

List<Change> _moveCommit(int run) => [
  Put(
    'strategy/raw',
    'content/p0/element/e0',
    _json({'payload': _agent('e0', 500.0 + run).data, 'revision': run}),
  ),
  Put('library', 'summary/raw', '$_summary$run'),
];

Future<List<String>> _measureCommits(
  EngineOpener open,
  EngineCloser close,
) async {
  final engine = open();
  final lease = switch (await engine.lease()) {
    Leased(:final lease) => lease,
    final other => throw StateError('no lease: $other'),
  };
  void applied(Committing committing) {
    if (committing is! CommitApplied) {
      throw StateError('not applied: $committing');
    }
  }

  final single = Times('one commit of one small key');
  final shaped = Times(
    'one commit shaped like a save: an element row and a summary, two areas',
  );
  var run = 0;
  for (var i = 0; i < saveRuns; i++) {
    applied(
      await single.time(() => lease.commit([Put('probe', 'key', 'value $i')])),
    );
    applied(await shaped.time(() => lease.commit(_moveCommit(run++))));
  }
  final awaited = Times(
    '$burst save-shaped commits, each awaited before the next',
  );
  for (var i = 0; i < burst; i++) {
    applied(await awaited.time(() => lease.commit(_moveCommit(run++))));
  }
  final issued = Times('$burst save-shaped commits issued at once');
  final clock = Stopwatch()..start();
  await Future.wait([
    for (var i = 0; i < burst; i++)
      lease.commit(_moveCommit(run++)).then((result) {
        applied(result);
        issued.add(clock.elapsedMicroseconds);
      }),
  ]);
  final allApplied = clock.elapsedMicroseconds;

  final removal = Times(
    'remove a $bigPages-page strategy of ${bigPages * pageItems} items in '
    'one commit',
  );
  for (var i = 0; i < 5; i++) {
    for (var page = 0; page < bigPages; page++) {
      applied(
        await lease.commit([
          for (var item = 0; item < pageItems; item++)
            Put(
              'strategy/gone',
              'content/p$page/element/e$item',
              _json(
                page == 0 && item.isOdd
                    ? _drawing('e$item', 0).data
                    : _agent('e$item', item * 1.0).data,
              ),
            ),
        ]),
      );
    }
    applied(await lease.commit([Put('library', 'summary/gone', _summary)]));
    applied(
      await removal.time(
        () => lease.commit(const [
          ClearArea('strategy/gone'),
          Delete('library', 'summary/gone'),
        ]),
      ),
    );
    if (await lease.keys('strategy/gone', '') case Done(value: [_, ...])) {
      throw StateError('the strategy was not removed');
    }
  }
  await lease.release();
  await close(engine);
  return [
    single.summary,
    shaped.summary,
    awaited.summary,
    issued.summary,
    '$burst save-shaped commits issued at once: all applied after '
        '${(allApplied / 1000).toStringAsFixed(1)} ms',
    removal.summary,
  ];
}
