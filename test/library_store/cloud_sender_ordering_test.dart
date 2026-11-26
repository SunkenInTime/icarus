import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show pageId, strategyId;
import 'sender_world.dart';

Future<StoreBatchOutcome> rowReplaced(ServerCall call) => Future.value(
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
        point: stampedWhenAnswered,
      ),
    );

void main() {
  test(
      'a result read after a later connection\'s stamp opened a session, '
      'while the app\'s connection count has not moved, is labelled with the '
      'session the queue holds', () {
    inWorld((world) {
      world.settle();
      final first = world.cloud().queue.session.number;
      world.server.answerReadNext(strategyId, (call) {
        world.server.connection = 2;
        return Future.value(world.server.answerNow(call));
      });
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 10));
      final opened = world.cloud().queue.session;
      expect(opened.generation?.connection, 2);
      expect(opened.number, greaterThan(first));
      expect(world.connection, 1);
      final before = world.written().whereType<BaseArrived>().length;
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 10));
      final later =
          world.written().whereType<BaseArrived>().skip(before).toList();
      expect(later, isNotEmpty);
      expect(
        [for (final result in later) result.session],
        everyElement(opened.number),
      );
      expect(world.cloud().queue.session.number, opened.number);
    });
  });

  test(
      'a page read asked for after a refusal, while an earlier read of the '
      'page timed out unanswered on this connection, does not pay the '
      'refusal; the read after it does', () {
    inWorld((world) {
      world.settle();
      world.server.answerReadNext(
        strategyId,
        (call) => Completer<StoreReadOutcome>().future,
      );
      world.sender.owesFreshRead(strategyId, const ReadOfPage(pageId));
      world.settle(const Duration(seconds: 1));
      expect('${world.server.readCalls.last}', 'page $pageId');
      expect(world.server.readCalls.last.answered, isFalse);
      world.settle(timing.giveUpAfter);
      final reads = world.server.readCalls.length;
      world.server.answerNext(strategyId, rowReplaced);
      world.commitMove(1);
      while (world.server.readCalls.length == reads) {
        world.settle(const Duration(milliseconds: 50));
      }
      world.settle(const Duration(milliseconds: 500));
      expect(world.server.calls, hasLength(1));
      expect(
        [for (final call in world.server.readCalls.skip(reads)) '$call'],
        ['page $pageId'],
      );
      expect(world.cloud().queue.shown.pageRead(pageId), isA<ReadOwed>());
      expect(world.written().whereType<BaseArrived>().last.requestedAt, isNull);
      world.settle(const Duration(seconds: 10));
      expect(
        world.cloud().queue.shown.pageRead(pageId),
        const ReadThisSession(),
      );
    });
  });
}
