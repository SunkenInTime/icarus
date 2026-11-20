@TestOn('browser')
library;

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:test/test.dart';

import '../crash_harness.dart';
import '../store_support.dart';
import '../support.dart';
import 'indexed_db_harness.dart';

void main() {
  late String name;
  var count = 0;

  setUp(() async {
    name = 'icarus-test-${count++}';
    await deleteDatabase(name);
  });

  test(
    'reads what it wrote, by area, and lists keys by prefix in order',
    () async {
      final engine = await openIndexedDb(name);
      stored(
        await engine.write('a', {
          'page/2': 'two',
          'page/1': 'one',
          'other': 'x',
        }),
      );
      stored(await engine.write('b', {'page/1': 'elsewhere'}));
      stored(
        await engine.write('a', {'pagf': 'after the prefix', 'page': 'before'}),
      );
      expect(stored(await engine.read('a', 'page/1')), 'one');
      expect(stored(await engine.read('a', 'missing')), isNull);
      expect(stored(await engine.keys('a', 'page/')), ['page/1', 'page/2']);
      stored(await engine.delete('a', ['page/1']));
      expect(stored(await engine.keys('a', '')), [
        'other',
        'page',
        'page/2',
        'pagf',
      ]);
      expect(stored(await engine.read('b', 'page/1')), 'elsewhere');
      await engine.release();
    },
  );

  test('the store saves and reopens on IndexedDB', () async {
    final engine = IndexedDbEngine(name);
    final store = await openStore(engine);
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    final moved = savedValue(
      await store.commit(
        strategyId,
        everyOpType()['element.patch to another page']!,
      ),
    );
    await store.close();
    await engine.close();

    final reopenedEngine = IndexedDbEngine(name);
    final reopened = await openStore(reopenedEngine);
    expect(reopened.library.strategies.single, moved.change.summary);
    final pageB = pageOf(await reopened.readPage(strategyId, 'page-b'));
    expect(elementOn(pageB, 'jett').pagePublicId, 'page-b');
    await reopenedEngine.close();
  });

  test('a second opening on this origin is told another tab holds the '
      'library, and opens once the first closes', () async {
    final first = await openIndexedDb(name);
    expect(await IndexedDbEngine(name).lease(), isA<HeldByAnotherWriter>());
    await first.release();
    await (await openIndexedDb(name)).release();
  });

  test('writes in flight when a lease is released land whole before another '
      'context is granted the library', () async {
    Map<String, String> batch(int generation) => {
      for (var key = 0; key < 24; key++)
        'k$key': '$generation-${'x' * (key * 211)}',
    };
    final lease = await openIndexedDb(name);
    stored(await lease.write('probe', batch(0)));
    final second = readFromAnotherContext(name, 'probe');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final writes = [
      for (var generation = 1; generation <= 20; generation++)
        lease.write('probe', batch(generation)),
    ];
    await lease.release();
    expect(await Future.wait(writes), everyElement(isA<Done<void>>()));
    final (refusals, values) = await second;
    expect(refusals, greaterThan(0));
    expect(values, hasLength(24));
    expect(values.map((value) => value.split('-').first).toSet(), {'20'});
  });

  test('a transaction aborted after its first request succeeded is a failure '
      'the caller receives, and none of its keys land', () async {
    final engine = await openIndexedDb(name);
    stored(await engine.write('a', {'k1': 'old', 'k2': 'old'}));
    abortNextAfterItsFirstRequest();
    expect(
      await engine.write('a', {'k1': 'new', 'k2': 'new', 'k3': 'new'}),
      isA<StorageFailed<void>>(),
    );
    abortNextAfterItsFirstRequest();
    expect(await engine.delete('a', ['k1', 'k2']), isA<StorageFailed<void>>());
    expect(stored(await engine.keys('a', '')), ['k1', 'k2']);
    expect(stored(await engine.read('a', 'k1')), 'old');
    await engine.release();
  });

  test('a quota error is a failure the caller receives, the write does not '
      'land, and the store saves again afterwards', () async {
    final engine = IndexedDbEngine(name);
    final store = await openStore(engine);
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    exceedQuotaNext();
    final op = everyOpType()['element.patch']!;
    final refused = await store.commit(strategyId, op);
    expect(
      refused,
      isA<NotSaved<Committed, CommitRefusal>>().having(
        (result) => '${result.failure}',
        'failure',
        contains('QuotaExceededError'),
      ),
    );
    savedValue(await store.commit(strategyId, op));
    await store.close();
    await engine.close();
  });

  group('the engine contract', () {
    for (final check in engineContract) {
      test(check.name, () async {
        final result = await check.run(IndexedDbContractHarness(name));
        expect(result, isA<Passed>(), reason: '$result');
      });
    }
  });

  group(IndexedDbCrashHarness().name, () {
    engineCrashContract(IndexedDbCrashHarness.new);
    storeCrashContract(IndexedDbCrashHarness.new);
  });
}
