import 'dart:io';

import 'package:icarus_library/icarus_library.dart';

const _items = 300;
const _drawingPoints = 1000;
const _strategies = 700;
const _runs = 60;

bool _readsAll(ElementPayload payload) => true;

final _created = DateTime.utc(2026);

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

StrategyRowSet _strategy(String id, {required int items, int pageCount = 2}) {
  final pages = [
    for (var i = 0; i < pageCount; i++) '$id-${'abcdefghijklmnopqrst'[i]}',
  ];
  return StrategyRowSet(
    strategy: ReadableStrategy(
      publicId: id,
      name: id,
      mapData: 'lotus',
      revision: 1,
      createdAt: _created,
      updatedAt: _created,
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
        ReadablePageSettings(
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

Future<LibraryStore> _open(MemoryStorage storage) async =>
    switch (await LibraryStore.open(
      MemoryEngine(storage),
      canRead: _readsAll,
    )) {
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
    return 'median ${ms(sorted[sorted.length ~/ 2])} ms, '
        'p95 ${ms(p95)} ms, n=${sorted.length}';
  }
}

Future<void> main() async {
  final storage = MemoryStorage();
  final setup = await _open(storage);
  final added = await setup.editLibrary([
    AddStrategy(_strategy('big', items: _items)),
    for (var i = 0; i < _strategies - 1; i++)
      AddStrategy(_strategy('s$i', items: 6)),
  ]);
  if (added is! Saved) throw StateError('library not added: $added');
  await setup.close();

  final listing = _Times();
  final coldPage = _Times();
  final warmPage = _Times();
  for (var run = 0; run < 10; run++) {
    final store = await listing.time(() => _open(storage));
    if (store.library case LibraryOpen(
      :final list,
    ) when list.strategies.length != _strategies) {
      throw StateError('list');
    }
    final cold = await coldPage.time(() => store.readPage('big', 'big-a'));
    await store.unload('big');
    await store.readStrategy('big');
    final warm = await warmPage.time(() => store.readPage('big', 'big-b'));
    for (final page in [cold, warm]) {
      if (page case Found(
        value: PageContent(:final elements),
      ) when elements.length == _items) {
        continue;
      }
      throw StateError('page');
    }
    await store.close();
  }

  final editing = await _open(storage);
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
  await editing.close();

  final wideStorage = MemoryStorage();
  final wideSetup = await _open(wideStorage);
  if (await wideSetup.editLibrary([
        AddStrategy(_strategy('wide', items: _items, pageCount: _widePages)),
      ])
      is! Saved) {
    throw StateError('wide strategy not added');
  }
  await wideSetup.close();
  final wide = _Times();
  for (var run = 0; run < 10; run++) {
    final store = await _open(wideStorage);
    await wide.time(() async {
      final content = await store.readStrategy('wide');
      if (content case Found(value: StrategyContent(:final pages))) {
        for (final page in pages) {
          await store.readPage('wide', page.publicId);
        }
      } else {
        throw StateError('wide');
      }
    });
    await store.close();
  }

  final pageNames = _Times();
  final wideNames = _Times();
  for (var run = 0; run < _runs; run++) {
    await pageNames.time(() async => _digestAll(_items, run));
    await wideNames.time(() async => _digestAll(_items * _widePages, run));
  }

  stdout
    ..writeln('Memory engine')
    ..writeln(
      '  open the store and its library list ($_strategies strategies): '
      '${listing.summary}',
    )
    ..writeln(
      '  open a page in a strategy not yet read ($_items items, half of '
      'them $_drawingPoints-point drawings): ${coldPage.summary}',
    )
    ..writeln('  open a page in a strategy already read: ${warmPage.summary}')
    ..writeln('  commit: move one agent on that page: ${move.summary}')
    ..writeln(
      '  commit: rewrite one $_drawingPoints-point drawing on that page: '
      '${redraw.summary}',
    )
    ..writeln(
      '  open a $_widePages-page strategy and every page of it '
      '(${_items * _widePages} items): ${wide.summary}',
    )
    ..writeln('  digest $_items ids: ${pageNames.summary}')
    ..writeln('  digest ${_items * _widePages} ids: ${wideNames.summary}');
}

const _widePages = 20;

int _digestAll(int count, int run) {
  var length = 0;
  for (var i = 0; i < count; i++) {
    length += digestOf('page-$run-element-$i').length;
  }
  return length;
}
