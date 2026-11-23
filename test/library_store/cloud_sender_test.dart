import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart' show useCloudAs;
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/library_store/store_sessions.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show
        openStore,
        pageId,
        pageList,
        pageSnapshot,
        secondPage,
        serverRows,
        servedAccount,
        shadowOn,
        strategyId;
import 'sender_world.dart';

final _signIns = StateProvider<int>((ref) => 0);

void holdNextWrite(MemoryStorage storage, void Function() atIt) {
  final hold = storage.holdNextWrite();
  unawaited(
    hold.reached.then((_) {
      atIt();
      hold.letGo();
    }),
  );
}

void main() {
  group('the loop over the real queue', () {
    test('sends a commit once, after the wait, as the strategy\'s owner', () {
      inWorld((world) {
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 100));
        expect(world.server.calls, isEmpty);
        world.settle();
        expect(world.server.calls.single.account, servedAccount);
        expect(world.server.calls.single.opIds, ['move-1']);
        expect(world.queueLength(), 0);
      });
    });

    test('two rows changed within the wait go in one call', () {
      inWorld((world) {
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 50));
        world.commitRename(strategyId, 'rename');
        world.settle();
        expect(world.server.calls.single.opIds, ['move-1', 'rename']);
      });
    });

    test('50 moves made one after another make 50 calls, and 20 make 20', () {
      for (final moves in [50, 20]) {
        inWorld((world) {
          for (var n = 1; n <= moves; n++) {
            world.commitMove(n);
            world.settle();
            world.showResult();
          }
          expect(world.server.calls, hasLength(moves));
          expect(world.server.applied, moves);
          expect(world.queueLength(), 0);
        });
      }
    });

    test('a start with saved work sends it with no wake from outside', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld((world) {
        world.sender.hold('x');
        world.commitMove(1);
        world.settle();
      }, storage: storage, server: server);
      inWorld(
        (world) {
          world.settle(const Duration(seconds: 5));
          expect(server.calls, hasLength(1));
          expect(world.queueLength(), 0);
        },
        storage: storage,
        server: server,
        shadow: false,
        addStrategy: false,
      );
    });

    test('another account\'s work is not sent, and is sent when it is back',
        () {
      inWorld((world) {
        world.commitMove(1);
        world.signIn(otherAccount);
        world.settle();
        expect(world.server.calls, isEmpty);
        world.signIn(servedAccount);
        world.settle();
        expect(world.server.calls.single.account, servedAccount);
        expect(world.server.wrongAccount, isEmpty);
      });
    });

    test(
        'held while the claim is written, the claim is given back with no '
        'call, and released it is sent once', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.commitMove(1);
        holdNextWrite(storage, () => world.sender.hold('held by the test'));
        world.settle();
        expect(world.server.calls, isEmpty);
        expect(world.written(), contains(isA<ClaimReleased>()));
        world.sender.release();
        world.settle(const Duration(seconds: 10));
        expect(world.server.calls, hasLength(1));
        expect(world.queueLength(), 0);
      }, storage: storage);
    });

    test('held during the call, the answer is still written', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) {
          world.sender.hold('held by the test');
          return Future.value(world.server.applyAll(call));
        });
        world.commitMove(1);
        world.settle();
        expect(world.queueLength(), 0);
        world.commitMove(2);
        world.settle();
        expect(world.server.calls, hasLength(1));
      });
    });

    test(
        'disposed during the claim, the call or the answer\'s write, the next '
        'run sends the op once under its original client', () {
      for (final at in ['claim', 'call', 'write']) {
        final storage = MemoryStorage();
        final server = FakeServer();
        inWorld(
          (world) {
            world.commitMove(1);
            switch (at) {
              case 'claim':
                holdNextWrite(storage, world.sender.dispose);
              case 'call':
                server.answerNext(strategyId, (call) {
                  server.applyAll(call);
                  world.sender.dispose();
                  return Completer<StoreBatchOutcome>().future;
                });
              case _:
                server.answerNext(strategyId, (call) {
                  holdNextWrite(storage, world.sender.dispose);
                  return Future.value(server.applyAll(call));
                });
            }
            world.settle(const Duration(minutes: 1));
            expect(world.async.pendingTimers, isEmpty);
          },
          storage: storage,
          server: server,
        );
        inWorld(
          (world) {
            world.settle(const Duration(minutes: 5));
            expect(world.queueLength(), 0, reason: at);
            expect(server.appliedOf(strategyId), 1, reason: at);
            expect(server.anyAppliedTwice, isFalse, reason: at);
            final clients = {for (final call in server.calls) call.clientId};
            expect(clients, hasLength(1), reason: at);
          },
          storage: storage,
          server: server,
          shadow: false,
          addStrategy: false,
          clientId: 'client-2',
        );
      }
    });

    test(
        'a transport that never answers is given up, and the resend carries '
        'the same op and client and lands once', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) {
          world.server.applyAll(call);
          return Completer<StoreBatchOutcome>().future;
        });
        world.commitMove(1);
        world.async.elapse(const Duration(seconds: 44));
        expect(world.server.calls, hasLength(1));
        world.settle(const Duration(minutes: 5));
        final [first, second] = world.server.calls;
        expect(second.opIds, first.opIds);
        expect(second.clientId, first.clientId);
        expect(world.server.anyAppliedTwice, isFalse);
        expect(world.queueLength(), 0);
      });
    });

    test(
        'UNAUTHENTICATED and ACCOUNT_MISMATCH make no further call until the '
        'sign-in changes, through a hold and release', () {
      for (final refusal in <StoreBatchOutcome>[
        const StoreBatchRefusedWhole(BatchRefusal.unauthenticated),
        const StoreBatchAccountMismatch('another account'),
      ]) {
        inWorld((world) {
          world.server.answerWith(strategyId, refusal);
          world.commitMove(1);
          world.settle(const Duration(minutes: 10));
          world.sender
            ..hold('x')
            ..release();
          world.settle(const Duration(minutes: 10));
          expect(world.server.calls, hasLength(1));
          world.authChanges = 2;
          world.settle(const Duration(minutes: 5));
          expect(world.server.calls, hasLength(2));
          expect(world.queueLength(), 0);
        });
      }
    });

    test(
        'a refusal is held to the sign-in its call was made under: a refusal '
        'after the sign-in moved does not hold the newer one', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (_) {
          world.authChanges = 2;
          return Future.value(
            const StoreBatchRefusedWhole(BatchRefusal.unauthenticated),
          );
        });
        world.commitMove(1);
        world.settle(const Duration(minutes: 5));
        expect(world.server.calls, hasLength(2));
        expect(world.queueLength(), 0);
      });
    });

    test('an upgrade refusal holds every strategy, through a hold and release',
        () {
      inWorld((world) {
        world.addOtherStrategy();
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.upgradeRequired),
        );
        world.commitMove(1);
        world.settle();
        world.sender
          ..hold('x')
          ..release();
        world.commitRename(otherStrategy, 'other');
        world.settle(const Duration(minutes: 10));
        expect(world.server.calls, hasLength(1));
        expect(world.sender.view.run, contains('newer build'));
      });
    });

    test(
        'FORBIDDEN and NOT_FOUND are that strategy\'s verdicts, and another '
        'strategy still sends', () {
      for (final (refusal, face) in [
        (BatchRefusal.editAccessRemoved, Face.editAccessLost),
        (BatchRefusal.strategyDeleted, Face.deletedOnServer),
      ]) {
        inWorld((world) {
          world.addOtherStrategy();
          world.server.answerWith(strategyId, StoreBatchRefusedWhole(refusal));
          world.commitMove(1);
          world.settle(const Duration(minutes: 1));
          expect(world.face(), face);
          world.commitRename(otherStrategy, 'other');
          world.settle(const Duration(minutes: 1));
          expect(
            world.server.calls.map((call) => call.strategyId),
            [strategyId, otherStrategy],
          );
        });
      }
    });

    test(
        'a disconnect with no editor open is recorded, best effort, and work '
        'made offline is sent once it returns, whether or not that record '
        'was written', () {
      for (final refuseTheRecord in [false, true]) {
        inWorld((world) {
          world.commitMove(1);
          world.settle();
          world.showResult();
          world.dropsConnectionLost.value = refuseTheRecord;
          world.connection = null;
          world.settle();
          expect(
            world.written().whereType<ConnectionLost>(),
            hasLength(refuseTheRecord ? 0 : 1),
          );
          world.commitRename(strategyId, 'offline');
          world.settle();
          expect(world.server.calls, hasLength(1));
          world.connection = 2;
          world.settle();
          expect(world.server.calls.last.opIds, ['offline']);
          expect(world.queueLength(), 0);
        });
      }
    });

    test(
        'one strategy whose writes are refused does not delay another, and '
        'says it could not be written', () {
      inWorld((world) {
        world.addOtherStrategy();
        world.commitMove(1);
        world.lease.refusedAreas.add(strategyId);
        world.settle();
        world.commitRename(otherStrategy, 'other');
        world.settle();
        expect(world.server.calls.last.strategyId, otherStrategy);
        expect(world.status(), contains('could not be written'));
      });
    });

    test('a store that starts closing during the claim makes no call', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.commitMove(1);
        holdNextWrite(storage, () => unawaited(world.store.close()));
        world.settle(const Duration(minutes: 1));
        expect(world.server.calls, isEmpty);
        expect(world.sender.ended, isNotNull);
      }, storage: storage);
    });

    test('a store closed during a call ends the sender with the reason', () {
      inWorld((world) {
        final answer = Completer<StoreBatchOutcome>();
        world.server.answerNext(strategyId, (_) => answer.future);
        world.commitMove(1);
        world.settle();
        unawaited(world.store.close());
        world.async.flushMicrotasks();
        answer.complete(world.server.applyAll(world.server.calls.single));
        world.settle(const Duration(minutes: 5));
        expect(world.sender.ended, isNotNull);
        expect(world.sender.view.run, startsWith('ended'));
        expect(world.lease.commits, lessThan(20));
      });
    });

    test(
        'a result that arrived under a connection since replaced is stale, '
        'and recorded into no session', () {
      inWorld((world) {
        final old = world.stamp;
        world.connection = 2;
        world.settle();
        world.shadow!.page(
          strategyId,
          pageSnapshot(serverRows()),
          old.connection,
          stamp: old,
        );
        world.settle();
        expect(
          world.shadow!.ledger.last.verdict,
          isA<Skipped>().having(
            (skip) => skip.reason,
            'reason',
            SkipReason.staleForSender,
          ),
        );
        expect(
          world.sender.store.reports.whereType<ResultWritten>().where(
                (written) => written.stamp == old,
              ),
          hasLength(2),
        );
      });
    });

    test(
        'a claim made while the connection, the sign-in or the account '
        'changed is given back and sent from the new session', () {
      for (final (change, restore)
          in <(void Function(World), void Function(World))>[
        ((world) => world.connection = 2, (_) {}),
        ((world) => world.authChanges = 2, (_) {}),
        (
          (world) => world.account = otherAccount,
          (world) => world.account = servedAccount,
        ),
      ]) {
        final storage = MemoryStorage();
        inWorld((world) {
          world.commitMove(1);
          holdNextWrite(storage, () => change(world));
          world.settle();
          expect(world.written(), contains(isA<ClaimReleased>()));
          restore(world);
          world.settle(const Duration(seconds: 10));
          expect(world.server.calls, hasLength(1));
          expect(world.server.wrongAccount, isEmpty);
          expect(world.queueLength(), 0);
        }, storage: storage);
      }
    });

    test(
        'a restart opens the session before anything else, so the last run\'s '
        'attempt is closed by the restart and resent once', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld((world) {
        server.answerNext(strategyId, (call) {
          server.applyAll(call);
          world.sender.dispose();
          return Completer<StoreBatchOutcome>().future;
        });
        world.commitMove(1);
        world.settle();
      }, storage: storage, server: server);
      inWorld(
        (world) {
          world.settle(const Duration(minutes: 5));
          final events = world.written();
          expect(events.first, isA<AppRestarted>());
          expect(events.whereType<TransportFailed>(), isEmpty);
          expect(server.anyAppliedTwice, isFalse);
          expect(world.queueLength(), 0);
        },
        storage: storage,
        server: server,
        shadow: false,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'an answer whose write the disk refused is dropped, and the open '
        'attempt is closed and resent in this run, landing once', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) {
          world.lease.refuseNext = 1;
          return Future.value(world.server.applyAll(call));
        });
        world.commitMove(1);
        world.settle(const Duration(minutes: 5));
        expect(world.written(), contains(isA<TransportFailed>()));
        expect(world.server.calls, hasLength(2));
        expect(world.server.anyAppliedTwice, isFalse);
        expect(world.queueLength(), 0);
      });
    });

    test(
        'a token refresh for the same account opens no session and writes no '
        'account change', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        world.authChanges = 2;
        world.commitRename(strategyId, 'after-refresh');
        world.settle();
        final events = world.written();
        expect(events.whereType<AccountChanged>(), isEmpty);
        expect(events.whereType<ConnectionReturned>(), isEmpty);
        expect(world.server.calls, hasLength(2));
        world
          ..authChanges = 3
          ..connection = 2;
        world.commitAdds(1);
        world.settle();
        expect(world.written().whereType<AccountChanged>(), isEmpty);
        expect(world.written().whereType<ConnectionReturned>(), hasLength(1));
        expect(world.server.calls, hasLength(3));
      });
    });

    test(
        'a strategy with a long backlog does not keep another waiting: they '
        'take turns', () {
      inWorld((world) {
        world.addOtherStrategy();
        world.commitAdds(90);
        world.commitRename(otherStrategy, 'other');
        world.settle(const Duration(seconds: 10));
        final order = [for (final call in world.server.calls) call.strategyId];
        expect(order, hasLength(4));
        expect(order.indexOf(otherStrategy), lessThanOrEqualTo(1));
      });
    });

    test('with nothing to do, the loop does not look again by itself', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        final looks = world.sender.looks;
        world.settle(const Duration(minutes: 10));
        expect(world.sender.looks - looks, lessThanOrEqualTo(1));
      });
    });

    test(
        'the shadow and the loop opening one strategy at once write the '
        'restart once and one session', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      var before = 0;
      inWorld((world) {
        world.sender.hold('x');
        world.commitMove(1);
        world.settle();
        before = world.cloud().queue.nextSession;
      }, storage: storage, server: server);
      inWorld(
        (world) {
          world.addServedStrategy();
          world.settle();
          expect(world.cloud().queue.nextSession, before + 2);
          expect(world.written().whereType<AppRestarted>(), hasLength(1));
          final opened = world.shadowReports
              .whereType<ShadowSessionOpened>()
              .map((report) => report.because);
          expect(opened, isNotEmpty);
          expect(opened, everyElement('the sender opened it'));
          expect(server.calls, hasLength(1));
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test('a session write the disk refused is tried again with its restart',
        () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.sender.hold('x');
        world.commitMove(1);
        world.settle();
      }, storage: storage);
      inWorld(
        (world) {
          world.lease.refuseNext = 1;
          world.settle(const Duration(seconds: 10));
          expect(world.written().whereType<AppRestarted>(), hasLength(1));
          expect(world.server.calls, hasLength(1));
        },
        storage: storage,
        shadow: false,
        addStrategy: false,
      );
    });
  });

  group('the round-four cases', () {
    test(
        'ten edits 50 ms apart make one call, as today\'s outbox does, because '
        'each new edit restarts the wait', () {
      inWorld((world) {
        for (var n = 0; n < 10; n++) {
          world.commitAdds(1, from: n);
          world.async.elapse(const Duration(milliseconds: 50));
        }
        world.settle();
        expect(world.server.calls, hasLength(1));
        expect(world.server.calls.single.ops, hasLength(10));
      });
    });

    test('edits that never pause are still sent at least once a second', () {
      inWorld((world) {
        for (var n = 0; n < 60; n++) {
          world.commitAdds(1, from: n);
          world.async.elapse(const Duration(milliseconds: 50));
        }
        final during = world.server.calls.length;
        world.settle();
        expect(during, inInclusiveRange(2, 4));
        expect(world.queueLength(), 0);
      });
    });

    test('a result arriving does not hold a send back', () {
      inWorld((world) {
        world.commitAdds(1);
        for (var n = 0; n < 6; n++) {
          world.async.elapse(const Duration(milliseconds: 60));
          world.shadow!.page(
            strategyId,
            pageSnapshot(serverRows()),
            world.connection,
            stamp: world.stamp,
          );
        }
        world.async.flushMicrotasks();
        expect(world.server.calls, hasLength(1));
      });
    });

    test(
        'a retry time that passes while the queue is read is looked at again '
        'at once', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchLost(TransportFailure.network, 'lost'),
        );
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 300));
        world.async.flushMicrotasks();
        expect(world.server.calls, hasLength(1));
        final retryAt = [
          for (final view in world.views())
            for (final hold in view.holds)
              if (hold case UntilRetryTime(:final at)) at,
        ].single;
        final left = retryAt.difference(start.add(world.async.elapsed));
        expect(left, greaterThan(Duration.zero));
        world.async.elapse(left ~/ 3);
        world.slowStore.afterRead = left;
        world.sender.wake();
        world.async.elapse(left * 2);
        world.slowStore.afterRead = Duration.zero;
        world.async.elapse(const Duration(seconds: 7));
        world.async.flushMicrotasks();
        expect(world.server.calls, hasLength(2));
        expect(world.queueLength(), 0);
      });
    });

    test('closing a quiet store ends the loop', () {
      inWorld((world) {
        world.settle();
        unawaited(world.store.close());
        world.settle();
        expect(world.sender.ended, isNotNull);
      });
    });

    test(
        'a refused answer write waits its delay: nothing is written for that '
        'strategy in the next second and a half', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) {
          world.lease.refusedAreas.add(strategyId);
          return Future.value(world.server.applyAll(call));
        });
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 300));
        world.async.flushMicrotasks();
        expect(world.lease.refusedFor[strategyId], 1);
        world.async.elapse(const Duration(milliseconds: 1500));
        expect(world.lease.refusedFor[strategyId], 1);
        world.lease.refusedAreas.clear();
        world.settle(const Duration(minutes: 1));
        expect(world.queueLength(), 0);
        expect(world.server.anyAppliedTwice, isFalse);
      });
    });

    test(
        'an attempt no call answers is not closed when sending is held while '
        'its queue is read', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) {
          world.lease.refuseNext = 1;
          return Future.value(world.server.applyAll(call));
        });
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 300));
        world.async.flushMicrotasks();
        expect(world.server.calls, hasLength(1));
        final retry = world.sender.notBefore[strategyId]!;
        world.slowStore.afterRead = const Duration(seconds: 1);
        world.async.elapse(
          retry.difference(start.add(world.async.elapsed)) +
              const Duration(milliseconds: 300),
        );
        expect(world.sender.busy, isTrue);
        world.sender.hold('held while the queue is read');
        world.settle(const Duration(minutes: 1));
        expect(world.written().whereType<TransportFailed>(), isEmpty);
        world.slowStore.afterRead = Duration.zero;
        world.sender.release();
        world.settle(const Duration(minutes: 1));
        expect(world.written().whereType<TransportFailed>(), hasLength(1));
        expect(world.queueLength(), 0);
      });
    });

    test(
        'a session written but not read back is not written again with its '
        'restart', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.sender.hold('x');
        world.commitMove(1);
        world.settle();
      }, storage: storage);
      inWorld(
        (world) {
          world.slowStore.dropSessionReadBack = 1;
          world.settle(const Duration(minutes: 1));
          expect(world.written().whereType<AppRestarted>(), hasLength(1));
          expect(world.queueLength(), 0);
        },
        storage: storage,
        shadow: false,
        addStrategy: false,
      );
    });

    test('the run-wide holds are facts a sync state can be combined with', () {
      for (final (refusal, hold) in [
        (
          const StoreBatchRefusedWhole(BatchRefusal.upgradeRequired),
          isA<UpgradeHold>(),
        ),
        (
          const StoreBatchRefusedWhole(BatchRefusal.unauthenticated),
          isA<SignInHold>(),
        ),
      ]) {
        inWorld((world) {
          expect(world.sender.runHold, isNull);
          world.server.answerWith(strategyId, refusal);
          world.commitMove(1);
          world.settle();
          expect(world.sender.runHold, hold);
        });
      }
    });

    test(
        'a first page list that arrived under a replaced connection adds '
        'nothing, and one whose add outlived its connection binds nothing', () {
      final storage = MemoryStorage();
      inWorld(
        (world) {
          final old = world.stamp;
          world.connection = 2;
          world.settle();
          world.shadow!.pageList(
            strategyId,
            pageList(serverRows()),
            old.connection,
            stamp: old,
          );
          world.settle();
          expect(world.store.library, isA<LibraryOpen>());
          expect(
            (world.store.library as LibraryOpen).list.strategies,
            isEmpty,
          );
          holdNextWrite(storage, () => world.connection = 3);
          world.shadow!.pageList(
            strategyId,
            pageList(serverRows()),
            2,
            stamp: (account: servedAccount, connection: 2, signIns: 1),
          );
          world.settle();
          expect(
            (world.store.library as LibraryOpen).list.strategies,
            hasLength(1),
          );
          expect(world.sender.bound, isEmpty);
          expect(
              world.sender.store.reports.whereType<ResultWritten>(), isEmpty);
        },
        storage: storage,
        addStrategy: false,
      );
    });

    test(
        'a result whose session write is held while the connection is '
        'replaced is stale, and records nothing', () {
      final storage = MemoryStorage();
      inWorld((world) {
        final before =
            world.sender.store.reports.whereType<ResultWritten>().length;
        world.connection = 2;
        world.settle();
        holdNextWrite(storage, () => world.connection = 3);
        world.shadow!.page(
          strategyId,
          pageSnapshot(serverRows()),
          2,
          stamp: (account: servedAccount, connection: 2, signIns: 1),
        );
        world.settle();
        expect(
          world.sender.store.reports.whereType<ResultWritten>(),
          hasLength(before),
        );
        expect(world.sender.bound[strategyId]?.connection, isNot(2));
      }, storage: storage);
    });

    test(
        'after a change of sign-in count, results stop for the run while '
        'sends go on', () {
      inWorld((world) {
        world.authChanges = 2;
        world.settle();
        final before =
            world.sender.store.reports.whereType<ResultWritten>().length;
        world.showResult();
        expect(
          world.sender.store.reports.whereType<ResultWritten>(),
          hasLength(before),
        );
        world.commitMove(1);
        world.settle();
        expect(world.server.calls, hasLength(1));
      });
    });
  });

  group('the round-five cases', () {
    test(
        'the sign-in rule holds from the start of the run: a first page list '
        'under a later sign-in count adds nothing', () {
      inWorld(
        (world) {
          world.authChanges = 2;
          world.settle();
          world.shadow!.pageList(
            strategyId,
            pageList(serverRows()),
            world.connection,
            stamp: world.stamp,
          );
          world.settle();
          expect(
            (world.store.library as LibraryOpen).list.strategies,
            isEmpty,
          );
          expect(world.intake.outcomes.values.single, isA<ResultStale>());
        },
        addStrategy: false,
      );
    });

    test(
        'results that arrived before a call\'s answer are recorded before it, '
        'so they are not taken as the fresh read a page delete waits for', () {
      inWorld((world) {
        void handOlder() => world.shadow!
          ..pageList(
            strategyId,
            pageList(serverRows(), more: [secondPage()]),
            world.connection,
            stamp: world.stamp,
          )
          ..page(
            strategyId,
            pageSnapshot(serverRows()),
            world.connection,
            stamp: world.stamp,
          );
        handOlder();
        world.settle();
        final reply = Completer<void>();
        world.server.answerNext(strategyId, (call) {
          final answered = world.server.applyAll(call);
          return reply.future.then((_) => answered);
        });
        world.commitMove(1);
        world.settle(const Duration(milliseconds: 300));
        expect(world.server.calls, hasLength(1));
        world.commitPageDelete('delete-page', pageId);
        final before = world.sender.store.reports.length;
        handOlder();
        world.async.flushMicrotasks();
        reply.complete();
        world.settle();
        expect(
          [
            for (final report in world.sender.store.reports.skip(before))
              if (report is ResultWritten)
                'result'
              else if (report case EventsWritten(:final events)
                  when events.any((event) => event is OpAnswered))
                'answer',
          ],
          ['result', 'result', 'answer'],
        );
        expect(
          [
            for (final call in world.server.calls)
              for (final op in call.ops)
                if (op is PageDeleteOp) op.opId,
          ],
          isEmpty,
        );
      });
    });

    test(
        'a result waiting when the loop ends is answered as not recorded, '
        'and the shadow drains', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.commitMove(1);
        final hold = storage.holdNextWrite();
        unawaited(
          hold.reached.then((_) {
            world.shadow!.page(
              strategyId,
              pageSnapshot(serverRows()),
              world.connection,
              stamp: world.stamp,
            );
            unawaited(world.store.close());
            hold.letGo();
          }),
        );
        world.settle(const Duration(minutes: 1));
        expect(world.sender.ended, isNotNull);
        final waited = world.arrivals.whereType<ResultForStore>().last;
        expect(world.intake.outcomes[waited], isA<ResultNotRecorded>());
        var drained = false;
        unawaited(world.shadow!.idle.then((_) => drained = true));
        world.settle();
        expect(drained, isTrue);
      }, storage: storage);
    });

    test(
        'use cloud acts as the signed-in account: another account cannot take '
        'the cloud\'s version of the owner\'s rejected edit', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          StoreBatchAnswered(
            [
              const RejectedAnswer(
                'move-1',
                RejectionReason.revisionMismatch,
                NoServerCopy(),
              ),
            ],
            complete: true,
          ),
        );
        world.commitMove(1);
        world.settle();
        expect(world.views().single.state, isA<NeedsUser>());
        Object? refused;
        unawaited(
          useCloudAs(world.store, otherAccount, strategyId).then<void>(
            (_) {},
            onError: (Object error) => refused = error,
          ),
        );
        world.settle();
        expect(refused, isA<StateError>());
        expect(world.views().single.state, isA<NeedsUser>());
        List<String>? used;
        useCloudAs(world.store, servedAccount, strategyId)
            .then((value) => used = value);
        world.settle();
        expect(used, ['move-1']);
        expect(world.queueLength(), 0);
      });
    });

    test(
        'a result compared after a newer one for its strategy was handed over '
        'is skipped as superseded, not reported different', () {
      inWorld((world) {
        final before = world.shadow!.ledger.length;
        world.server.revisions[strategyId] = 5;
        world.shadow!
          ..page(
            strategyId,
            pageSnapshot(serverRows()),
            world.connection,
            stamp: world.stamp,
          )
          ..page(
            strategyId,
            world.shownPage(),
            world.connection,
            stamp: world.stamp,
          );
        world.settle();
        expect(
          [
            for (final entry in world.shadow!.ledger.skip(before))
              entry.verdict,
          ],
          [
            isA<Skipped>().having(
              (skipped) => skipped.reason,
              'reason',
              SkipReason.superseded,
            ),
            isA<ComparedEqual>(),
          ],
        );
      });
    });

    test(
        'after a restart, a page recorded before the run\'s first page list is '
        'skipped for comparison, not reported different', () {
      final storage = MemoryStorage();
      inWorld((world) {}, storage: storage);
      inWorld(
        (world) {
          world.shadow!.page(
            strategyId,
            pageSnapshot(serverRows()),
            world.connection,
            stamp: world.stamp,
          );
          world.settle();
          expect(world.sender.store.reports.whereType<ResultWritten>(),
              hasLength(1));
          expect(
            world.shadow!.ledger.single.verdict,
            isA<Skipped>().having(
              (skipped) => skipped.reason,
              'reason',
              SkipReason.beforePageList,
            ),
          );
        },
        storage: storage,
        addStrategy: false,
      );
    });

    test(
        'a result written into its session after the connection changed '
        'justifies nothing: the next send opens a new session first and goes '
        'out checked', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.sender.hold('held by the test');
        world.commitElementDelete('delete-1');
        world.settle();
        holdNextWrite(storage, () => world.connection = 2);
        world.showResult();
        final shown = world.arrivals.whereType<ResultForStore>().last;
        expect(world.intake.outcomes[shown], isA<ResultRecorded>());
        final before = world.written().length;
        world.sender.release();
        world.settle();
        expect(
          world.written().skip(before).map((event) => event.runtimeType),
          containsAllInOrder([ConnectionReturned, BatchClaimed]),
        );
        final sent = world.server.calls.single.ops.single as ElementDeleteOp;
        expect(sent.lastWriterWins, isFalse);
      }, storage: storage);
    });

    test(
        'signing out ends the sessions: signed back in as the same account on '
        'the same connection, a delete queued before is sent checked', () {
      inWorld((world) {
        world.sender.hold('held by the test');
        world.commitElementDelete('delete-1');
        world.settle();
        world.signIn(null);
        world.settle();
        expect(world.sender.bound, isEmpty);
        world.signIn(servedAccount);
        world.settle();
        world.sender.release();
        world.settle();
        final sent = world.server.calls.single.ops.single as ElementDeleteOp;
        expect(sent.lastWriterWins, isFalse);
      });
    });
  });

  test(
      'shadow-only mode compares while the queue holds this device\'s own '
      'work, as it did before the sender', () async {
    final store = await openStore(MemoryStorage());
    final shadow = shadowOn(store)
      ..pageList(strategyId, pageList(serverRows()), 0)
      ..page(strategyId, pageSnapshot(serverRows()), 0);
    await shadow.idle;
    final row = switch (await store.readStrategy(strategyId)) {
      Found(:final value) => value.strategy,
      final other => throw StateError('$other'),
    };
    expect(
      await store.commitAllAs(servedAccount, strategyId, [
        StrategyPatchOp(
          opId: 'rename',
          expectedStrategyRevision: (row.toJson()! as Map)['revision']! as int,
          name: 'Renamed',
        ),
      ]),
      isA<Saved<List<Committed>, CommitRefusal>>(),
    );

    shadow.page(strategyId, pageSnapshot(serverRows()), 0);
    await shadow.idle;

    expect(shadow.ledger.last.verdict, isNot(isA<Skipped>()));
  });

  group('through the real provider', () {
    test(
        'disposing the container during a call ends quietly: nothing throws, '
        'and the attempt is left for the next run', () {
      inWorld((world) {
        world.sender.dispose();
        final answer = Completer<StoreBatchOutcome>();
        final calls = <List<String>>[];
        final container = ProviderContainer(
          overrides: [
            storeBatchSendProvider.overrideWithValue(({
              required strategyPublicId,
              required clientId,
              required ops,
              required account,
            }) {
              calls.add([for (final op in ops) op.opId]);
              return answer.future;
            }),
            convexSignInsProvider.overrideWithValue(const Stream.empty()),
            cloudSenderClockProvider.overrideWithValue(
              () => start.add(world.async.elapsed),
            ),
            senderSignInWatchProvider.overrideWithValue(_signIns),
            senderConnectionProvider.overrideWithValue(() => 1),
            convexConnectionSnapshotProvider.overrideWith((ref) => true),
            authChangesProvider.overrideWithValue(
              () => (changes: 1, authenticated: true, subject: 'account-a'),
            ),
          ],
        );
        final sender = container
            .read(cloudSenderProvider.notifier)
            .begin(world.store, build: 'test-build');
        world.commitMove(1);
        world.settle();
        expect(calls, [
          ['move-1'],
        ]);
        container.dispose();
        expect(sender.view.run, 'disposed');
        answer.complete(
          StoreBatchAnswered(
            [const AppliedAnswer('move-1', revision: 3)],
            complete: true,
          ),
        );
        world.settle(const Duration(minutes: 1));
        expect(world.views().single.state, isA<Sending>());
      });
    });
  });
}
