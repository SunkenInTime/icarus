import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show pageId, strategyId;
import 'sender_world.dart';

ResultPoint onConnection(World world, int connection) => ResultPoint(
      client: 1,
      connection: connection,
      snapshot: world.server.stamp().snapshot,
      serverTime: world.server.serverNow,
    );

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

DateTime sendRetryAt(World world) => [
      for (final view in world.views())
        for (final hold in view.holds)
          if (hold case UntilRetryTime(:final at)) at,
    ].single;

DateTime now(World world) => start.add(world.async.elapsed);

void sendLostThenRead(
  World world,
  ReadOf read,
  String call,
  StoreReadOutcome answer,
) {
  world.settle();
  world.server.answerWith(
    strategyId,
    const StoreBatchLost(TransportFailure.network, 'lost'),
  );
  world.commitMove(1);
  world.settle(const Duration(milliseconds: 500));
  expect(world.server.calls, hasLength(1));
  final reads = world.server.readCalls.length;
  world.server.answerReadWith(strategyId, answer);
  world.sender.owesFreshRead(strategyId, read);
  world.settle(const Duration(milliseconds: 100));
  expect(
    [for (final call in world.server.readCalls.skip(reads)) '$call'],
    [call],
  );
  expect(world.server.calls, hasLength(1));
}

DateTime readDueAt(World world) => switch (world.sender.outlook(
      strategyId,
      world.cloud(),
    )) {
      ReadAt(:final at) => at,
      final other => throw StateError('no read is due later: $other'),
    };

({DateTime at, String what}) firstCallAfter(World world, DateTime due) {
  expect(world.sender.busy, isFalse, reason: 'the sender is not idle');
  expect(world.sender.armedFor, due, reason: 'the sender sleeps until');
  final sends = world.server.calls.length;
  final reads = world.server.readCalls.length;
  final wakes = world.sender.wakes;
  final dues = world.sender.dues;
  while (true) {
    world.async.elapse(const Duration(milliseconds: 10));
    if (world.sender.dues != dues) break;
    expect(world.server.calls, hasLength(sends));
    expect(world.server.readCalls, hasLength(reads));
    expect(world.sender.wakes, wakes, reason: 'woken before its deadline');
  }
  while (world.server.calls.length == sends &&
      world.server.readCalls.length == reads) {
    world.async.elapse(const Duration(milliseconds: 10));
    if (now(world).difference(due) > const Duration(minutes: 5)) {
      throw StateError('no call within five minutes of $due');
    }
  }
  return world.server.calls.length > sends
      ? (at: world.server.calls.last.at!, what: 'send')
      : (at: world.server.readCalls.last.at!, what: 'read');
}

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
      'refusal, nor does any later read on that connection, since the native '
      'read may still be running; a read on the next connection does', () {
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
      final asked = world.written().whereType<BaseArrived>().length;
      world.sender.owesFreshRead(strategyId, const ReadOfPage(pageId));
      world.settle(const Duration(seconds: 10));
      final later = world.written().whereType<BaseArrived>().skip(asked);
      expect(later, isNotEmpty);
      expect(
          [for (final read in later) read.requestedAt], everyElement(isNull));
      expect(isDebt(world.cloud().queue.shown.pageRead(pageId)), isTrue);
      world
        ..connection = null
        ..connection = 2;
      world.server.connection = 2;
      world.sender.owesFreshRead(strategyId, const ReadOfPage(pageId));
      world.settle(const Duration(seconds: 10));
      expect(
        world.cloud().queue.shown.pageRead(pageId),
        const ReadThisSession(),
      );
    });
  });

  test(
      'an upgrade refusal stamped on a connection that has ended holds '
      'nothing, and the edit is sent again', () {
    inWorld((world) {
      world.connection = 2;
      world.settle();
      world.server.answerNext(
        strategyId,
        (call) async => StoreBatchRefusedWhole(
          BatchRefusal.upgradeRequired,
          point: onConnection(world, 1),
        ),
      );
      world.commitMove(1);
      world.settle(const Duration(minutes: 2));
      expect(world.sender.upgradeAsked, isFalse);
      expect(world.server.calls, hasLength(2));
      expect(world.queueLength(), 0);
    });
  });

  test(
      'a sign-in refusal of a batch stamped on a connection that has ended '
      'waits for no sign-in, and the edit is sent again', () {
    inWorld((world) {
      world.connection = 2;
      world.settle();
      world.server.answerNext(
        strategyId,
        (call) async => StoreBatchRefusedWhole(
          BatchRefusal.unauthenticated,
          point: onConnection(world, 1),
        ),
      );
      world.commitMove(1);
      world.settle(const Duration(minutes: 2));
      expect(world.sender.signInWaitFrom, isNull);
      expect(world.server.calls, hasLength(2));
      expect(world.queueLength(), 0);
    });
  });

  test(
      'an account refusal of a batch stamped on a connection that has ended '
      'waits for no sign-in, and the edit is sent again', () {
    inWorld((world) {
      world.connection = 2;
      world.settle();
      world.server.answerNext(
        strategyId,
        (call) async => StoreBatchAccountMismatch(
          'another account',
          point: onConnection(world, 1),
        ),
      );
      world.commitMove(1);
      world.settle(const Duration(minutes: 2));
      expect(world.sender.signInWaitFrom, isNull);
      expect(world.server.calls, hasLength(2));
      expect(world.server.calls[1].opIds, world.server.calls[0].opIds);
      expect(world.queueLength(), 0);
    });
  });

  test(
      'an account refusal of a batch on the current connection gives the '
      'claim back and waits for the sign-in to change', () {
    inWorld((world) {
      world.settle();
      world.server.answerWith(
        strategyId,
        const StoreBatchAccountMismatch(
          'another account',
          point: stampedWhenAnswered,
        ),
      );
      world.commitMove(1);
      world.settle(const Duration(minutes: 2));
      expect(world.sender.runHold, isA<SignInHold>());
      expect(world.server.calls, hasLength(1));
      expect(world.queueLength(), 1);
    });
  });

  test(
      'a success that is the first stamp from a later connection opens its '
      'session and still sets the server time live writes are judged by', () {
    inWorld((world) {
      world.settle();
      final before = world.cloud().queue.session.number;
      late final int time;
      world.server.answerNext(strategyId, (call) async {
        world.server.connection = 2;
        final applied = world.server.applyAll(call) as StoreBatchAnswered;
        time = world.server.serverNow;
        return StoreBatchAnswered(
          applied.answers,
          complete: applied.complete,
          point: onConnection(world, 2),
          serverTime: time,
        );
      });
      world.commitMove(1);
      world.settle(const Duration(milliseconds: 500));
      expect(world.connection, 1);
      final queue = world.cloud().queue;
      expect(queue.session.number, greaterThan(before));
      expect(queue.session.generation?.connection, 2);
      expect(queue.session.basis?.serverTime, time);
    });
  });

  test(
      'a success stamped on a connection that has ended does not set the '
      'server time live writes are judged by', () {
    inWorld((world) {
      world.connection = 2;
      world.settle();
      final held = world.cloud().queue.session.basis;
      world.server.answerNext(strategyId, (call) async {
        final applied = world.server.applyAll(call) as StoreBatchAnswered;
        return StoreBatchAnswered(
          applied.answers,
          complete: applied.complete,
          point: onConnection(world, 1),
          serverTime: world.server.serverNow,
        );
      });
      world.commitMove(1);
      world.settle(const Duration(milliseconds: 500));
      expect(world.server.calls, hasLength(1));
      final discarded = world.written().whereType<ServerTimeHeld>().single;
      expect(discarded.point.connection, 1);
      expect(world.cloud().queue.session.basis, held);
    });
  });

  test(
      'an idle strategy whose send retry comes before its deferred read makes '
      'its first call, a send, at the send\'s deadline', () {
    inWorld((world) {
      world.settle();
      for (var lost = 0; lost < 2; lost++) {
        world.server.answerReadWith(
          strategyId,
          const StoreReadLost(TransportFailure.network, 'lost'),
        );
      }
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 3));
      world.server.answerWith(
        strategyId,
        const StoreBatchLost(TransportFailure.network, 'lost'),
      );
      world.commitMove(1);
      world.settle(const Duration(milliseconds: 500));
      final send = sendRetryAt(world);
      final read = readDueAt(world);
      expect(send.isBefore(read), isTrue, reason: 'send $send, read $read');
      expect(firstCallAfter(world, send), (at: send, what: 'send'));
    });
  });

  test(
      'an idle strategy whose deferred read comes before its send retry makes '
      'its first call, a read, at the read\'s deadline', () {
    inWorld((world) {
      world.settle();
      for (var lost = 0; lost < 4; lost++) {
        world.server.answerWith(
          strategyId,
          const StoreBatchLost(TransportFailure.network, 'lost'),
        );
      }
      world.commitMove(1);
      while (world.server.calls.length < 4) {
        world.settle(const Duration(seconds: 1));
      }
      world.settle(const Duration(milliseconds: 500));
      world.server.answerReadWith(
        strategyId,
        const StoreReadLost(TransportFailure.network, 'lost'),
      );
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(milliseconds: 500));
      final send = sendRetryAt(world);
      final read = readDueAt(world);
      expect(read.isBefore(send), isTrue, reason: 'read $read, send $send');
      expect(firstCallAfter(world, read), (at: read, what: 'read'));
    });
  });

  test(
      'a lost send that backs off is sent again at its retry time, not at the '
      'retry time of a list read lost after it', () {
    inWorld((world) {
      sendLostThenRead(
        world,
        const ReadOfList(),
        'list',
        const StoreReadLost(TransportFailure.network, 'lost'),
      );
      final resend = sendRetryAt(world);
      final readAgain = now(world).add(timing.readRetryAfter(1));
      expect(resend.isBefore(readAgain), isTrue);
      world.settle(const Duration(seconds: 10));
      expect(world.server.calls, hasLength(2));
      expect(world.server.calls[1].at, resend);
      expect(world.queueLength(), 0);
    });
  });

  test(
      'a lost send that backs off is sent again at its retry time, not ten '
      'minutes later when a page read refused as FORBIDDEN is tried again', () {
    inWorld((world) {
      sendLostThenRead(
        world,
        const ReadOfPage(pageId),
        'page $pageId',
        const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden',
            point: stampedWhenAnswered),
      );
      expect(world.sender.cannotRead(strategyId), isNotNull);
      final resend = sendRetryAt(world);
      world.settle(const Duration(seconds: 10));
      expect(world.server.calls, hasLength(2));
      expect(world.server.calls[1].at, resend);
      expect(world.queueLength(), 0);
    });
  });

  test(
      'a read planned while the store starts closing is never issued, and '
      'the sender ends', () {
    inWorld(
      (world) {
        world.settle();
        final before = world.server.readCalls.length;
        world.slowStore.afterRead = const Duration(seconds: 1);
        world.sender.owesFreshRead(strategyId, const ReadOfList());
        world.async.elapse(const Duration(milliseconds: 500));
        expect(world.sender.busy, isTrue);
        unawaited(world.store.close());
        world.settle(const Duration(seconds: 10));
        expect(world.server.readCalls.skip(before), isEmpty);
        expect(world.sender.ended, isNotNull);
      },
      keepOpen: true,
    );
  });

  test(
      'a sign-in refusal of a read stamped on a connection that has ended is '
      'a lost read, not a wait for the next sign-in', () {
    inWorld(
      (world) {
        world.connection = 2;
        world.server.answerReadNext(
          strategyId,
          (call) async => StoreReadRefused(
            StoreReadRefusal.unauthenticated,
            'signed out',
            point: onConnection(world, 1),
          ),
        );
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 30));
        expect(world.sender.signInWaitFrom, isNull);
        expect(world.cloud().queue.shown.list, const ReadThisSession());
      },
      addStrategy: false,
    );
  });
}
