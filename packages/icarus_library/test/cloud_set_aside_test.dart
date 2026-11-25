import 'package:icarus_library/icarus_library.dart';
import 'package:test/test.dart';

import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

const laterLife = fixtureLife + 86400000;

StrategyRowSet replaced(StrategyRowSet rows, {int life = laterLife}) =>
    StrategyRowSet(
      strategy: strategyRow(
        createdAt: DateTime.fromMillisecondsSinceEpoch(life, isUtc: true),
      ),
      pages: rows.pages,
      settings: rows.settings,
      elements: rows.elements,
      lineupGroups: rows.lineupGroups,
    );

Client withTwoEdits() {
  final client = Client();
  client.edit(movePatch('move'));
  final attempt = client.claim(['move']);
  client.edit(movePatch('later', elementId: 'e2'));
  client.must(TransportFailed(attempt, TransportFailure.network, at: now));
  return client;
}

List<String> setAsideIds(CloudQueue queue) => switch (queue.strategy.setAside) {
  SetAside(:final entries) => [for (final entry in entries) entry.id],
  NothingSetAside() => const [],
};

final class CommitsSeen extends ForwardingLease {
  CommitsSeen(super.inner, this.seen, this.refuse);

  final List<List<Change>> seen;
  final bool Function(List<Change> changes) refuse;

  @override
  Future<Committing> commit(List<Change> changes) async {
    if (refuse(changes)) {
      return const CommitRefused(DeviceFailure('the disk is full'));
    }
    seen.add(changes);
    return super.commit(changes);
  }
}

bool setsAside(List<Change> changes) => changes.any(
  (change) =>
      change is Put &&
      change.key == 'cloud' &&
      change.value.contains('"setAside"'),
);

void main() {
  group('a page list of a later strategy life sets every edit aside in one '
      'step', () {
    test('every entry moves into the record together, and nothing is left '
        'that could be sent', () {
      final client = withTwoEdits();
      final before = client.queue;
      final result = transition(
        before,
        BaseArrived(
          headerReadOf(replaced(initialRows())),
          session: before.session.number,
        ),
        now: client.at,
      );
      final after = (result as Stepped).queue;
      expect(after.entries, isEmpty);
      expect(after.attempts, isEmpty);
      expect(after.landed, isEmpty);
      expect(setAsideIds(after), ['move', 'later']);
      expect(entryViews(after, client.at), isEmpty);
      expect(result.effects, contains(const StrategySetAside(2)));
      expect((after.strategy.setAside as SetAside).entries, before.entries);
    });

    test('a page result whose page has another life owes the page list, '
        'and the list it brings sets the edits aside', () {
      final client = withTwoEdits();
      final again = replaced(initialRows()).withRows([
        bornIn(
          LivePage(
            publicId: 'page-a',
            strategyPublicId: strategyId,
            name: 'Page 1',
            sortIndex: 0,
            isAttack: true,
            revision: 1,
          ),
          laterLife,
        ),
      ]);
      client.arrive(pageReadOf(again, 'page-a'));
      expect(isDebt(client.queue.shown.list), isTrue);
      expect(setAsideIds(client.queue), isEmpty);
      client.arrive(headerReadOf(again));
      expect(setAsideIds(client.queue), ['move', 'later']);
    });

    test('a list of the same life, or an earlier one, sets nothing aside', () {
      for (final life in [
        strategyCreatedAt.millisecondsSinceEpoch,
        strategyCreatedAt.millisecondsSinceEpoch - 1000,
      ]) {
        final client = withTwoEdits();
        client.arrive(headerReadOf(replaced(initialRows(), life: life)));
        expect(setAsideIds(client.queue), isEmpty);
        expect(client.queue.entries, hasLength(2));
      }
    });

    test('a refusal as STRATEGY_REPLACED is paid only by the list of a later '
        'life, which sets the edits aside', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      client.arrive(headerReadOf(initialRows()));
      expect(setAsideIds(client.queue), isEmpty);
      expect(isDebt(client.queue.shown.list), isTrue);
      client.arrive(headerReadOf(replaced(initialRows())));
      expect(setAsideIds(client.queue), ['move']);
      expect(client.queue.shown.list, const ReadThisSession());
    });
  });

  group('nothing set aside is sent, drawn or counted as waiting', () {
    test('a set-aside op cannot be claimed', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      for (final id in ['move', 'later']) {
        expect(
          client.step(BatchClaimed(clientId: clientId, opIds: [id], at: now)),
          isA<NotApplicable>(),
        );
      }
    });

    test('a set-aside move is not drawn over the new strategy', () {
      final client = Client();
      client.edit(movePatch('move', x: 40));
      client.base = replaced(initialRows());
      client.read(client.base);
      expect(
        client.visible.element('e1')!.toJson(),
        initialRows().element('e1')!.toJson(),
      );
    });

    test('the tally counts the edits as set aside, none as waiting, and the '
        'status says how many were not applied', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      final tally = Tally.of(client.queue, now);
      expect(tally.stillGoing, 0);
      expect(tally.needingYou, 0);
      expect(tally.setAside, 2);
      final state = syncStateOf(
        OwnedBy(testAccount),
        tally,
        network: Network.online,
        signedIn: SignedInAs(testAccount),
      );
      expect(
        state,
        isA<Outstanding>().having(
          (state) => state.face,
          'face',
          Face.strategyReplaced,
        ),
      );
      expect(
        placeholderWordsFor(state),
        allOf(startsWith('PLACEHOLDER'), contains('2 edits were not applied')),
      );
    });

    test('an edit made after the replacement goes out in the new life', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      client.edit(movePatch('fresh', elementId: 'e2'));
      client.claim(['fresh']);
      expect(
        client.effects.whereType<SendBatch>().last.strategyLife,
        laterLife,
      );
    });
  });

  group('Keep mine is not offered for an edit of a replaced strategy', () {
    QueueEvent keepMine(Client client) => UserKeptMine(
      'move',
      movePatch('mine', x: 55, expected: 1),
      authored: const KeptOverServer(1, life: fixtureLife),
    );

    test('after STRATEGY_REPLACED the edit waits for the list: nothing asks '
        'the user, and Keep mine does not apply', () {
      final client = Client();
      client.edit(movePatch('move'));
      final attempt = client.claim(['move']);
      client.must(BatchRefused(attempt, BatchRefusal.strategyReplaced));
      expect(client.view('move').state, isNot(isA<NeedsUser>()));
      expect(Tally.of(client.queue, now).needingYou, 0);
      expect(client.step(keepMine(client)), isA<NotApplicable>());
    });

    test('once set aside the edit has no view for the app to offer anything '
        'on, and Keep mine does not apply', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      expect(entryViews(client.queue, client.at).keys, isEmpty);
      expect(Tally.of(client.queue, now).needingYou, 0);
      expect(client.step(keepMine(client)), isA<NotApplicable>());
      expect(setAsideIds(client.queue), ['move', 'later']);
    });
  });

  group('the user discarding what was set aside', () {
    test('is the only way out, and empties the record', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      final result = client.step(const UserDiscardedReplaced());
      expect((result as Stepped).effects, contains(const SetAsideDiscarded(2)));
      expect(setAsideIds(client.queue), isEmpty);
      expect(Tally.of(client.queue, now).setAside, 0);
      expect(client.step(const UserDiscardedReplaced()), isA<NotApplicable>());
    });

    test('no other user action reaches a set-aside op', () {
      final client = withTwoEdits();
      client.read(replaced(initialRows()));
      for (final action in const <QueueEvent>[
        UserDiscarded('move'),
        UserUsedCloud('move'),
        UserRetried('move'),
      ]) {
        expect(client.step(action), isA<NotApplicable>());
      }
      expect(setAsideIds(client.queue), ['move', 'later']);
    });
  });

  group('in the store', () {
    Future<(LibraryStore, MemoryStorage)> withEdits() async {
      final storage = MemoryStorage();
      final store = await openCloudStore(MemoryEngine(storage));
      await addCloud(store, initialRows());
      await recordAll(store, [const AppRestarted(build: build)]);
      savedValue(
        await store.commitAs(testAccount, strategyId, movePatch('move')),
      );
      savedValue(
        await store.commitAs(
          testAccount,
          strategyId,
          movePatch('later', elementId: 'e2'),
        ),
      );
      await store.close();
      return (store, storage);
    }

    Future<Saving<Recorded, CommitRefusal>> listOfALaterLife(
      LibraryStore store,
    ) async {
      await recordAll(store, [const AppRestarted(build: build)]);
      return store.record(testAccount, strategyId, [
        BaseArrived(
          headerReadOf(replaced(initialRows())),
          session: await sessionOf(store),
        ),
      ]);
    }

    test('the set-aside record and the removal of every queued row are one '
        'commit', () async {
      final (_, storage) = await withEdits();
      final seen = <List<Change>>[];
      final store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => CommitsSeen(lease, seen, (_) => false),
        ),
      );
      savedValue(await listOfALaterLife(store));
      final commit = seen.singleWhere(setsAside);
      expect([
        for (final change in commit)
          if (change is Delete && change.key.startsWith('pending/')) change.key,
      ], hasLength(2));
      expect(
        storage.contents[strategyArea(strategyId)]!.keys.where(
          (key) => key.startsWith('pending/'),
        ),
        isEmpty,
      );
    });

    test('a restart before the set-aside is stored finds every edit still '
        'queued; one after finds every edit set aside', () async {
      final (_, storage) = await withEdits();
      var refuse = true;
      var store = await openCloudStore(
        WrappingEngine(
          MemoryEngine(storage),
          (lease) => CommitsSeen(lease, [], (changes) {
            return refuse && setsAside(changes);
          }),
        ),
      );
      expect(
        await listOfALaterLife(store),
        isNot(isA<Saved<Recorded, CommitRefusal>>()),
      );
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final before = (await syncOf(store)).queue;
      expect([for (final entry in before.entries) entry.id], ['move', 'later']);
      expect(setAsideIds(before), isEmpty);
      refuse = false;
      savedValue(await listOfALaterLife(store));
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      final after = (await syncOf(store)).queue;
      expect(after.entries, isEmpty);
      expect(setAsideIds(after), ['move', 'later']);
      expect((after.strategy.setAside as SetAside).entries, before.entries);
    });

    test('adopting the new life drops everything held from the old one: the '
        'pages are read again before anything old is drawn', () async {
      final (_, storage) = await withEdits();
      final store = await openCloudStore(MemoryEngine(storage));
      savedValue(await listOfALaterLife(store));
      final queue = (await syncOf(store)).queue;
      expect(queue.shown.content, isEmpty);
      expect(queue.shown.rows, isEmpty);
      expect(queue.landed, isEmpty);
      expect(queue.shown.pagesToRead, {'page-a', 'page-b'});
      final page = await store.readPage(strategyId, 'page-a');
      expect((page as Found<PageContent>).value.elements, isEmpty);
    });
  });

  group('one strategy life per batch', () {
    test('an op written before the record knew its strategy life never '
        'shares a batch with one written after', () {
      final client = Client();
      client.queue = CloudQueue.start(build: build);
      client.edit(movePatch('unknown'));
      client.read(initialRows());
      client.edit(movePatch('known', elementId: 'e2'));
      final entries = {
        for (final entry in client.queue.entries)
          entry.id: (entry as PendingOp).strategyLife,
      };
      expect(entries, {
        'unknown': null,
        'known': strategyCreatedAt.millisecondsSinceEpoch,
      });
      expect(
        client.step(
          BatchClaimed(
            clientId: clientId,
            opIds: ['unknown', 'known'],
            at: now,
          ),
        ),
        isA<NotApplicable>(),
      );
    });
  });
}
