import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/stall_exits.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show servedAccount, strategyId;
import 'sender_world.dart';

const pageId = 'p1';

List<DateTime> listReads(World world) => [
      for (final call in world.server.readCalls)
        if (call.page == null) call.at!,
    ];

List<DateTime> pageReads(World world, String page) => [
      for (final call in world.server.readCalls)
        if (call.page == page) call.at!,
    ];

void forbidEveryRead(World world) {
  world.server.answerWith(
    strategyId,
    const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
  );
  world.server.overrideRead =
      (call) => const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden');
}

void main() {
  group('Sol 1: opening a strategy cannot go past the access check', () {
    test(
        'three reopen requests at one instant after the check stopped make '
        'at most one call', () {
      inWorld(
        (world) {
          forbidEveryRead(world);
          for (var n = 0; n < 8; n++) {
            world.sender.adopt(strategyId);
            world.settle(const Duration(minutes: 11));
          }
          final stopped = listReads(world).length;
          for (var n = 0; n < 3; n++) {
            world.sender.adopt(strategyId);
            world.async.flushMicrotasks();
          }
          world.settle(const Duration(seconds: 1));
          expect(listReads(world).length - stopped, lessThanOrEqualTo(1));
        },
        addStrategy: false,
      );
    });
  });

  group('Sol 2: an early end of a wait keeps the floor', () {
    test('four retries and four reconnects at one instant read the page once',
        () {
      inWorld((world) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
            StoreBatchAnswered(
              [
                RejectedAnswer(
                  call.opIds.single,
                  RejectionReason.rowReplaced,
                  const NoServerCopy(),
                ),
              ],
              complete: true,
            ),
          ),
        );
        world.server.overrideRead = (call) => call.page == pageId
            ? const StoreReadLost(TransportFailure.network, 'lost')
            : null;
        world.commitMove(1);
        world.settle(const Duration(minutes: 30));
        final before = pageReads(world, pageId).length;
        for (var n = 0; n < 4; n++) {
          world.sender.retryNow(strategyId);
          world.async.flushMicrotasks();
          world
            ..connection = null
            ..connection = 10 + n;
          world.async.flushMicrotasks();
        }
        world.settle(const Duration(seconds: 1));
        expect(pageReads(world, pageId).length - before, lessThanOrEqualTo(1));
      });
    });

    for (final (kind, answer) in <(String, OpAnswer Function(String))>[
      ('already made, without a revision', NoopWithoutRevision.new),
    ]) {
      test('answers that say an edit was $kind do not end a stalled wait', () {
        inWorld(
          (world) {
            world.pagesOnServer(['p2']);
            world.sender.adopt(strategyId);
            world.settle(const Duration(minutes: 1));
            world.server.overrideRead = (call) => call.page == 'p2'
                ? const StoreReadAnswered(PageGone('nowhere'))
                : null;
            world
              ..connection = null
              ..connection = 2;
            world.commitPageDelete('delete-p2', 'p2');
            world.settle(const Duration(seconds: 40));
            final stalled = pageReads(world, 'p2').length;
            final sends = world.server.calls.length;
            for (var n = 1; n <= 6; n++) {
              world.server.answerNext(
                strategyId,
                (call) => Future.value(
                  StoreBatchAnswered(
                    [for (final op in call.opIds) answer(op)],
                    complete: true,
                  ),
                ),
              );
              world.commitMove(n);
              world.settle(const Duration(seconds: 2));
            }
            expect(world.server.calls.length, sends + 6);
            expect(pageReads(world, 'p2'), hasLength(stalled));
          },
          addStrategy: false,
        );
      });
    }
  });

  group('Sol 4: what is shown while pages are unread', () {
    test('a strategy whose first page reads are lost is not shown as saved',
        () {
      inWorld(
        (world) {
          world.server.overrideRead = (call) => call.page == null
              ? null
              : const StoreReadLost(TransportFailure.network, 'lost');
          world.sender.adopt(strategyId);
          world.settle(const Duration(hours: 1));
          expect(world.face(), isNotNull);
        },
        addStrategy: false,
      );
    });

    test(
        'lost reads and then refused results reach the bound together and '
        'write the marker', () {
      inWorld((world) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
            StoreBatchAnswered(
              [
                RejectedAnswer(
                  call.opIds.single,
                  RejectionReason.rowReplaced,
                  const NoServerCopy(),
                ),
              ],
              complete: true,
            ),
          ),
        );
        var reads = 0;
        world.server.overrideRead = (call) {
          if (call.page != pageId) return null;
          reads++;
          if (reads <= 3) {
            return const StoreReadLost(TransportFailure.network, 'lost');
          }
          final held = world.server.rows[strategyId]!.page(pageId)! as LivePage;
          return StoreReadAnswered(
            PageRead(
              page: bornIn(held, lifeOfRow(held.key) + 1000) as PageRow,
              elements: const [],
              lineupGroups: const [],
            ),
          );
        };
        world.commitMove(1);
        world.settle(const Duration(seconds: 6));
        expect(pageReads(world, pageId), hasLength(greaterThan(2)));
        expect(world.face(), isNot(Face.unreadableWork));
        world.settle(const Duration(seconds: 1));
        expect(world.face(), Face.unreadableWork);
        world.settle(const Duration(minutes: 30));
        expect(world.face(), Face.unreadableWork);
      });
    });
  });

  group('Sol 5: trouble writing locally is not a server read', () {
    test(
        'a store that keeps refusing to keep a page result reads the page '
        'once, and retries the write with the result it has', () {
      inWorld((world) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
            StoreBatchAnswered(
              [
                RejectedAnswer(
                  call.opIds.single,
                  RejectionReason.rowReplaced,
                  const NoServerCopy(),
                ),
              ],
              complete: true,
            ),
          ),
        );
        world.slowStore.refusesBaseWrites = 1000;
        final before = pageReads(world, pageId).length;
        world.commitMove(1);
        world.settle(const Duration(hours: 2));
        expect(pageReads(world, pageId).length - before, 1);
      });
    });
  });

  group('a refusal on a read shows the same state as on a send', () {
    test('a page read refused for an upgrade shows upgradeRequired', () {
      inWorld(
        (world) {
          world.server.overrideRead = (call) => call.page == null
              ? null
              : const StoreReadRefused(
                  StoreReadRefusal.upgradeRequired,
                  'upgrade',
                );
          world.sender.adopt(strategyId);
          world.settle(const Duration(minutes: 10));
          expect(world.face(), Face.upgradeRequired);
          expect(world.sender.waitingOn(strategyId), StallExit.upgrade);
        },
        addStrategy: false,
      );
    });

    test(
        'a read refused for the sign-in holds every call until a sign-in, '
        'and the face stays what the waiting work showed', () {
      inWorld((world) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
            StoreBatchAnswered(
              [
                RejectedAnswer(
                  call.opIds.single,
                  RejectionReason.rowReplaced,
                  const NoServerCopy(),
                ),
              ],
              complete: true,
            ),
          ),
        );
        world.server.overrideRead = (call) => const StoreReadRefused(
              StoreReadRefusal.unauthenticated,
              'signed out',
            );
        world.commitMove(1);
        world.settle(const Duration(seconds: 5));
        final held = world.server.readCalls.length;
        world.settle(const Duration(minutes: 30));
        expect(world.server.readCalls, hasLength(held));
        expect(world.face(), Face.needsYou);
        expect(world.sender.waitingOn(strategyId), StallExit.signIn);
        world.server.overrideRead = null;
        world.signIn(servedAccount);
        world.settle(const Duration(seconds: 5));
        expect(world.server.readCalls.length, greaterThan(held));
      });
    });
  });

  test('the access check reports when it has stopped, and retry starts it', () {
    inWorld((world) {
      forbidEveryRead(world);
      world.commitMove(1);
      world.settle(const Duration(minutes: 30));
      expect(world.sender.accessCheckStopped(strategyId), isFalse);
      world.settle(const Duration(hours: 1));
      expect(world.sender.accessCheckStopped(strategyId), isTrue);
      world.sender.retryNow(strategyId);
      expect(world.sender.accessCheckStopped(strategyId), isFalse);
      world.sender.openInEditor(strategyId);
      world.settle(const Duration(hours: 2));
      expect(world.sender.accessCheckStopped(strategyId), isFalse);
    });
  });

  test(
      'the marker is a state: a need past the bound whose next read is lost '
      'writes it then, though the count passed the bound on answered reads',
      () {
    inWorld(
      (world) {
        world.pagesOnServer(['p2']);
        world.sender.adopt(strategyId);
        world.settle(const Duration(minutes: 1));
        world.server.overrideRead = (call) => call.page == 'p2'
            ? const StoreReadAnswered(PageGone('nowhere'))
            : null;
        world
          ..connection = null
          ..connection = 2;
        final adopted = pageReads(world, 'p2').length;
        world.commitPageDelete('delete-p2', 'p2');
        world.settle(const Duration(seconds: 7));
        expect(pageReads(world, 'p2'), hasLength(adopted + 3));
        expect(world.face(), isNot(Face.unreadableWork));
        world.server.overrideRead = (call) => call.page == 'p2'
            ? const StoreReadLost(TransportFailure.network, 'lost')
            : null;
        world.settle(const Duration(seconds: 10));
        expect(pageReads(world, 'p2'), hasLength(adopted + 4));
        expect(world.face(), Face.unreadableWork);
      },
      addStrategy: false,
    );
  });

  test(
      'closing the editor after it restarted a stopped access check leaves '
      'six more reads, then the check stops again', () {
    inWorld((world) {
      forbidEveryRead(world);
      world.commitMove(1);
      world.settle(const Duration(hours: 2));
      expect(world.sender.accessCheckStopped(strategyId), isTrue);
      final stopped = listReads(world).length;
      world.sender.openInEditor(strategyId);
      world.settle(const Duration(minutes: 1));
      expect(listReads(world), hasLength(stopped + 1));
      world.sender.openInEditor(null);
      world.settle(const Duration(hours: 2));
      expect(listReads(world), hasLength(stopped + timing.accessReads));
      expect(world.sender.accessCheckStopped(strategyId), isTrue);
    });
  });
}
