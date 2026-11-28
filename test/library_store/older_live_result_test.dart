import 'package:flutter_test/flutter_test.dart';

import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_sender_live_test.dart'
    show
        liveList,
        listReads,
        livePage,
        storedPageName,
        teammateRenamesPage,
        theListRead;
import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

void main() {
  test(
      'a live page list that answers before the take-up and is older than the '
      'take-up\'s own read owes nothing: one list read, not two', () {
    inWorld((world) {
      final from = world.async.elapsed;
      world.openInEditor(strategyId);
      world.sender.liveOpened(strategyId, theListRead);
      final first = liveList(world);
      world.sender.liveArrived(strategyId, theListRead, servedAccount, first);
      teammateRenamesPage(world, 'Renamed before the take-up');
      world.sender.adopt(strategyId);
      world.settle(const Duration(seconds: 30));
      expect(world.holds(), isTrue);
      expect(storedPageName(world), 'Renamed before the take-up');
      expect(listReads(world, from), hasLength(1));
    }, addStrategy: false);
  });

  test(
      'a live page list newer than the take-up\'s read is still taken, with '
      'no read of its own', () {
    inWorld((world) {
      final from = world.async.elapsed;
      world.openInEditor(strategyId);
      world.sender.liveOpened(strategyId, theListRead);
      world.sender.adopt(strategyId);
      world.settle(const Duration(seconds: 30));
      expect(listReads(world, from), hasLength(1));
      teammateRenamesPage(world, 'Renamed after the take-up');
      world.sender
          .liveArrived(strategyId, theListRead, servedAccount, liveList(world));
      world.settle(const Duration(seconds: 30));
      expect(storedPageName(world), 'Renamed after the take-up');
      expect(listReads(world, from), hasLength(1));
    }, addStrategy: false);
  });

  test(
      'an older live page result refused while the queue owes a read of the '
      'page still gets that read, from the queue\'s own need, once', () {
    inWorld((world) {
      const subject = ReadOfPage(pageId);
      world.sender.liveOpened(strategyId, subject);
      final older = livePage(world);
      world.teammateMoves(1);
      world.sender
          .liveArrived(strategyId, subject, servedAccount, livePage(world));
      world.settle();
      final drawn = world.firstElement();
      world.server.answerNext(strategyId, (call) {
        world.server.rows[strategyId] =
            world.server.rows[strategyId]!.withRows([
          LiveElement(
            publicId: drawn.publicId,
            pagePublicId: drawn.pagePublicId,
            payload: drawn.payload,
            sortIndex: drawn.sortIndex,
            revision: 1,
            unknownFields:
                jsonObject({'createdAt': createdAtOf(drawn)! + 1000}),
          ),
        ]);
        return Future.value(
          StoreBatchAnswered(
            [
              RejectedAnswer(
                call.opIds.single,
                RejectionReason.rowReplaced,
                const NoServerCopy(),
              ),
            ],
            complete: true,
            point: world.server.stamp(),
          ),
        );
      });
      final from = world.async.elapsed;
      world.commitMove(2);
      world.settle(const Duration(milliseconds: 500));
      world.sender.liveArrived(strategyId, subject, servedAccount, older);
      world.settle(const Duration(seconds: 30));
      expect(
        world.sender.store.reports
            .whereType<EventNotApplied>()
            .map((report) => report.why),
        contains('${const OlderResult()}'),
      );
      expect(world.sender.liveOwed, 0);
      expect(
        [
          for (final call in world.server.readCalls)
            if (call.at!.difference(start) >= from) '${call.page} ${call.why}',
        ],
        ['$pageId the queue asked for it'],
      );
      world.sender.liveClosed(strategyId, subject);
      world.settle();
    });
  });
}
