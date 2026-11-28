import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/cloud/op_facts.dart' show renamed;
import 'package:test/test.dart';

import 'cloud_server.dart';
import 'cloud_store_support.dart';
import 'cloud_support.dart';
import 'store_support.dart';
import 'support.dart';

final theyDeleted = withOp(initialRows(), pageDelete('their-drop', 'page-b'));

final theyRestored = initialRows().withRows([
  initialRows().strategy.rewritten(revision: theyDeleted.strategy.revision + 1),
]);

final purged = withoutPage(theyDeleted, 'page-b');

Future<void> commit(LibraryStore store, StrategyOp op) async => savedValue(
  await store.commitAs(testAccount, strategyId, op, seen: await seenIn(store)),
);

Future<void> listed(LibraryStore store, StrategyRowSet server) async {
  await recordAll(store, [await arrivalIn(store, headerReadOf(server))]);
  for (final page in server.pages) {
    if (page is LivePage) {
      await recordAll(store, [
        await arrivalIn(store, pageReadOf(server, page.publicId)),
      ]);
    }
  }
}

Future<EntryView> viewOf(LibraryStore store, String id) async =>
    (await syncOf(store)).views[id]!;

Future<List<String>> sendable(LibraryStore store) async {
  final cloud = await syncOf(store);
  return [
    for (final entry in cloud.queue.entries)
      if (cloud.views[entry.id]?.sendable ?? false) entry.id,
  ];
}

Future<SendBatch> sendTo(LibraryStore store, Server server) async {
  final sent = await claimAll(store);
  await recordAll(store, [
    for (final op in sent.ops)
      OpAnswered(sent.attempt, server.apply(clientId, op), point: tick()),
  ]);
  return sent;
}

Future<LibraryStore> refusedOnB([MemoryStorage? storage]) async {
  final store = await openCloudStore(MemoryEngine(storage ?? MemoryStorage()));
  await addCloud(store, initialRows());
  await commit(store, movePatch('mine', elementId: 'e3', pageId: 'page-b'));
  await sendTo(store, Server()..rows = theyDeleted);
  return store;
}

Future<void> keepMine(LibraryStore store, String opId, String newId) async {
  final entry = (await syncOf(store)).queue.entry(opId)! as PendingOp;
  await recordAll(store, [
    UserKeptMine(
      opId,
      renamed(entry.op, newId),
      authored: const AuthoredNoRow(),
    ),
  ]);
}

void main() {
  group('a change the server refuses as its page deleted', () {
    test('needs the user with its own reason, counted on its own, and is '
        'never sent again by the queue', () async {
      final store = await refusedOnB();
      final view = await viewOf(store, 'mine');
      expect(view.state, const NeedsUser(RefusedAsPageDeleted()));
      expect(view.sendable, isFalse);
      final cloud = await syncOf(store);
      expect(cloud.tally.attention, {Attention.refusedAsPageDeleted: 1});
      expect(cloud.tally.waiting, isEmpty);
      for (final server in [theyDeleted, theyRestored, purged]) {
        await listed(store, server);
        expect(
          (await viewOf(store, 'mine')).state,
          const NeedsUser(RefusedAsPageDeleted()),
          reason: 'after a list of ${server.pages.map((p) => p.publicId)}',
        );
        expect(await sendable(store), isEmpty);
      }
    });

    test('a teammate restoring the page changes nothing by itself: the '
        'question stays until the player answers', () async {
      final store = await refusedOnB();
      await listed(store, theyRestored);
      final cloud = await syncOf(store);
      expect(cloud.queue.entries.map((entry) => entry.id), ['mine']);
      expect(cloud.tally.attention, {Attention.refusedAsPageDeleted: 1});
    });

    test('it reads the same after a restart: the reason comes from the '
        'stored refusal', () async {
      final storage = MemoryStorage();
      var store = await refusedOnB(storage);
      await store.close();
      store = await openCloudStore(MemoryEngine(storage));
      await recordAll(store, [const AppRestarted(build: build)]);
      expect(
        (await viewOf(store, 'mine')).state,
        const NeedsUser(RefusedAsPageDeleted()),
      );
    });

    test('restore: once the page is live again, keep mine sends the change '
        'under its new id and it lands once', () async {
      final store = await refusedOnB();
      final server = Server()..rows = theyRestored;
      await listed(store, theyRestored);
      await keepMine(store, 'mine', 'mine-kept');
      expect(await sendable(store), ['mine-kept']);
      final sent = await sendTo(store, server);
      expect(sent.ops.map((op) => op.opId), ['mine-kept']);
      expect(server.landed('mine-kept'), isTrue);
      expect(server.landed('mine'), isFalse);
      expect(
        (server.rows.element('e3')! as LiveElement).payload,
        movePatch('mine', elementId: 'e3', pageId: 'page-b').payload,
      );
      await listed(store, server.rows);
      expect((await syncOf(store)).queue.entries, isEmpty);
    });

    test('keep mine while the page is still in the trash is refused the '
        'same way and asks again', () async {
      final store = await refusedOnB();
      await keepMine(store, 'mine', 'mine-kept');
      await sendTo(store, Server()..rows = theyDeleted);
      expect(
        (await viewOf(store, 'mine-kept')).state,
        const NeedsUser(RefusedAsPageDeleted()),
      );
    });

    test('after a purge, keep mine is sent, refused as not found, and reaches '
        'the user like any refusal', () async {
      final store = await refusedOnB();
      await listed(store, purged);
      await keepMine(store, 'mine', 'mine-kept');
      expect(await sendable(store), ['mine-kept']);
      await sendTo(store, Server()..rows = purged);
      final view = await viewOf(store, 'mine-kept');
      expect(
        view.state,
        const NeedsUser(
          RefusedByServer(
            RejectedByServer(RejectionReason.notFound, NoServerCopy()),
          ),
        ),
        reason: '$view',
      );
    });

    test('discard lets it go and leaves nothing behind', () async {
      final store = await refusedOnB();
      await recordAll(store, [const UserDiscarded('mine')]);
      final cloud = await syncOf(store);
      expect(cloud.queue.entries, isEmpty);
      expect(cloud.tally.attention, isEmpty);
    });

    test('other work goes on: an edit on a live page sends and lands, and a '
        'later edit of the same item waits behind the question', () async {
      final store = await refusedOnB();
      await commit(store, movePatch('on-a', elementId: 'e1', x: 30));
      await commit(
        store,
        movePatch(
          'again-on-b',
          elementId: 'e3',
          expected: 2,
          x: 40,
          pageId: 'page-b',
        ),
      );
      expect(await sendable(store), ['on-a']);
      expect((await viewOf(store, 'again-on-b')).holds, [
        const BehindEntry('mine', Dependency.sameRow),
      ]);
      final server = Server()..rows = theyDeleted;
      await sendTo(store, server);
      expect(server.landed('on-a'), isTrue);
      final cloud = await syncOf(store);
      expect(cloud.tally.attention, {
        Attention.refusedAsPageDeleted: 1,
        Attention.waitingOnRefused: 1,
      });
    });
  });
}
