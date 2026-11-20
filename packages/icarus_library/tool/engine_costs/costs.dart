import 'package:icarus_library/icarus_library.dart';

const strategies = 500;
const pageItems = 300;
const drawingPoints = 1000;
const coldRuns = 15;
const saveRuns = 60;

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

StrategyRowSet _strategy(String id, {required int pages, required int items}) {
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
      for (final page in pageIds)
        for (var i = 0; i < items; i++)
          LiveElement(
            publicId: '$page-$i',
            pagePublicId: page,
            payload: i.isOdd
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

  String get summary {
    String ms(int micros) => (micros / 1000).toStringAsFixed(2);
    return '$name: median ${ms(_at(0.5))} ms, p90 ${ms(_at(0.9))} ms, '
        'n=${_micros.length}';
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
      AddStrategy(_strategy('big', pages: 2, items: pageItems)),
      for (var i = 1; i < strategies; i++)
        AddStrategy(_strategy('s$i', pages: 2, items: 3)),
    ]),
  );
  await setup.close();
  await close(seeding);

  final cold = Times(
    'cold start: open the store and list $strategies strategies',
  );
  final page = Times(
    'open a $pageItems-item page, half $drawingPoints-point drawings',
  );
  for (var run = 0; run < coldRuns; run++) {
    final engine = open();
    final store = await cold.time(() async {
      final store = await _open(engine);
      if (store.library.strategies.length != strategies) {
        throw StateError('list');
      }
      return store;
    });
    await store.readStrategy('big');
    final opened = await page.time(() => store.readPage('big', 'big-p0'));
    if (opened case Found(
      value: PageContent(:final elements),
    ) when elements.length == pageItems) {
      await store.close();
      await close(engine);
      continue;
    }
    throw StateError('page');
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
  await store.close();
  await close(engine);
  return [cold.summary, page.summary, move.summary, redraw.summary];
}
