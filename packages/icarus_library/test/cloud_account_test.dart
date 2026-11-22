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
  savedValue(await store.commitAs(testAccount, strategyId, movePatch('mine')));
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
            Future<Saving<Object?, CommitRefusal>> Function(LibraryStore),
          )
        >[
          (
            'an edit',
            (store) => store.commitAs(
              otherAccount,
              strategyId,
              movePatch('theirs', elementId: 'e2'),
            ),
          ),
          (
            'a batch of edits',
            (store) => store.commitAllAs(otherAccount, strategyId, [
              movePatch('theirs', elementId: 'e2'),
            ]),
          ),
          (
            'a claim',
            (store) => store.record(otherAccount, strategyId, [
              BatchClaimed(
                clientId: clientId,
                opIds: const ['mine'],
                at: fixedClock(),
              ),
            ]),
          ),
          (
            'an account change',
            (store) => store.record(otherAccount, strategyId, [
              const AccountChanged(),
            ]),
          ),
          (
            'a connection',
            (store) => store.record(otherAccount, strategyId, [
              const ConnectionReturned(),
            ]),
          ),
          (
            'a result',
            (store) => store.record(otherAccount, strategyId, [
              BaseArrived(headerReadOf(initialRows()), session: 1),
            ]),
          ),
          (
            'a look that records no event',
            (store) => store.record(otherAccount, strategyId, const []),
          ),
        ];
    for (final (label, call) in calls) {
      test(label, () async {
        final (store, storage) = await withWork();
        final before = editable(storage.contents);
        final queue = (await syncOf(store)).queue;
        expect(await call(store), anotherAccountsWork());
        expect(sameContents(storage.contents, before), isTrue);
        expect((await syncOf(store)).queue, queue);
        final sent = await claimAll(store);
        expect(sent.ops.map((op) => op.opId), ['mine']);
      });
    }
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
      await local.commitAs(testAccount, strategyId, movePatch('someone')),
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
        await store.commitAs(testAccount, strategyId, movePatch('next')),
        refusedWith<QueueHeld>(),
      );
      expect(
        await store.record(testAccount, strategyId, const []),
        refusedWith<QueueHeld>(),
      );
      expect(sameContents(disk.contents, before), isTrue);
    });

    test('is cleared only by discarding the held work, after which the '
        'strategy is the discarding account\'s', () async {
      final (store, _) = await reopenedWithCloudRow(
        (row) => {...row}..remove('account'),
      );
      savedValue(
        await store.discardUnreadableQueue(
          otherAccount,
          strategyId,
          const DiscardsUnsentWork(),
        ),
      );
      final sync = await syncOf(store);
      expect(sync.owner, otherAccount);
      expect(sync.queue.entries, isEmpty);
    });

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
        signedIn: testAccount,
      );
      expect(
        sync.mine,
        isA<Outstanding>()
            .having((state) => state.face, 'face', Face.sending)
            .having((state) => state.tally, 'tally', work),
      );
      expect(sync.others, {otherAccount: work});
      expect(sync.ownerUnreadable, held);
    });

    test('signed out, no work is anyone\'s own', () {
      final sync = accountSyncState(
        [(owner: OwnedBy(testAccount), tally: work)],
        network: Network.online,
        signedIn: null,
      );
      expect(sync.mine, isA<AllSaved>());
      expect(sync.others, {testAccount: work});
    });

    test('a strategy\'s work is another account\'s when the signed-in '
        'account is not its owner', () {
      for (final signedIn in [otherAccount, null]) {
        expect(
          syncStateOf(
            OwnedBy(testAccount),
            work,
            network: Network.online,
            signedIn: signedIn,
          ),
          isA<Outstanding>().having(
            (state) => state.face,
            'face',
            Face.notThisAccount,
          ),
        );
      }
      expect(
        syncStateOf(
          OwnedBy(testAccount),
          work,
          network: Network.online,
          signedIn: testAccount,
        ),
        isA<Outstanding>().having((state) => state.face, 'face', Face.sending),
      );
    });
  });
}
