import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'store_support.dart';
import 'support.dart';

void main() {
  Future<String> wholeRead(LibraryStore store) async {
    final content = switch (await store.readStrategy(strategyId)) {
      Found(:final value) => value,
      final other => fail('$other'),
    };
    final pages = [
      for (final page in content.pages)
        switch (await store.readPage(strategyId, page.publicId)) {
          Found(:final value) => [
            for (final row in value.elements) row.toJsonView(),
          ],
          final other => fail('$other'),
        },
    ];
    final strategy = [
      for (final row in content.pages) row.toJsonView(),
      for (final row in content.settings.values) row.toJsonView(),
      headerOf(content).toJsonView(),
      content.written,
    ];
    return '$strategy $pages';
  }

  StrategyRowSet rows() => strategyRows(
    elements: [
      element('agent-a', pageId: 'page-a'),
      element('agent-b', pageId: 'page-b'),
    ],
  );

  test('a strategy read ahead is read in one engine read of its area, and '
      'reads back as it does without reading ahead', () async {
    final storage = MemoryStorage();
    final writing = await openStore(MemoryEngine(storage));
    savedValue(await writing.putStrategy(rows(), writtenAt: 113));
    await writing.close();

    final plain = await openStore(MemoryEngine(storage));
    final expected = await wholeRead(plain);
    await plain.close();

    final (engine, counts) = counting(MemoryEngine(storage));
    final store = await openStore(engine);
    addTearDown(store.close);
    counts.reset();
    await store.readAhead([strategyId]);
    final read = await wholeRead(store);

    expect(read, expected);
    expect(counts.entryListings, [(strategyArea(strategyId), '')]);
    expect(counts.reads, isEmpty);
    expect(counts.keyListings, isEmpty);
  });

  test('a strategy removed after it was read ahead reads as gone', () async {
    final storage = MemoryStorage();
    final writing = await openStore(MemoryEngine(storage));
    savedValue(await writing.putStrategy(rows(), writtenAt: 113));
    await writing.close();
    final store = await openStore(MemoryEngine(storage));
    addTearDown(store.close);

    await store.readAhead([strategyId]);
    savedValue(await store.editLibrary([RemoveStrategy(strategyId)]));

    expect(await store.readStrategy(strategyId), isA<NotFound<Object>>());
  });

  test('a strategy unloaded after it was read ahead is read from the engine '
      'again', () async {
    final storage = MemoryStorage();
    final writing = await openStore(MemoryEngine(storage));
    savedValue(await writing.putStrategy(rows(), writtenAt: 113));
    await writing.close();
    final (engine, counts) = counting(MemoryEngine(storage));
    final store = await openStore(engine);
    addTearDown(store.close);

    await store.readAhead([strategyId]);
    await wholeRead(store);
    await store.unload(strategyId);
    counts.reset();
    await wholeRead(store);

    expect(counts.reads, isNotEmpty);
  });
}
