import 'dart:convert';

import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

String area = strategyArea(strategyId);

Matcher refusedWith<T>() => isA<Refused<Object?, CommitRefusal>>().having(
  (refused) => refused.reason,
  'reason',
  isA<T>(),
);

Matcher anotherAccountsWork() => isA<Refused<Object?, CommitRefusal>>().having(
  (refused) => refused.reason,
  'reason',
  isA<WorkOfAnotherAccount>()
      .having((why) => why.strategyPublicId, 'strategy', strategyId)
      .having((why) => why.owner, 'owner', OwnedBy(testAccount)),
);

Future<(LibraryStore, MemoryStorage)> withWork() async {
  final storage = MemoryStorage();
  final store = await openCloudStore(MemoryEngine(storage));
  await addCloud(store, initialRows());
  savedValue(
    await store.commitAs(
      testAccount,
      strategyId,
      movePatch('mine'),
      seen: await seenIn(store),
    ),
  );
  return (store, storage);
}

Future<(LibraryStore, MemoryStorage)> reopenedWithCloudRow(
  Map<String, Object?> Function(Map<String, Object?> row) change,
) async {
  final (store, storage) = await withWork();
  await store.close();
  final contents = editable(storage.contents);
  final row = jsonDecode(contents[area]!['cloud']!) as Map<String, Object?>;
  contents[area]!['cloud'] = jsonEncode(change(row));
  final disk = MemoryStorage(contents);
  return (await openCloudStore(MemoryEngine(disk)), disk);
}

StrategyRowSet renamedRows() => withOp(
  initialRows(),
  const StrategyPatchOp(
    opId: 'renamed',
    expectedStrategyRevision: 1,
    name: 'Renamed by the server',
  ),
);

StrategyRowSet otherStrategyRows() => StrategyRowSet(
  strategy: strategyRow(publicId: 'strategy-2'),
  pages: const [],
  settings: const [],
  elements: const [],
  lineupGroups: const [],
);

final class FailingListingsLease extends ForwardingLease {
  FailingListingsLease(super.inner);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      area == strategyArea(strategyId)
      ? const StorageFailed(DeviceFailure('the listing timed out'))
      : super.entries(area, prefix);
}

String describe(StoreChange change) => switch (change) {
  StrategyRefreshed(:final strategyPublicId, :final summary) =>
    'refreshed $strategyPublicId ${summary.toJson()}',
  _ => '${change.runtimeType}',
};

void main() {
  test('a cloud strategy keeps the account its work belongs to, across a '
      'reopen', () async {
    final (store, storage) = await withWork();
    expect((await syncOf(store)).owner, testAccount);
    expect(
      listOf(store).strategies.single.sync,
      isA<KeptInCloud>().having(
        (sync) => sync.owner,
        'owner',
        OwnedBy(testAccount),
      ),
    );
    expect(
      jsonDecode(storage.contents[area]!['cloud']!),
      containsPair('account', testAccount.subject),
    );
    await store.close();
    final reopened = await openCloudStore(MemoryEngine(storage));
    expect(
      listOf(reopened).strategies.single.sync,
      isA<KeptInCloud>().having(
        (sync) => sync.owner,
        'owner',
        OwnedBy(testAccount),
      ),
    );
    expect((await syncOf(reopened)).owner, testAccount);
  });

  test('a clean cloud strategy is listed as unverified with its account until '
      'its queue is read', () async {
    final storage = MemoryStorage();
    final store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    await store.close();
    final reopened = await openCloudStore(MemoryEngine(storage));
    expect(
      listOf(reopened).strategies.single.sync,
      isA<CloudUnverified>().having(
        (sync) => sync.owner,
        'owner',
        OwnedBy(testAccount),
      ),
    );
  });

  group('a call from another account is refused and changes nothing', () {
    final calls =
        <
          (
            String,
            Future<Saving<Object?, CommitRefusal>> Function(
              LibraryStore store,
              int session,
            ),
          )
        >[
          (
            'an edit',
            (store, _) async => store.commitAs(
              otherAccount,
              strategyId,
              movePatch('theirs', elementId: 'e2'),
              seen: await seenIn(store),
            ),
          ),
          (
            'a batch of edits',
            (store, _) async => store.commitAllAs(otherAccount, strategyId, [
              movePatch('theirs', elementId: 'e2'),
            ], seen: await seenIn(store)),
          ),
          (
            'a claim',
            (store, _) => store.record(otherAccount, strategyId, [
              BatchClaimed(
                clientId: clientId,
                opIds: const ['mine'],
                at: fixedClock(),
              ),
            ]),
          ),
          (
            'an answer',
            (store, _) => store.record(otherAccount, strategyId, [
              const OpAnswered(
                1,
                AppliedAnswer('mine', revision: 2, life: fixtureLife),
              ),
            ]),
          ),
          (
            'a user\'s choice',
            (store, _) => store.record(otherAccount, strategyId, [
              const UserDiscarded('mine'),
            ]),
          ),
          (
            'an account change',
            (store, _) => store.record(otherAccount, strategyId, [
              const AccountChanged(),
            ]),
          ),
          (
            'a connection',
            (store, _) => store.record(otherAccount, strategyId, [
              const ConnectionReturned(),
            ]),
          ),
          (
            'a result of the current session',
            (store, session) async => store.record(otherAccount, strategyId, [
              BaseArrived(
                headerReadOf(renamedRows()),
                session: session,
                from: await readStartOf(store),
              ),
            ]),
          ),
          (
            'a look that records no event',
            (store, _) => store.record(otherAccount, strategyId, const []),
          ),
          (
            'a discard of a queue that is not held',
            (store, _) => store.discardUnreadableQueue(
              otherAccount,
              strategyId,
              const DiscardsUnsentWork(),
            ),
          ),
        ];
    for (final (label, call) in calls) {
      test(label, () async {
        final (store, storage) = await withWork();
        final before = editable(storage.contents);
        final queue = (await syncOf(store)).queue;
        expect(await call(store, queue.session.number), anotherAccountsWork());
        expect(sameContents(storage.contents, before), isTrue);
        expect((await syncOf(store)).queue, queue);
        final sent = await claimAll(store);
        expect(sent.ops.map((op) => op.opId), ['mine']);
      });
    }

    test('the same result from the owner applies', () async {
      final (store, _) = await withWork();
      final session = (await syncOf(store)).queue.session.number;
      final recorded = await recordAll(store, [
        BaseArrived(
          headerReadOf(renamedRows()),
          session: session,
          from: await readStartOf(store),
        ),
      ]);
      expect(recorded.outcomes.single, isA<ReportApplied>());
      expect(
        (strategyOf(await store.readStrategy(strategyId)).strategy
                as ReadableStrategy)
            .name,
        renamedRows().strategy.name,
      );
    });
  });

  group('another account is told so once its owner is known, ahead of '
      'every other queue refusal', () {
    test('on a held queue whose owner is known', () async {
      final (store, disk) = await reopenedWithCloudRow(
        (row) => {...row, 'presence': 'not a presence'},
      );
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.owner,
          'owner',
          OwnedBy(testAccount),
        ),
      );
      final before = editable(disk.contents);
      expect(
        await store.commitAs(
          otherAccount,
          strategyId,
          movePatch('theirs'),
          seen: await seenIn(store),
        ),
        anotherAccountsWork(),
      );
      expect(
        await store.record(otherAccount, strategyId, const [
          ConnectionReturned(),
        ]),
        anotherAccountsWork(),
      );
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('mine again'),
          seen: await seenIn(store),
        ),
        refusedWith<QueueHeld>(),
      );
      expect(sameContents(disk.contents, before), isTrue);
    });

    test('for a result that names another strategy', () async {
      final (store, storage) = await withWork();
      final before = editable(storage.contents);
      final elsewhere = BaseArrived(
        headerReadOf(otherStrategyRows()),
        session: (await syncOf(store)).queue.session.number,
        from: await readStartOf(store),
      );
      expect(
        await store.record(otherAccount, strategyId, [elsewhere]),
        anotherAccountsWork(),
      );
      expect(
        await store.record(testAccount, strategyId, [elsewhere]),
        refusedWith<ResultOutOfPlace>(),
      );
      expect(sameContents(storage.contents, before), isTrue);
    });
  });

  test('a call refused for another account, first after a reopen, loads the '
      'strategy exactly as a read does and nothing more', () async {
    final storage = MemoryStorage();
    final store = await openCloudStore(MemoryEngine(storage));
    await addCloud(store, initialRows());
    await store.close();
    final saved = editable(storage.contents);

    final (refusedEngine, counts) = counting(
      MemoryEngine(MemoryStorage(editable(saved))),
    );
    final refusedDisk = MemoryStorage(editable(saved));
    final refusing = await openCloudStore(MemoryEngine(refusedDisk));
    final refusingChanges = <String>[];
    refusing.changes.listen((change) => refusingChanges.add(describe(change)));
    final reading = await openCloudStore(
      MemoryEngine(MemoryStorage(editable(saved))),
    );
    final readingChanges = <String>[];
    reading.changes.listen((change) => readingChanges.add(describe(change)));
    final counted = await openCloudStore(refusedEngine);
    expect(listOf(refusing).strategies.single.sync, isA<CloudUnverified>());

    expect(
      await refusing.record(otherAccount, strategyId, const [AccountChanged()]),
      anotherAccountsWork(),
    );
    expect(
      await counted.record(otherAccount, strategyId, const [AccountChanged()]),
      anotherAccountsWork(),
    );
    expect(counts.commits, 0);
    expect(sameContents(refusedDisk.contents, saved), isTrue);

    await reading.readStrategy(strategyId);
    await pumpEventQueue();
    expect(refusingChanges, isNotEmpty);
    expect(refusingChanges, readingChanges);
    expect(listOf(refusing).strategies.single.sync, isA<KeptInCloud>());
    expect(
      '${listOf(refusing).strategies.single.toJson()}',
      '${listOf(reading).strategies.single.toJson()}',
    );
    final refused = await syncOf(refusing);
    final read = await syncOf(reading);
    expect(refused.queue, read.queue);
    expect(refused.queue.nextAttempt, read.queue.nextAttempt);
    expect(refused.queue.nextSession, read.queue.nextSession);
    expect(refused.queue.session, read.queue.session);

    for (final store in [refusing, reading]) {
      await store.record(testAccount, strategyId, const [ConnectionReturned()]);
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('next'),
          seen: await seenIn(store),
        ),
      );
    }
    final refusedNext = await syncOf(refusing);
    final readNext = await syncOf(reading);
    expect(refusedNext.queue.session.number, readNext.queue.session.number);
    expect(
      (await claimAll(refusing)).attempt,
      (await claimAll(reading)).attempt,
    );
  });

  group('when an earlier refusal comes first, another account still applies '
      'and saves nothing', () {
    Future<void> expectNothing(
      LibraryStore store,
      MemoryStorage disk,
      Counts counts,
      Matcher refusal,
      StrategyRead seen,
    ) async {
      final before = editable(disk.contents);
      final commitsBefore = counts.commits;
      for (final call in <Future<Saving<Object?, CommitRefusal>> Function()>[
        () => store.commitAs(
          otherAccount,
          strategyId,
          movePatch('theirs'),
          seen: seen,
        ),
        () => store.commitAllAs(otherAccount, strategyId, [
          movePatch('theirs'),
        ], seen: seen),
        () => store.record(otherAccount, strategyId, const [
          ConnectionReturned(),
        ]),
        () => store.discardUnreadableQueue(
          otherAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
      ]) {
        expect(await call(), refusal);
      }
      expect(counts.commits, commitsBefore);
      expect(sameContents(disk.contents, before), isTrue);
    }

    test('a missing strategy row', () async {
      final (store, storage) = await withWork();
      final seen = await seenIn(store);
      await store.close();
      final contents = editable(storage.contents);
      contents[area]!.remove('strategy');
      final disk = MemoryStorage(contents);
      final (engine, counts) = counting(MemoryEngine(disk));
      final reopened = await openCloudStore(engine);
      await expectNothing(
        reopened,
        disk,
        counts,
        isA<Refused<Object?, CommitRefusal>>().having(
          (refused) => refused.reason,
          'reason',
          anyOf(isA<StrategyNotReadable>(), isA<NoSuchStrategy>()),
        ),
        seen,
      );
    });

    test('a read that fails', () async {
      final (store, storage) = await withWork();
      final seen = await seenIn(store);
      await store.close();
      final disk = MemoryStorage(editable(storage.contents));
      final (counted, counts) = counting(MemoryEngine(disk));
      final failing = WrappingEngine(counted, FailingListingsLease.new);
      final reopened = await openCloudStore(failing);
      await expectNothing(
        reopened,
        disk,
        counts,
        isA<NotSaved<Object?, CommitRefusal>>(),
        seen,
      );
    });
  });

  test('an edit of a cloud strategy that names no account is refused, and one '
      'of a local strategy that names an account is refused', () async {
    final (cloud, cloudDisk) = await withWork();
    final before = editable(cloudDisk.contents);
    expect(
      await cloud.commit(strategyId, movePatch('nobody', elementId: 'e2')),
      refusedWith<AccountNeeded>(),
    );
    expect(
      await cloud.commitAll(strategyId, [movePatch('nobody', elementId: 'e2')]),
      refusedWith<AccountNeeded>(),
    );
    expect(sameContents(cloudDisk.contents, before), isTrue);

    final localDisk = MemoryStorage();
    final local = await openCloudStore(MemoryEngine(localDisk));
    savedValue(await local.putStrategy(initialRows()));
    final localBefore = editable(localDisk.contents);
    expect(
      await local.commitAs(
        testAccount,
        strategyId,
        movePatch('someone'),
        seen: await seenIn(local),
      ),
      refusedWith<NotACloudStrategy>(),
    );
    expect(sameContents(localDisk.contents, localBefore), isTrue);
    savedValue(await local.commit(strategyId, movePatch('here')));
  });

  group('a cloud row without its account', () {
    test('holds the strategy, whose work then names no owner', () async {
      final (store, disk) = await reopenedWithCloudRow(
        (row) => {...row}..remove('account'),
      );
      final before = editable(disk.contents);
      final content = strategyOf(await store.readStrategy(strategyId));
      expect(
        content.sync,
        isA<CloudHeld>()
            .having((held) => held.owner, 'owner', const OwnerUnreadable())
            .having((held) => held.rows.map((row) => row.ref.name), 'rows', [
              'cloud',
            ]),
      );
      expect(
        listOf(store).strategies.single.sync,
        isA<KeptInCloud>()
            .having((sync) => sync.owner, 'owner', const OwnerUnreadable())
            .having((sync) => sync.tally.standing, 'standing', Standing.held),
      );
      expect(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('next'),
          seen: await seenIn(store),
        ),
        refusedWith<QueueHeld>(),
      );
      expect(
        await store.record(testAccount, strategyId, const []),
        refusedWith<QueueHeld>(),
      );
      expect(sameContents(disk.contents, before), isTrue);
    });

    test('permits nothing: no account may discard the held work, and '
        'nothing is written', () async {
      final (store, disk) = await reopenedWithCloudRow(
        (row) => {...row}..remove('account'),
      );
      final before = editable(disk.contents);
      for (final account in [testAccount, otherAccount]) {
        expect(
          await store.discardUnreadableQueue(
            account,
            strategyId,
            const DiscardsUnsentWork(),
          ),
          refusedWith<OwnerNotRead>(),
        );
      }
      expect(sameContents(disk.contents, before), isTrue);
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.owner,
          'owner',
          const OwnerUnreadable(),
        ),
      );
    });

    test(
      'an account that is not a string is the same as a missing one',
      () async {
        final (store, _) = await reopenedWithCloudRow(
          (row) => {...row, 'account': 7},
        );
        expect(
          strategyOf(await store.readStrategy(strategyId)).sync,
          isA<CloudHeld>().having(
            (held) => held.owner,
            'owner',
            const OwnerUnreadable(),
          ),
        );
      },
    );

    test('an empty account is the same as a missing one', () async {
      final (store, _) = await reopenedWithCloudRow(
        (row) => {...row, 'account': ''},
      );
      expect(
        strategyOf(await store.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.owner,
          'owner',
          const OwnerUnreadable(),
        ),
      );
    });
  });

  test('damage to another fact in the cloud row keeps its account: the '
      'queue is held for its owner, another account cannot discard it, and '
      'the owner can', () async {
    final (store, disk) = await reopenedWithCloudRow(
      (row) => {...row, 'presence': 'not a presence'},
    );
    expect(
      strategyOf(await store.readStrategy(strategyId)).sync,
      isA<CloudHeld>().having(
        (held) => held.owner,
        'owner',
        OwnedBy(testAccount),
      ),
    );
    final before = editable(disk.contents);
    expect(
      await store.discardUnreadableQueue(
        otherAccount,
        strategyId,
        const DiscardsUnsentWork(),
      ),
      anotherAccountsWork(),
    );
    expect(sameContents(disk.contents, before), isTrue);
    savedValue(
      await store.discardUnreadableQueue(
        testAccount,
        strategyId,
        const DiscardsUnsentWork(),
      ),
    );
    expect((await syncOf(store)).owner, testAccount);
  });

  test(
    'another account cannot discard held work whose owner is known',
    () async {
      final (store, storage) = await withWork();
      await store.close();
      final contents = editable(storage.contents);
      contents[area]!['pending/999'] = 'not a queue row';
      final held = MemoryStorage(contents);
      final reopened = await openCloudStore(MemoryEngine(held));
      expect(
        strategyOf(await reopened.readStrategy(strategyId)).sync,
        isA<CloudHeld>().having(
          (held) => held.owner,
          'owner',
          OwnedBy(testAccount),
        ),
      );
      final before = editable(held.contents);
      expect(
        await reopened.discardUnreadableQueue(
          otherAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
        anotherAccountsWork(),
      );
      expect(sameContents(held.contents, before), isTrue);
      savedValue(
        await reopened.discardUnreadableQueue(
          testAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
      );
      expect((await syncOf(reopened)).owner, testAccount);
    },
  );

  group('the sync state of an account', () {
    final work = Tally(
      standing: Standing.good,
      waiting: const {Underway.unsent: 2},
    );
    final held = Tally(standing: Standing.held, unreadable: 1);
    final deleted = Tally(standing: Standing.deletedOnServer);
    final accessLost = Tally(standing: Standing.editAccessLost);
    String stateOf(SyncState state) => switch (state) {
      AllSaved() => 'allSaved',
      Outstanding(:final face) => face.name,
    };

    final viewers = <String, SignedIn>{
      'signed out': const SignedOut(),
      'the owner': SignedInAs(testAccount),
      'someone else': SignedInAs(otherAccount),
    };
    final strategies = <String, (CloudOwner, Tally)>{
      'readable with work': (OwnedBy(testAccount), work),
      'readable and empty': (OwnedBy(testAccount), Tally.empty),
      'held, owner known': (OwnedBy(testAccount), held),
      'held, owner unreadable': (const OwnerUnreadable(), held),
      'deleted on the server, empty': (OwnedBy(testAccount), deleted),
      'edit access lost, empty': (OwnedBy(testAccount), accessLost),
    };
    const expected = <String, Map<String, (String, String)>>{
      'signed out': {
        'readable with work': ('signedOut', 'signedOut'),
        'readable and empty': ('signedOut', 'signedOut'),
        'held, owner known': ('signedOut', 'signedOut'),
        'held, owner unreadable': ('ownerUnreadable', 'ownerUnreadable'),
        'deleted on the server, empty': ('signedOut', 'signedOut'),
        'edit access lost, empty': ('signedOut', 'signedOut'),
      },
      'the owner': {
        'readable with work': ('sending', 'offline'),
        'readable and empty': ('allSaved', 'allSaved'),
        'held, owner known': ('unreadableWork', 'unreadableWork'),
        'held, owner unreadable': ('ownerUnreadable', 'ownerUnreadable'),
        'deleted on the server, empty': ('deletedOnServer', 'deletedOnServer'),
        'edit access lost, empty': ('editAccessLost', 'editAccessLost'),
      },
      'someone else': {
        'readable with work': ('notThisAccount', 'notThisAccount'),
        'readable and empty': ('notThisAccount', 'notThisAccount'),
        'held, owner known': ('heldForAnotherAccount', 'heldForAnotherAccount'),
        'held, owner unreadable': ('ownerUnreadable', 'ownerUnreadable'),
        'deleted on the server, empty': ('notThisAccount', 'notThisAccount'),
        'edit access lost, empty': ('notThisAccount', 'notThisAccount'),
      },
    };
    for (final MapEntry(key: viewer, value: signedIn) in viewers.entries) {
      for (final MapEntry(key: strategy, value: (owner, tally))
          in strategies.entries) {
        test('$viewer, $strategy', () {
          final (online, offline) = expected[viewer]![strategy]!;
          expect(
            stateOf(
              syncStateOf(
                owner,
                tally,
                network: Network.online,
                signedIn: signedIn,
              ),
            ),
            online,
            reason: 'online',
          );
          expect(
            stateOf(
              syncStateOf(
                owner,
                tally,
                network: Network.offline,
                signedIn: signedIn,
              ),
            ),
            offline,
            reason: 'offline',
          );
        });
      }
    }

    test('counts only that account\'s strategies, and names every other '
        'account that holds work', () {
      final sync = accountSyncState(
        [
          (owner: OwnedBy(testAccount), tally: work),
          (owner: OwnedBy(otherAccount), tally: work),
          (owner: OwnedBy(Account('account-c')), tally: Tally.empty),
          (owner: const OwnerUnreadable(), tally: held),
        ],
        network: Network.online,
        signedIn: SignedInAs(testAccount),
      );
      expect(
        sync,
        isA<SignedInSync>()
            .having((sync) => sync.account, 'account', testAccount)
            .having((sync) => stateOf(sync.mine), 'mine', 'sending'),
      );
      expect(sync.others, {otherAccount: work});
      expect(sync.ownerUnreadable, held);
    });

    test('signed out is its own state, apart from signed in with nothing to '
        'send', () {
      final signedOut = accountSyncState(
        [(owner: OwnedBy(testAccount), tally: work)],
        network: Network.online,
        signedIn: const SignedOut(),
      );
      expect(signedOut, isA<SignedOutSync>());
      expect(signedOut.others, {testAccount: work});
      expect(
        accountSyncState(
          const [],
          network: Network.online,
          signedIn: SignedInAs(testAccount),
        ),
        isA<SignedInSync>().having(
          (sync) => stateOf(sync.mine),
          'mine',
          'allSaved',
        ),
      );
    });
  });
}
