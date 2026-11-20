import 'dart:io';

import 'package:icarus_library/hive_storage.dart';
import 'package:icarus_library/icarus_library.dart';

const _items = 300;
const _drawingPoints = 1000;
const _strategies = 500;
const _runs = 60;

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
      for (var i = 0; i < _drawingPoints; i++)
        {'dx': 100 + i * 0.731 + shift, 'dy': 200 + (i % 37) * 1.913},
    ],
  },
);

StrategyRowSet _strategy(String id, {required int items}) {
  final pages = ['$id-a', '$id-b'];
  return StrategyRowSet(
    strategy: StrategyRow(
      publicId: id,
      name: id,
      mapData: 'lotus',
      revision: 1,
    ),
    pages: [
      for (final (index, page) in pages.indexed)
        LivePage(
          publicId: page,
          strategyPublicId: id,
          name: 'Page ${index + 1}',
          sortIndex: index,
          isAttack: index.isEven,
          revision: 1,
        ),
    ],
    settings: [
      for (final page in pages)
        PageSettingsRow(
          pagePublicId: page,
          settings: const PageSettings(
            agentSize: 1,
            abilitySize: 1,
            useNeutralTeamColors: false,
          ),
          revision: 1,
        ),
    ],
    elements: [
      for (final page in pages)
        for (var i = 0; i < items; i++)
          LiveElement(
            publicId: '$page-$i',
            pagePublicId: page,
            payload: i.isEven
                ? _agent('$page-$i', i * 1.0)
                : _drawing('$page-$i', 0),
            sortIndex: i,
            revision: 1,
          ),
    ],
  );
}

Future<LibraryStore> _open(StorageEngine engine) async =>
    switch (await LibraryStore.open(engine, canRead: _readsAll)) {
      StoreOpened(:final store) => store,
      StoreNotOpened(:final problem) => throw StateError('$problem'),
    };

void _expectSaved(CommitResult result) {
  if (result is! Saved) throw StateError('not saved: $result');
}

final class _Times {
  final _micros = <int>[];

  Future<T> time<T>(Future<T> Function() task) async {
    final watch = Stopwatch()..start();
    final result = await task();
    _micros.add(watch.elapsedMicroseconds);
    return result;
  }

  String get summary {
    final sorted = [..._micros]..sort();
    String ms(int micros) => (micros / 1000).toStringAsFixed(2);
    final p95 = sorted[((sorted.length - 1) * 0.95).round()];
    return 'median ${ms(sorted[sorted.length ~/ 2])} ms, p95 ${ms(p95)} ms, n=${sorted.length}';
  }
}

Future<void> _measure(
  String name,
  Future<StorageEngine> Function() engine,
  Future<void> Function(StorageEngine engine) close,
) async {
  final setup = await engine();
  final store = await _open(setup);
  final added = await store.editLibrary([
    AddStrategy(
      _strategy('big', items: _items),
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    for (var i = 0; i < _strategies - 1; i++)
      AddStrategy(
        _strategy('s$i', items: 6),
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
  ]);
  if (added is! Saved) throw StateError('library not added: $added');
  await close(setup);

  final listing = _Times();
  for (var run = 0; run < 10; run++) {
    final opened = await engine();
    final list = await listing.time(() async => (await _open(opened)).library);
    if (list.strategies.length != _strategies) throw StateError('list');
    await close(opened);
  }

  final pageOpen = _Times();
  for (var run = 0; run < 10; run++) {
    final opened = await engine();
    final fresh = await _open(opened);
    await fresh.readStrategy('big');
    final page = await pageOpen.time(() => fresh.readPage('big', 'big-a'));
    if (page case Found(
      value: PageContent(:final elements),
    ) when elements.length == _items) {
      await close(opened);
      continue;
    }
    throw StateError('page');
  }

  final working = await engine();
  final editing = await _open(working);
  await editing.readPage('big', 'big-a');
  final move = _Times();
  final redraw = _Times();
  for (var run = 0; run < _runs; run++) {
    _expectSaved(
      await move.time(
        () => editing.commit(
          'big',
          ElementPatchOp(
            opId: 'move-$run',
            elementPublicId: 'big-a-0',
            expectedElementRevision: run + 1,
            payload: _agent('big-a-0', 500.0 + run),
          ),
        ),
      ),
    );
    _expectSaved(
      await redraw.time(
        () => editing.commit(
          'big',
          ElementPatchOp(
            opId: 'redraw-$run',
            elementPublicId: 'big-a-1',
            expectedElementRevision: run + 1,
            payload: _drawing('big-a-1', run + 1.0),
          ),
        ),
      ),
    );
  }
  await close(working);

  stdout
    ..writeln('$name engine')
    ..writeln(
      '  open the library list ($_strategies strategies): ${listing.summary}',
    )
    ..writeln(
      '  open a page ($_items items, half of them $_drawingPoints-point drawings): ${pageOpen.summary}',
    )
    ..writeln('  commit: move one agent on that page: ${move.summary}')
    ..writeln(
      '  commit: rewrite one $_drawingPoints-point drawing on that page: ${redraw.summary}',
    );
}

Future<void> main() async {
  final memory = MemoryEngine();
  await _measure('Memory', () async => memory, (_) async {});
  final directory = await Directory.systemTemp.createTemp(
    'icarus-store-bench-',
  );
  try {
    await _measure(
      'Hive CE (files in ${directory.path})',
      () async => HiveEngine(directory.path),
      (engine) => (engine as HiveEngine).close(),
    );
  } finally {
    await directory.delete(recursive: true);
  }
}
