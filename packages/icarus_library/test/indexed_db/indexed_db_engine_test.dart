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
      committed(
        await put(engine, 'a', {
          'page/2': 'two',
          'page/1': 'one',
          'other': 'x',
        }),
      );
      committed(await put(engine, 'b', {'page/1': 'elsewhere'}));
      committed(
        await put(engine, 'a', {'pagf': 'after the prefix', 'page': 'before'}),
      );
      expect(valueOf(await engine.read('a', 'page/1')), 'one');
      expect(valueOf(await engine.read('a', 'missing')), isNull);
      expect(stored(await engine.keys('a', 'page/')), ['page/1', 'page/2']);
      committed(await remove(engine, 'a', ['page/1']));
      expect(stored(await engine.keys('a', '')), [
        'other',
        'page',
        'page/2',
        'pagf',
      ]);
      expect(valueOf(await engine.read('b', 'page/1')), 'elsewhere');
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
    expect(listOf(reopened).strategies.single, moved.change.summary);
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
    committed(await put(lease, 'probe', batch(0)));
    final second = readFromAnotherContext(name, 'probe');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final writes = [
      for (var generation = 1; generation <= 20; generation++)
        put(lease, 'probe', batch(generation)),
    ];
    await lease.release();
    expect(await Future.wait(writes), everyElement(isA<CommitApplied>()));
    final (refusals, values) = await second;
    expect(refusals, greaterThan(0));
    expect(values, hasLength(24));
    expect(values.map((value) => value.split('-').first).toSet(), {'20'});
  });

  test(
    'a commit across three areas with an area clear, aborted after its '
    'first request succeeded, is refused and leaves every area as it was',
    () async {
      final engine = await openIndexedDb(name);
      committed(
        await engine.commit(const [
          Put('a', 'k1', 'old'),
          Put('b', 'k1', 'old'),
          Put('c', 'k1', 'old'),
          Put('c', 'k2', 'old'),
        ]),
      );
      abortNextAfterItsFirstRequest();
      expect(
        await engine.commit(const [
          Put('a', 'k1', 'new'),
          Delete('b', 'k1'),
          ClearArea('c'),
          Put('c', 'k3', 'new'),
        ]),
        isA<CommitRefused>(),
      );
      for (final area in ['a', 'b']) {
        expect(stored(await engine.entries(area, '')), [
          (key: 'k1', value: 'old'),
        ], reason: area);
      }
      expect(stored(await engine.entries('c', '')), [
        (key: 'k1', value: 'old'),
        (key: 'k2', value: 'old'),
      ]);
      await engine.release();
    },
  );

  test('a quota error leaves the save in doubt, since a browser can keep part '
      'of an aborted transaction; the store shuts, and a store opened after it '
      'saves again', () async {
    final engine = IndexedDbEngine(name);
    final store = await openStore(engine);
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    exceedQuotaNext();
    final op = everyOpType()['element.patch']!;
    expect(
      await store.commit(strategyId, op),
      isA<SaveInDoubt<Committed, CommitRefusal>>().having(
        (result) => '${result.failure}',
        'failure',
        contains('QuotaExceededError'),
      ),
    );
    await store.close();
    final reopened = await openStore(engine);
    savedValue(await reopened.commit(strategyId, op));
    await reopened.close();
    await engine.close();
  });

  test('a put that throws while the commit is being queued leaves nothing of '
      'the commit and is refused', () async {
    final lease = await openIndexedDb(name);
    committed(await lease.commit(const [Put('a', 'k', 'old')]));
    throwOnPutOf('too big');
    expect(
      await lease
          .commit(const [
            Put('a', 'k', 'new'),
            Put('b', 'k', 'too big'),
            ClearArea('c'),
          ])
          .timeout(const Duration(seconds: 5)),
      isA<CommitRefused>(),
    );
    throwOnPutOf(null);
    expect(valueOf(await lease.read('a', 'k')), 'old');
    expect(valueOf(await lease.read('b', 'k')), isNull);
    expect(await lease.release(), isA<Released>());
  });

  test('a lease asked for while the engine closes is refused or ended by the '
      'close, and once close returns the next engine can lease', () async {
    for (var round = 0; round < 10; round++) {
      final engine = IndexedDbEngine(name);
      final leasing = engine.lease();
      await engine.close();
      switch (await leasing) {
        case Leased(:final lease):
          expect(lease.status, isA<Ended>(), reason: 'round $round');
        case LeaseFailed(failure: EngineClosed()):
          break;
        case final other:
          fail('round $round: $other');
      }
      final next = IndexedDbEngine(name);
      expect(await next.lease(), isA<Leased>(), reason: 'round $round');
      await next.close();
    }
  });

  test('a lock request the browser rejects is a failed lease, and a name Web '
      'Locks keep for themselves is refused when the engine is made', () async {
    expect(() => IndexedDbEngine('-reserved'), throwsArgumentError);
    rejectLockRequests(true);
    final leasing = await IndexedDbEngine(
      name,
    ).lease().timeout(const Duration(seconds: 5));
    rejectLockRequests(false);
    expect(leasing, isA<LeaseFailed>());
    await (await openIndexedDb(name)).release();
  });

  test('a browser that does not keep a write transaction strict is refused '
      'a lease', () async {
    dropTransactionOptions(true);
    final leasing = await IndexedDbEngine(name).lease();
    dropTransactionOptions(false);
    expect(leasing, isA<LeaseFailed>());
    await (await openIndexedDb(name)).release();
  });

  test('another connection upgrading or deleting the database ends the lease '
      'instead of waiting on it', () async {
    final lease = await openIndexedDb(name);
    committed(await lease.commit(const [Put('a', 'k', 'v')]));
    expect(await upgradeFinishes(name, 2), isTrue);
    expect(lease.status, isA<Ended>());
    expect(
      await lease.commit(const [Put('a', 'k', 'w')]),
      isA<CommitRefused>().having(
        (refused) => refused.failure,
        'failure',
        isA<LeaseEnded>(),
      ),
    );
    await deleteDatabase(name);
    final again = await openIndexedDb(name);
    committed(await again.commit(const [Put('a', 'k', 'v')]));
    await deleteDatabase(name);
    expect(again.status, isA<Ended>());
  });

  test('the browser closing the database ends the lease', () async {
    final lease = await openIndexedDb(name);
    forceCloseOpenedDatabases();
    expect(lease.status, isA<Ended>());
    expect(await lease.read('a', 'k'), isA<KeyNotRead>());
  });

  test('a second release does not answer before the first has let go of '
      'the library', () async {
    final engine = IndexedDbEngine(name);
    final lease = await leaseOf(engine);
    final pending = engine.holdNextCommit();
    final writing = lease.commit(const [Put('a', 'k', 'held')]);
    await pending.reached;
    final first = lease.release();
    var secondAnswered = false;
    final second = lease.release().then((releasing) {
      secondAnswered = true;
      return releasing;
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(secondAnswered, isFalse);
    pending.letGo();
    await writing;
    expect(await first, isA<Released>());
    expect(await second, isA<Released>());
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

  test('the contract catches a real IndexedDB engine whose held write lands '
      'through a fresh connection after the next lease was granted, since a '
      'Web Lock does not stop a stale tab from writing', () async {
    final check = engineContract.singleWhere(
      (check) => check.name.startsWith('a write pending when its lease ends'),
    );
    expect(await check.run(StaleWriterHarness(name)), isA<Broke>());
  });

  group(IndexedDbCrashHarness().name, () {
    engineCrashContract(IndexedDbCrashHarness.new);
    storeCrashContract(IndexedDbCrashHarness.new);
  });
}
