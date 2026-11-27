import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus_library/icarus_library.dart';

import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

import 'live_pages.dart';

void main() {
  group('a live page answer decodes only the rows the store does not hold', () {
    test(
        'the first answer of a page the store does not hold decodes all '
        '$heavyItems, the same answer again decodes none, and an answer with '
        'one row changed decodes exactly that one', () {
      inWorld((world) {
        fillServerPage(world, heavyItems);
        world.sender.liveOpened(strategyId, openPage);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 1));
        expect(world.server.readsOf(strategyId), ['list']);

        expect(deliver(world), heavyItems);
        expect(revisionsInStore(world), revisionsOnServer(world));

        expect(deliver(world), 0);
        expect(revisionsInStore(world), revisionsOnServer(world));

        world.teammateMoves(1);
        expect(deliver(world), 1);
        expect(revisionsInStore(world), revisionsOnServer(world));
        expect(world.server.readsOf(strategyId), ['list']);
      }, addStrategy: false);
    });

    test(
        'the first answer of a watch on a page the store already holds from '
        'its own read decodes none of the rows it holds', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, openPage);
        expect(deliver(world), 0);
        world.teammateMoves(1);
        expect(deliver(world), 1);
        expect(revisionsInStore(world), revisionsOnServer(world));
      });
    });

    test(
        'with an unsent edit to an item drawn at the revision it predicts, '
        'a teammate\'s edit that the server gives that same revision is '
        'what the queue is handed, not the unsent edit', () {
      inWorld((world) {
        world.commitMove(1);
        final drawn = world.firstElement();
        final before = world.server.rows[strategyId]!.element(drawn.publicId)!
            as LiveElement;
        world.server
            .teammate(strategyId, World.moveOf(before, 501, 'teammate-1'));
        final teammate = world.server.rows[strategyId]!.element(drawn.publicId)!
            as LiveElement;
        expect(teammate.revision, drawn.revision);
        expect(teammate.payload, isNot(drawn.payload));

        world.sender
          ..liveOpened(strategyId, openPage)
          ..livePageArrived(
            strategyId,
            openPage,
            servedAccount,
            LivePageAnswer(
              remotePageOf(world),
              pagePublicId: pageId,
              point: world.server.stamp(),
            ),
          );
        world.settle(const Duration(seconds: 1));

        final taken = pageResultsWritten(world).last.elements.firstWhere(
              (row) => row.publicId == drawn.publicId,
            ) as LiveElement;
        expect(taken.revision, teammate.revision);
        expect(taken.payload, teammate.payload);
      });
    });

    test(
        'an answer without a row the memo held drops it from the memo, so the '
        'row coming back at the same identity is decoded again', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, openPage);
        expect(deliver(world), 0);
        final whole = remotePageOf(world);
        final before = world.sender.liveRowsDecoded;
        world.sender.livePageArrived(
          strategyId,
          openPage,
          servedAccount,
          LivePageAnswer(
            RemotePageSnapshot(
              page: whole.page,
              content: whole.content,
              elements: whole.elements.skip(1).toList(),
              lineups: whole.lineups,
              assetsById: whole.assetsById,
            ),
            pagePublicId: pageId,
            point: world.server.stamp(),
          ),
        );
        world.settle();
        expect(world.sender.liveRowsDecoded - before, 0);
        expect(deliver(world), 1);
      });
    });

    test(
        'a row the store holds as unreadable at the same identity stays '
        'unreadable without a second decode', () {
      inWorld((world) {
        unreadableOnServer(world, 'unreadable-1');
        world.sender
          ..liveOpened(strategyId, openPage)
          ..livePageArrived(
            strategyId,
            openPage,
            servedAccount,
            LivePageAnswer(
              remotePageOf(world),
              pagePublicId: pageId,
              point: world.server.stamp(),
            ),
          );
        world.settle();
        expect(
          pageResultsWritten(world).last.elements.firstWhere(
                (row) => row.publicId == 'unreadable-1',
              ),
          isA<UnreadableElement>(),
        );

        expect(deliver(world), 0);
        expect(
          pageResultsWritten(world).last.elements.firstWhere(
                (row) => row.publicId == 'unreadable-1',
              ),
          isA<UnreadableElement>(),
        );
      });
    });

    test(
        'converted, then a newer result lands, then admitted: the queue ends '
        'at the newer result', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, openPage);
        deliver(world);
        world.teammateMoves(1);
        final older = LivePageAnswer(
          remotePageOf(world),
          pagePublicId: pageId,
          point: world.server.stamp(),
        );
        world.slowStore.baseWritesWait = const Duration(seconds: 1);
        world.sender
            .livePageArrived(strategyId, openPage, servedAccount, older);
        world.async.elapse(const Duration(milliseconds: 100));
        world.teammateMoves(2);
        world.recordRead([
          (world.server.answerNow(ReadCall(strategyId, pageId, servedAccount))
                  as StoreReadAnswered)
              .base,
        ]);
        world.slowStore.baseWritesWait = Duration.zero;
        world.settle(const Duration(minutes: 1));
        expect(revisionsInStore(world), revisionsOnServer(world));
        expect(
          world.cloud().queue.shown.pageRead(pageId),
          isNot(isA<ReadRefused>()),
        );
      });
    });
  });
}
