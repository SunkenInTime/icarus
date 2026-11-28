import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus_library/icarus_library.dart';

import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

void main() {
  group('a page is read when it is shown or owed', () {
    test(
        'a page the store already holds is not read again for being shown, '
        'even while its watch stays silent', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        world.sender.liveOpened(strategyId, const ReadOfPage(pageId));
        world.settle(const Duration(minutes: 1));
        expect(world.server.readCalls.skip(before), isEmpty);
      });
    });

    test(
        'a page whose held content the queue owes a read is read without '
        'being shown, and a page it neither owes nor shows is not', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
          world
            ..show(pageId)
            ..show('p2');
          world.connection = null;
          world.commitMove(1);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      contents[strategyArea(strategyId)]!['read/header'] = '{"version":99}';
      inWorld(
        (world) {
          final before = world.server.readCalls.length;
          world.settle(const Duration(minutes: 1));
          final pages = [
            for (final call in world.server.readCalls.skip(before))
              if (call.page case final page?) page,
          ];
          expect(world.cloud().queue.shown.content.keys, [pageId]);
          expect(pages, contains(pageId));
          expect(pages, isNot(contains('p2')));
          expect(world.server.applied, 1);
        },
        storage: MemoryStorage(contents),
        server: server,
        addStrategy: false,
      );
    });

    test(
        'a page the queue still owes a read once its edit is discarded is read '
        'without being shown', () {
      inWorld((world) {
        world.server.overrideRead = (call) => call.page == pageId
            ? const StoreReadLost(TransportFailure.network, 'held by the test')
            : null;
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
            StoreBatchAnswered(
              [
                for (final op in call.opIds)
                  RejectedAnswer(
                    op,
                    RejectionReason.rowReplaced,
                    const NoServerCopy(),
                  ),
              ],
              complete: true,
              point: world.server.stamp(),
            ),
          ),
        );
        world.commitMove(1);
        world.settle(const Duration(seconds: 3));
        Saving<Recorded, CommitRefusal>? discarded;
        world.store.record(servedAccount, strategyId, [
          const UserDiscarded('move-1'),
        ]).then((value) => discarded = value);
        world.async.flushMicrotasks();
        expect(discarded, isA<Saved<Recorded, CommitRefusal>>());
        expect(world.cloud().queue.entries, isEmpty);
        expect(
          owedReads(world.cloud().queue),
          contains(const PageResult(pageId)),
        );
        world.server.overrideRead = null;
        final before = world.server.readCalls.length;
        world.settle(const Duration(minutes: 10));
        expect(
          [
            for (final call in world.server.readCalls.skip(before))
              if (call.page != null) call.page,
          ],
          contains(pageId),
        );
        expect(owedReads(world.cloud().queue), isEmpty);
      });
    });

    List<String> pageReads(World world, int from) => [
          for (final call in world.server.readCalls.skip(from))
            if (call.page case final page?) page,
        ];

    test(
        'a page watch opened and answered before the sender attaches is known '
        'to it: the quiet page is read once', () {
      inWorld((world) {
        world.secondPageOnServer();
        world.sender.adopt(strategyId);
        world.settle();
        final live = LiveResultsToSender();
        const shown = ReadOfPage('p2');
        live.liveOpened(strategyId, shown);
        live.liveArrived(
          strategyId,
          shown,
          servedAccount,
          world.server.answerNow(ReadCall(strategyId, 'p2', servedAccount)),
        );
        final from = world.server.readCalls.length;
        world.settle(const Duration(minutes: 1));
        expect(pageReads(world, from), isEmpty);
        live.attach(world.sender);
        world.settle(const Duration(seconds: 15));
        expect(pageReads(world, from), ['p2']);
        world.settle(const Duration(minutes: 10));
        expect(pageReads(world, from), ['p2']);
        expect(world.cloud().queue.shown.content.keys, contains('p2'));
      }, addStrategy: false);
    });

    test(
        'a page watch opened while the old sender still waited for its first '
        'answer is known to the sender of the reopened store: the quiet page '
        'is read once, by the new sender', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      final live = LiveResultsToSender();
      const shown = ReadOfPage('p2');
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
          final from = world.server.readCalls.length;
          live
            ..attach(world.sender)
            ..liveOpened(strategyId, shown);
          world.settle();
          expect(pageReads(world, from), isEmpty);
          live.detach(world.sender);
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      inWorld(
        (world) {
          final from = world.server.readCalls.length;
          live.attach(world.sender);
          world.settle(const Duration(seconds: 15));
          expect(pageReads(world, from), ['p2']);
          world.settle(const Duration(minutes: 10));
          expect(pageReads(world, from), ['p2']);
          expect(world.cloud().queue.shown.content.keys, contains('p2'));
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
    });
  });
}
