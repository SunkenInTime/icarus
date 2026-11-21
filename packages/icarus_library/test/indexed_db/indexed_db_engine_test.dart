@TestOn('browser')
library;

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/indexed_db_storage.dart';
import 'package:icarus_library/src/indexed_db/indexed_db_engine.dart'
    show IndexedDbEngineHold, indexedDbMaxKeyLength;
import 'package:icarus_library/src/indexed_db/indexed_db_engine.dart'
    show roomMargin;
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
        (result) => result.failure,
        'failure',
        isA<AbortedForQuota>(),
      ),
    );
    await store.close();
    final reopened = await openStore(engine);
    savedValue(await reopened.commit(strategyId, op));
    await reopened.close();
    await engine.close();
  });

  test('a put that throws while the changes are being queued leaves the '
      'commit in doubt, and the next lease finds it whole', () async {
    final lease = await openIndexedDb(name);
    committed(
      await lease.commit(const [Put('a', 'k', 'old'), Put('c', 'x', 'gone')]),
    );
    throwOnPutOf('too big');
    expect(
      await lease
          .commit(const [
            Put('a', 'k', 'new'),
            Put('b', 'k', 'too big'),
            ClearArea('c'),
          ])
          .timeout(const Duration(seconds: 5)),
      isA<CommitUnknown>(),
    );
    throwOnPutOf(null);
    expect(await lease.release(), isA<Released>());
    final next = await openIndexedDb(name);
    expect(valueOf(await next.read('a', 'k')), 'new');
    expect(valueOf(await next.read('b', 'k')), 'too big');
    expect(await next.read('c', 'x'), isA<KeyMissing>());
    await next.release();
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
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<BrowserLacks>().having(
          (lacks) => lacks.feature,
          'feature',
          BrowserFeature.strictDurability,
        ),
      ),
    );
    await (await openIndexedDb(name)).release();
  });

  test('another connection upgrading or deleting the database ends the lease '
      'instead of waiting on it', () async {
    final lease = await openIndexedDb(name);
    committed(await lease.commit(const [Put('a', 'k', 'v')]));
    expect(await upgradeFinishes(name, 3), isTrue);
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

  test('a browser that does not report durability at all is refused; the '
      'lock is let go and the database the lease created is deleted', () async {
    hideDurability(true);
    final leasing = await IndexedDbEngine(
      name,
    ).lease().timeout(const Duration(seconds: 5));
    hideDurability(false);
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<BrowserLacks>().having(
          (lacks) => lacks.feature,
          'feature',
          BrowserFeature.strictDurability,
        ),
      ),
    );
    expect(await databaseExists(name), isFalse);
    expect(await lockIsFree(name), isTrue);
  });

  test(
    'opening that throws something other than a DOMException, before or '
    'after the database opens, is a failed lease that lets go of the lock',
    () async {
      openThrows(true);
      final early = await IndexedDbEngine(
        name,
      ).lease().timeout(const Duration(seconds: 5));
      openThrows(false);
      expect(early, isA<LeaseFailed>());
      expect(await lockIsFree(name), isTrue);
      storeNamesThrow(true);
      final late = await IndexedDbEngine(
        name,
      ).lease().timeout(const Duration(seconds: 5));
      storeNamesThrow(false);
      expect(late, isA<LeaseFailed>());
      expect(await lockIsFree(name), isTrue);
      await (await openIndexedDb(name)).release();
    },
  );

  test('an open queued behind a delete that another connection blocks gives '
      'up after its patience and lets go of the lock', () async {
    await (await openIndexedDb(name)).release();
    final other = await openRaw(name);
    final deleting = deleteDatabase(name);
    final leasing = await IndexedDbEngine(
      name,
      patience: const Duration(seconds: 1),
    ).lease().timeout(const Duration(seconds: 5));
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    expect(await lockIsFree(name), isTrue);
    other.close();
    await deleting;
    await (await openIndexedDb(name)).release();
  });

  test(
    'a put that throws something other than a DOMException while queued '
    'leaves the commit in doubt, and the next lease finds it whole',
    () async {
      final lease = await openIndexedDb(name);
      throwPlainlyOnPutOf('broken');
      final result = await lease
          .commit(const [Put('a', 'first', 'v'), Put('a', 'second', 'broken')])
          .timeout(const Duration(seconds: 5));
      throwPlainlyOnPutOf(null);
      expect(result, isA<CommitUnknown>());
      expect(await lease.release(), isA<Released>());
      final next = await openIndexedDb(name);
      expect(valueOf(await next.read('a', 'first')), 'v');
      expect(valueOf(await next.read('a', 'second')), 'broken');
      await next.release();
    },
  );

  test('when the abort after a failed queue throws too, the commit is in doubt '
      'and release still answers', () async {
    final lease = await openIndexedDb(name);
    throwPlainlyOnPutOf('broken');
    abortThrows(true);
    final result = await lease
        .commit(const [Put('a', 'first', 'v'), Put('a', 'second', 'broken')])
        .timeout(const Duration(seconds: 5));
    abortThrows(false);
    throwPlainlyOnPutOf(null);
    expect(result, isA<CommitUnknown>());
    expect(
      await lease.release().timeout(const Duration(seconds: 5)),
      isA<Released>(),
    );
  });

  test('a cursor key that cannot be read fails listing areas instead of '
      'leaving the caller waiting', () async {
    final lease = await openIndexedDb(name);
    committed(
      await lease.commit(const [Put('a', 'k', 'v'), Put('b', 'k', 'v')]),
    );
    cursorKeysThrow(true);
    final listed = await lease.areas('').timeout(const Duration(seconds: 5));
    cursorKeysThrow(false);
    expect(listed, isA<StorageFailed<List<String>>>());
    await lease.release();
  });

  test(
    'a stored value that is not text, null and undefined included, is a failure to read '
    'and to list alike',
    () async {
      await (await openIndexedDb(name)).release();
      await putRaw(name, 'a', 'null', 'null');
      await putRaw(name, 'b', 'undefined', 'undefined');
      await putRaw(name, 'c', 'number', 'number');
      final lease = await openIndexedDb(name);
      for (final (area, key) in [
        ('a', 'null'),
        ('b', 'undefined'),
        ('c', 'number'),
      ]) {
        expect(
          await lease.read(area, key),
          isA<KeyNotRead>().having(
            (notRead) => notRead.failure,
            'failure',
            isA<DamagedLibrary>(),
          ),
          reason: key,
        );
        expect(
          await lease.entries(area, ''),
          isA<StorageFailed<List<StoredEntry>>>().having(
            (failed) => failed.failure,
            'failure',
            isA<DamagedLibrary>(),
          ),
          reason: key,
        );
      }
      await lease.release();
    },
  );

  test('two closes at once both finish with the same answer', () async {
    final engine = IndexedDbEngine(name);
    for (var round = 0; round < 3; round++) {
      await (await leaseOf(engine)).release();
    }
    await leaseOf(engine);
    final [first, second] = await Future.wait([engine.close(), engine.close()]);
    expect(first, isA<Released>());
    expect(identical(first, second), isTrue);
  });

  test(
    'a commit that would not fit in the room the browser reports is '
    'refused with nothing written, and fits once the room is there',
    () async {
      pretendRoomLeft(roomMargin + 20000);
      final lease = await openIndexedDb(name);
      committed(await lease.commit(const [Put('a', 'small', 'v')]));
      final big = 'x' * 20000;
      expect(
        await lease.commit([
          const Put('a', 'small', 'gone?'),
          Put('a', 'big', big),
        ]),
        isA<CommitRefused>().having(
          (refused) => refused.failure,
          'failure',
          isA<NoRoomForCommit>(),
        ),
      );
      expect(valueOf(await lease.read('a', 'small')), 'v');
      expect(await lease.read('a', 'big'), isA<KeyMissing>());
      pretendRoomLeft(null);
      committed(await lease.commit([Put('a', 'big', big)]));
      await lease.release();
    },
  );

  test('saves do not ask the browser for room each time', () async {
    pretendRoomLeft(64 * 1024 * 1024);
    final lease = await openIndexedDb(name);
    final before = estimatesAsked;
    for (var save = 0; save < 50; save++) {
      committed(await lease.commit([Put('a', 'k$save', 'v')]));
    }
    expect(estimatesAsked - before, lessThanOrEqualTo(1));
    pretendRoomLeft(null);
    await lease.release();
  });

  test('commits issued together are admitted against the room one after '
      'another, not all against the same headroom', () async {
    pretendRoomLeft(roomMargin + 60000);
    final lease = await openIndexedDb(name);
    final big = 'x' * 10000;
    final outcomes = await Future.wait([
      for (var i = 0; i < 3; i++) lease.commit([Put('a', 'k$i', big)]),
    ]);
    pretendRoomLeft(null);
    expect(outcomes.whereType<CommitApplied>(), hasLength(1));
    expect(
      outcomes.whereType<CommitRefused>().map((refused) => refused.failure),
      everyElement(isA<NoRoomForCommit>()),
    );
    await lease.release();
  });

  test('with less than the margin left, a commit that only deletes or only '
      'clears is admitted and lands, an empty commit lands without needing '
      'room, and a commit with a put is still refused', () async {
    final seeding = await openIndexedDb(name);
    committed(
      await seeding.commit(const [Put('a', 'k', 'v'), Put('b', 'x', 'v')]),
    );
    await seeding.release();
    pretendRoomLeft(8000);
    final lease = await openIndexedDb(name);
    committed(await lease.commit(const [Delete('a', 'k')]));
    committed(await lease.commit(const [ClearArea('b')]));
    committed(await lease.commit(const []));
    expect(
      await lease.commit(const [Put('a', 'k', 'w')]),
      isA<CommitRefused>().having(
        (refused) => refused.failure,
        'failure',
        isA<NoRoomForCommit>(),
      ),
    );
    expect(await lease.read('a', 'k'), isA<KeyMissing>());
    expect(await lease.read('b', 'x'), isA<KeyMissing>());
    pretendRoomLeft(null);
    await lease.release();
  });

  test('a delete-only commit whose record the browser aborts for room is in '
      'doubt, and the next lease shows it whole or absent', () async {
    for (final (keep, deleted) in [('last', true), ('none', false)]) {
      final engine = IndexedDbEngine('$name-$keep');
      final seeding = await leaseOf(engine);
      committed(await seeding.commit(const [Put('a', 'k', 'v')]));
      await seeding.release();
      await engine.close();
      pretendRoomLeft(8000);
      final again = IndexedDbEngine('$name-$keep');
      final lease = await leaseOf(again);
      cutWrite('quota', 1, keep: keep);
      expect(
        await lease.commit(const [Delete('a', 'k')]),
        isA<CommitUnknown>(),
        reason: keep,
      );
      clearCut();
      pretendRoomLeft(null);
      await again.close();
      final next = IndexedDbEngine('$name-$keep');
      final reopened = await leaseOf(next);
      expect(
        await reopened.read('a', 'k'),
        deleted ? isA<KeyMissing>() : isA<KeyHeld>(),
        reason: keep,
      );
      await next.close();
    }
  });

  test('an estimate that fails or cannot be read after the engine had a '
      'figure leaves the room unchecked: the commit applies and the lease '
      'says so, rather than trusting the old balance', () async {
    for (final how in ['reject', 'badShape']) {
      pretendRoomLeft(roomMargin + 20000);
      final engine = IndexedDbEngine('$name-$how');
      final lease = await leaseOf(engine) as IndexedDbLease;
      expect(lease.roomCheck, isA<RoomChecked>(), reason: how);
      estimateFails(how);
      final outcome = await lease.commit([Put('a', 'big', 'x' * 20000)]);
      estimateFails(null);
      pretendRoomLeft(null);
      expect(outcome, isA<CommitApplied>(), reason: how);
      expect(lease.roomCheck, isA<RoomNotChecked>(), reason: how);
      await engine.close();
    }
  });

  test('a browser that cannot say how much room there is gets a lease that '
      'says the room is not checked, and its commits apply', () async {
    for (final how in ['reject', 'throw', 'hang']) {
      estimateFails(how);
      final engine = IndexedDbEngine(
        '$name-$how',
        patience: const Duration(milliseconds: 500),
      );
      final lease = await leaseOf(engine) as IndexedDbLease;
      expect(lease.roomCheck, isA<RoomNotChecked>(), reason: how);
      committed(await lease.commit([Put('a', 'big', 'x' * 20000)]));
      estimateFails(null);
      await engine.close();
    }
  });

  test('an estimate that throws while a commit waits on it answers the '
      'commit, and release still closes and lets go of the lock', () async {
    pretendRoomLeft(roomMargin + 20000);
    final lease = await openIndexedDb(name);
    estimateFails('throw');
    final outcome = await lease
        .commit([Put('a', 'big', 'x' * 20000)])
        .timeout(const Duration(seconds: 5));
    estimateFails(null);
    pretendRoomLeft(null);
    expect(outcome, isA<CommitApplied>());
    expect(
      await lease.release().timeout(const Duration(seconds: 5)),
      isA<Released>(),
    );
    expect(await lockIsFree(name), isTrue);
  });

  test('a release whose close throws still lets go of the lock, and says '
      'the release failed', () async {
    final lease = await openIndexedDb(name);
    closeThrows(true);
    final releasing = await lease.release().timeout(const Duration(seconds: 5));
    closeThrows(false);
    expect(releasing, isA<ReleaseFailed>());
    expect(await lockIsFree(name), isTrue);
  });

  test(
    'a refused lease whose clean-up throws still lets go of the lock',
    () async {
      hideDurability(true);
      deleteThrows(true);
      final leasing = await IndexedDbEngine(
        name,
      ).lease().timeout(const Duration(seconds: 5));
      deleteThrows(false);
      hideDurability(false);
      expect(leasing, isA<LeaseFailed>());
      expect(await lockIsFree(name), isTrue);
    },
  );

  test('an abort whose error cannot be read is a commit in doubt, not an '
      'escaped exception', () async {
    final lease = await openIndexedDb(name);
    abortNextAfterItsFirstRequest();
    transactionErrorThrows(true);
    final outcome = await lease
        .commit(const [Put('a', 'k', 'v')])
        .timeout(const Duration(seconds: 5));
    transactionErrorThrows(false);
    expect(outcome, isA<CommitUnknown>());
    expect(await lease.release(), isA<Released>());
  });

  Future<StorageOrigin> originOf(String database) async {
    final opening = await LibraryStore.open(
      IndexedDbEngine(database),
      canRead: readsKnownKinds,
      clock: fixedClock,
    );
    final opened = opening as StoreOpened;
    await opened.store.close();
    return opened.origin;
  }

  test('the store says a library was created when it holds nothing, and '
      'opening writes nothing: after an engine made the database, after an '
      'unsaved open, after the database was deleted; a library with rows '
      'whose marker was lost is existing, and its next save puts the marker '
      'back', () async {
    await (await openIndexedDb(name)).release();
    expect(await originOf(name), isA<StorageCreated>());
    expect(await originOf(name), isA<StorageCreated>());
    final lease = await openIndexedDb(name);
    expect(await lease.read('library', 'format'), isA<KeyMissing>());
    committed(await lease.commit(const [Put('library', 'folder/x', 'kept')]));
    await lease.release();
    expect(await originOf(name), isA<StorageExisted>());
    final store = await openStore(IndexedDbEngine(name));
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    await store.close();
    final reading = await openIndexedDb(name);
    expect(valueOf(await reading.read('library', 'format')), '$storeFormat');
    await reading.release();
    await deleteDatabase(name);
    expect(await originOf(name), isA<StorageCreated>());
  });

  test(
    'a database at a newer engine format is refused and left as it was',
    () async {
      await (await openIndexedDb(name)).release();
      expect(await upgradeFinishes(name, 3), isTrue);
      expect(
        await IndexedDbEngine(name).lease(),
        isA<LeaseFailed>().having(
          (failed) => failed.failure,
          'failure',
          isA<NewerFormat>()
              .having((newer) => newer.layer, 'layer', FormatLayer.engine)
              .having((newer) => newer.found, 'found', 3)
              .having((newer) => newer.known, 'known', 2),
        ),
      );
      final raw = await openRaw(name);
      expect(raw.version, 3);
      raw.close();
    },
  );

  test('a library whose store format is newer than this build is refused by '
      'the store, and nothing in it changes', () async {
    final store = await openStore(IndexedDbEngine(name));
    await store.close();
    await putRaw(name, 'library', 'format', 'text:2');
    final reading = await openIndexedDb(name);
    final before = stored(await reading.entries('library', ''));
    await reading.release();
    expect(
      await LibraryStore.open(
        IndexedDbEngine(name),
        canRead: readsKnownKinds,
        clock: fixedClock,
      ),
      isA<StoreNotOpened>().having(
        (refused) => refused.problem,
        'problem',
        isA<OpenStorageFailed>().having(
          (failed) => failed.failure,
          'failure',
          isA<NewerFormat>().having(
            (newer) => newer.layer,
            'layer',
            FormatLayer.store,
          ),
        ),
      ),
    );
    final lease = await openIndexedDb(name);
    expect(stored(await lease.entries('library', '')), before);
    await lease.release();
  });

  test('a database without the rows store is a damaged library', () async {
    (await openRaw(name)).close();
    expect(
      await IndexedDbEngine(name).lease(),
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<DamagedLibrary>(),
      ),
    );
  });

  test('a page without Web Locks cannot hold the library', () async {
    hideWebLocks(true);
    final leasing = await IndexedDbEngine(name).lease();
    hideWebLocks(false);
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<BrowserLacks>().having(
          (lacks) => lacks.feature,
          'feature',
          BrowserFeature.webLocks,
        ),
      ),
    );
  });

  test('a read whose answer never comes is a failure once the engine\'s '
      'patience runs out', () async {
    final engine = IndexedDbEngine(
      name,
      patience: const Duration(milliseconds: 500),
    );
    final lease = await leaseOf(engine);
    swallowReads(true);
    final read = await lease.read('a', 'k').timeout(const Duration(seconds: 5));
    swallowReads(false);
    expect(
      read,
      isA<KeyNotRead>().having(
        (notRead) => notRead.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    await engine.close();
  });

  test('a commit whose completion never comes is in doubt once the engine\'s '
      'patience runs out, and release still lets go of the lock', () async {
    final engine = IndexedDbEngine(
      name,
      patience: const Duration(milliseconds: 500),
    );
    final lease = await leaseOf(engine);
    swallowCompletions(true);
    final outcome = await lease
        .commit(const [Put('a', 'k', 'v')])
        .timeout(const Duration(seconds: 5));
    swallowCompletions(false);
    expect(
      outcome,
      isA<CommitUnknown>().having(
        (unknown) => unknown.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    await lease.release().timeout(const Duration(seconds: 5));
    expect(await lockIsFree(name), isTrue);
  });

  test('a rows store that cannot be made is a failed lease that lets go of '
      'the lock, never a hang', () async {
    storeCreationThrows(true);
    final leasing = await IndexedDbEngine(
      name,
    ).lease().timeout(const Duration(seconds: 5));
    storeCreationThrows(false);
    expect(leasing, isA<LeaseFailed>());
    expect(await lockIsFree(name), isTrue);
  });

  test('a newer database cleared between the version error and the version '
      'lookup is not created again, and is not reported as format 1', () async {
    await (await openIndexedDb(name)).release();
    expect(await upgradeFinishes(name, 3), isTrue);
    deleteOnVersionError(true);
    final leasing = await IndexedDbEngine(
      name,
    ).lease().timeout(const Duration(seconds: 5));
    deleteOnVersionError(false);
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isNot(isA<NewerFormat>().having((newer) => newer.found, 'found', 1)),
      ),
    );
    expect(await databaseExists(name), isFalse);
  });

  group('a commit cut at every point it can be cut', () {
    const seed = <Change>[
      Put('a', 'k1', 'old'),
      Put('a', 'k2', 'old'),
      Put('b', 'gone', 'old'),
      Put('c', 'x', 'old'),
      Put('c', 'y', 'old'),
    ];
    const changes = <Change>[
      Put('a', 'k1', 'new'),
      Put('a', 'k3', 'new'),
      Delete('b', 'gone'),
      ClearArea('c'),
      Put('c', 'z', 'new'),
    ];
    const before = {
      'a': {'k1': 'old', 'k2': 'old'},
      'b': {'gone': 'old'},
      'c': {'x': 'old', 'y': 'old'},
    };
    const after = {
      'a': {'k1': 'new', 'k2': 'old', 'k3': 'new'},
      'b': <String, String>{},
      'c': {'z': 'new'},
    };

    Future<Map<String, Map<String, String>>> contents(
      StorageLease lease,
    ) async => {
      for (final area in ['a', 'b', 'c'])
        area: {
          for (final (:key, :value) in stored(await lease.entries(area, '')))
            key: value,
        },
    };

    final cuts = <String, (void Function(), Matcher, Object)>{
      'the record aborted': (
        abortNextAfterItsFirstRequest,
        isA<CommitRefused>(),
        before,
      ),
      'the record aborted for room, kept': (
        () => cutWrite('quota', 1, keep: 'last'),
        isA<CommitUnknown>(),
        after,
      ),
      'the record aborted for room, lost': (
        () => cutWrite('quota', 1),
        isA<CommitUnknown>(),
        before,
      ),
      'the record with no answer': (
        () => cutWrite('silence', 1),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes failing to start': (
        () => cutWrite('start', 2),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes aborted after their first request': (
        () => cutWrite('abort', 2),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes aborted for room, nothing kept': (
        () => cutWrite('quota', 2),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes aborted for room, the first request kept': (
        () => cutWrite('quota', 2, keep: 'first'),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes aborted for room, only the last request kept, as in '
          'Firefox bug 2080749': (
        () => cutWrite('quota', 2, keep: 'last'),
        isA<CommitUnknown>(),
        after,
      ),
      'the changes with no answer': (
        () => cutWrite('silence', 2),
        isA<CommitUnknown>(),
        after,
      ),
      'a change that throws while queued, and an abort that throws too': (
        () {
          throwPlainlyOnPutOf('new');
          abortThrows(true);
        },
        isA<CommitUnknown>(),
        after,
      ),
    };
    for (final MapEntry(key: cut, value: (arm, answered, settled))
        in cuts.entries) {
      test('$cut: answered as it should be, and the next lease finds the '
          'commit whole or absent, never in part', () async {
        final engine = IndexedDbEngine(
          name,
          patience: const Duration(milliseconds: 500),
        );
        final lease = await leaseOf(engine);
        committed(await lease.commit(seed));
        arm();
        final outcome = await lease
            .commit(changes)
            .timeout(const Duration(seconds: 5));
        clearCut();
        throwPlainlyOnPutOf(null);
        abortThrows(false);
        expect(outcome, answered, reason: cut);
        await engine.close();
        final next = IndexedDbEngine(name);
        final reopened = await leaseOf(next);
        final seen = await contents(reopened);
        expect(seen, anyOf(equals(before), equals(after)), reason: cut);
        expect(seen, settled, reason: cut);
        await next.close();
      });
    }
  });

  group('a commit queued behind one whose changes land in part', () {
    Future<Map<String, Map<String, String>>> contents(
      StorageLease lease,
    ) async => {
      for (final area in ['a', 'b'])
        area: {
          for (final (:key, :value) in stored(await lease.entries(area, '')))
            key: value,
        },
    };

    final faults = <String, void Function()>{
      'aborted for room, only the last request kept': () =>
          cutWrite('quota', 2, keep: 'last'),
      'aborted for room, the first request kept': () =>
          cutWrite('quota', 2, keep: 'first'),
      'aborted': () => cutWrite('abort', 2),
      'given no answer': () => cutWrite('silence', 2),
      'failing to start': () => cutWrite('start', 2),
    };
    for (final MapEntry(key: fault, value: arm) in faults.entries) {
      for (final (label, second) in [
        ('a commit', const <Change>[Put('b', 'z', 'new')]),
        ('an empty commit', const <Change>[]),
      ]) {
        test('A\'s changes $fault, $label queued behind it: A is whole at the '
            'next lease, the queued commit is refused, and A\'s record is '
            'the one kept', () async {
          final engine = IndexedDbEngine(
            name,
            patience: const Duration(milliseconds: 500),
          );
          final lease = await leaseOf(engine);
          arm();
          final first = lease.commit(const [
            Put('a', 'x', 'new'),
            Put('a', 'y', 'new'),
          ]);
          final queued = lease.commit(second);
          final (a, b) = (await first, await queued);
          clearCut();
          expect(a, isA<CommitUnknown>(), reason: fault);
          expect(
            b,
            isA<CommitRefused>().having(
              (refused) => refused.failure,
              'failure',
              isA<LeaseEnded>(),
            ),
            reason: fault,
          );
          expect(lease.status, isA<Ended>(), reason: fault);
          expect(
            await lease.commit(const [Put('b', 'third', 'v')]),
            isA<CommitRefused>(),
            reason: fault,
          );
          await engine.close();
          final next = IndexedDbEngine(name);
          final reopened = await leaseOf(next);
          expect(await contents(reopened), {
            'a': {'x': 'new', 'y': 'new'},
            'b': <String, String>{},
          }, reason: fault);
          await next.close();
        });
      }
    }
  });

  test('an intact library opens on a full disk without a write; one whose '
      'last commit needs completing is refused as storage full, loses '
      'nothing, and is completed once there is room', () async {
    final lease = await openIndexedDb(name);
    committed(await lease.commit(const [Put('a', 'k', 'v')]));
    await lease.release();
    storageFull(true);
    final intact = await IndexedDbEngine(name).lease();
    expect(intact, isA<Leased>());
    if (intact case Leased(lease: final opened)) {
      expect(valueOf(await opened.read('a', 'k')), 'v');
      await opened.release();
    }
    storageFull(false);

    final writer = await openIndexedDb(name);
    cutWrite('quota', 2);
    expect(
      await writer.commit(const [Put('a', 'k', 'w'), Put('b', 'k', 'w')]),
      isA<CommitUnknown>(),
    );
    clearCut();
    await writer.release();
    storageFull(true);
    expect(
      await IndexedDbEngine(name).lease(),
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<StorageFull>(),
      ),
    );
    storageFull(false);
    final completed = await openIndexedDb(name);
    expect(valueOf(await completed.read('a', 'k')), 'w');
    expect(valueOf(await completed.read('b', 'k')), 'w');
    await completed.release();
  });

  test('a record of the last commit that cannot be read is a damaged library, '
      'and one from a newer engine format is a newer format, at the lease; '
      'the check is never skipped', () async {
    await (await openIndexedDb(name)).release();
    for (final (record, failure) in [
      ('not json', isA<DamagedLibrary>()),
      ('{"format":2,"changes":[["put","Bad","k","v"]]}', isA<DamagedLibrary>()),
      ('{"format":2}', isA<DamagedLibrary>()),
      (
        '{"format":3,"changes":[]}',
        isA<NewerFormat>()
            .having((newer) => newer.found, 'found', 3)
            .having((newer) => newer.known, 'known', 2),
      ),
    ]) {
      await putRecord(name, record);
      expect(
        await IndexedDbEngine(name).lease(),
        isA<LeaseFailed>().having(
          (failed) => failed.failure,
          'failure',
          failure,
        ),
        reason: record,
      );
    }
  });

  test('a record the engine could never have written (an older or zero '
      'format, a key past the write limit) is a damaged library at the lease, '
      'and no row changes, not even one its clear names', () async {
    final seeding = await openIndexedDb(name);
    committed(await seeding.commit(const [Put('c', 'kept', 'v')]));
    await seeding.release();
    final long = 'k' * (indexedDbMaxKeyLength + 1);
    for (final record in [
      '{"format":1,"changes":[["clear","c"]]}',
      '{"format":0,"changes":[["clear","c"]]}',
      '{"format":2,"changes":[["clear","c"],["put","c","$long","v"]]}',
      '{"format":2,"changes":[["clear","c"],["delete","c","$long"]]}',
    ]) {
      await putRecord(name, record);
      expect(
        await IndexedDbEngine(name).lease(),
        isA<LeaseFailed>().having(
          (failed) => failed.failure,
          'failure',
          isA<DamagedLibrary>(),
        ),
        reason: record,
      );
    }
    await putRecord(name, '{"format":2,"changes":[]}');
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('c', 'kept')), 'v');
    await lease.release();
  });

  test('an open that answered no answer while a delete was blocked creates '
      'nothing when its upgrade arrives late', () async {
    await (await openIndexedDb(name)).release();
    final other = await openRaw(name);
    final deleting = deleteDatabase(name);
    expect(
      await IndexedDbEngine(
        name,
        patience: const Duration(milliseconds: 300),
      ).lease(),
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    other.close();
    await deleting;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await databaseExists(name), isFalse);
  });

  test('an open that times out after its upgrade made the stores leaves no '
      'new database behind', () async {
    slowUpgradeFor(const Duration(milliseconds: 900));
    expect(
      await IndexedDbEngine(
        name,
        patience: const Duration(milliseconds: 300),
      ).lease(),
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(await databaseExists(name), isFalse);
  });

  test('an open of a format 1 database that times out during its upgrade '
      'leaves the rows untouched, and the upgrade done or not done, never '
      'half', () async {
    await makeFormatOne(name, 'a', 'k', 'kept');
    slowUpgradeFor(const Duration(milliseconds: 900));
    expect(
      await IndexedDbEngine(
        name,
        patience: const Duration(milliseconds: 300),
      ).lease(),
      isA<LeaseFailed>(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final raw = await openRaw(name);
    final upgraded = raw.objectStoreNames.contains('last');
    expect(raw.version, upgraded ? 2 : 1);
    raw.close();
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('a', 'k')), 'kept');
    await lease.release();
  });

  test('a record with a field the writer never emits is a damaged library, '
      'and no row changes, not even one its clear names', () async {
    final seeding = await openIndexedDb(name);
    committed(await seeding.commit(const [Put('c', 'kept', 'v')]));
    await seeding.release();
    await putRecord(
      name,
      '{"format":2,"changes":[["clear","c"]],"unexpected":true}',
    );
    expect(
      await IndexedDbEngine(name).lease(),
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<DamagedLibrary>(),
      ),
    );
    await putRecord(name, '{"format":2,"changes":[]}');
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('c', 'kept')), 'v');
    await lease.release();
  });

  test('a check at open that cannot read every row it needs refuses the lease '
      'rather than replaying on a partial view', () async {
    final seeding = await openIndexedDb(name);
    committed(await seeding.commit(const [ClearArea('c'), Put('d', 'k', 'v')]));
    await seeding.release();
    await putRaw(name, 'c', 'stray', 'text:mismatch');
    await putRaw(name, 'd', 'k', 'text:changed');
    swallowRowReads(true);
    final leasing = await IndexedDbEngine(
      name,
      patience: const Duration(milliseconds: 300),
    ).lease().timeout(const Duration(seconds: 5));
    swallowRowReads(false);
    expect(
      leasing,
      isA<LeaseFailed>().having(
        (failed) => failed.failure,
        'failure',
        isA<NoAnswer>(),
      ),
    );
    await putRecord(name, '{"format":2,"changes":[]}');
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('c', 'stray')), 'mismatch');
    expect(valueOf(await lease.read('d', 'k')), 'changed');
    await lease.release();
  });

  test('a replay that throws while queuing is aborted before the lease is '
      'refused, leaves no prefix, and keeps the record', () async {
    final writer = await openIndexedDb(name);
    committed(await writer.commit(const [Put('a', 'k', 'old')]));
    cutWrite('quota', 2);
    expect(
      await writer.commit(const [Put('a', 'k', 'new'), Put('b', 'k', 'boom')]),
      isA<CommitUnknown>(),
    );
    clearCut();
    await writer.release();
    throwPlainlyOnPutOf('boom');
    expect(
      await IndexedDbEngine(name).lease().timeout(const Duration(seconds: 5)),
      isA<LeaseFailed>(),
    );
    throwPlainlyOnPutOf(null);
    final raw = await openRaw(name);
    raw.close();
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('a', 'k')), 'new');
    expect(valueOf(await lease.read('b', 'k')), 'boom');
    await lease.release();
  });

  test('a format 1 database with rows opens, gets the store for the last '
      'commit, and loses nothing', () async {
    await makeFormatOne(name, 'a', 'k', 'kept');
    final lease = await openIndexedDb(name);
    expect(valueOf(await lease.read('a', 'k')), 'kept');
    committed(await lease.commit(const [Put('a', 'k2', 'new')]));
    await lease.release();
    final raw = await openRaw(name);
    expect(raw.version, 2);
    expect(raw.objectStoreNames.contains('last'), isTrue);
    raw.close();
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
