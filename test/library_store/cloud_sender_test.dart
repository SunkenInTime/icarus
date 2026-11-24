import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/dev/drive/drive_cloud_store.dart' show useCloudAs;
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/cloud_shadow.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart'
    show
        openStore,
        pageId,
        secondPage,
        pageList,
        pageSnapshot,
        serverRows,
        servedAccount,
        shadowOn,
        strategyId;
import 'sender_world.dart';

final _signIns = StateProvider<int>((ref) => 0);

final _editorOpen = StateProvider<String?>((ref) => null);

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
            expect(
              {for (final call in server.calls) call.clientId},
              {'client-1'},
              reason: at,
            );
          },
          storage: storage,
          server: server,
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
          world.server.roles[strategyId] = StoreReadRole.viewer;
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

    test(
        'with nothing to do but retire its landed work, the loop reads once '
        'and does not look again by itself', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        final looks = world.sender.looks;
        final reads = world.server.readCalls.length;
        world.settle(const Duration(minutes: 10));
        expect(world.server.readCalls.skip(reads).map((call) => '$call'), [
          'page p1',
        ]);
        expect(world.cloud().queue.landed, isEmpty);
        expect(world.sender.looks - looks, lessThanOrEqualTo(2));
      });
    });

    test(
        'adopting a strategy the store holds after a restart writes the '
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
  });

  group('the round-five cases', () {
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

  group('the round-six cases', () {
    test(
        'a sign-out and sign-in as the same account that the loop never '
        'looks between still ends the session: a delete queued before is '
        'sent checked', () {
      inWorld((world) {
        final reply = Completer<void>();
        world.server.answerNext(strategyId, (call) {
          final answered = world.server.applyAll(call);
          return reply.future.then((_) => answered);
        });
        world.commitAdds(1);
        world.settle(const Duration(milliseconds: 300));
        expect(world.server.calls, hasLength(1));
        world.commitElementDelete('delete-1');
        world
          ..signIn(null)
          ..signIn(servedAccount);
        reply.complete();
        world.settle();
        final sent = world.server.calls.last.ops.single as ElementDeleteOp;
        expect(sent.lastWriterWins, isFalse);
      });
    });

    test(
        'a connection that changes while the queue is read gets no session '
        'written for it', () {
      inWorld((world) {
        final before = world.written().whereType<ConnectionReturned>().length;
        world.sender.hold('held by the test');
        world.connection = 2;
        world.commitMove(1);
        world.settle();
        world.slowStore.afterRead = const Duration(seconds: 1);
        world.sender.release();
        world.async.elapse(const Duration(milliseconds: 500));
        world.slowStore.afterRead = Duration.zero;
        world.connection = 3;
        world.settle();
        expect(
          world.written().whereType<ConnectionReturned>(),
          hasLength(before + 1),
        );
        expect(world.server.calls, hasLength(1));
      });
    });

    test(
        'an edit committed while the queue is read moves the claim to the end '
        'of its own wait', () {
      inWorld((world) {
        final calledAt = <Duration>[];
        world.server.onCall = (_) => calledAt.add(world.async.elapsed);
        world.slowStore.afterRead = const Duration(milliseconds: 100);
        world.commitAdds(1);
        world.async.elapse(const Duration(milliseconds: 230));
        world.commitAdds(1, from: 1);
        final edited = world.async.elapsed;
        world.settle();
        expect(
          calledAt.first,
          greaterThanOrEqualTo(edited + timing.wait),
        );
      });
    });

    test(
        'a status listener may dispose the sender, and the status stream '
        'then closes', () {
      inWorld((world) {
        var closed = false;
        world.sender.views.listen(
          (view) {
            if (view.run.startsWith('held')) world.sender.dispose();
          },
          onDone: () => closed = true,
        );
        world.sender.hold('held by the test');
        world.settle();
        expect(world.sender.disposed, isTrue);
        expect(closed, isTrue);
      });
    });

    test(
        'the sender keeps its last thousand reports, and tests and the driver '
        'can keep them all', () {
      inWorld((world) {
        final kept = SenderStore(world.store);
        final all = SenderStore(world.store, keepsAllReports: true);
        for (var n = 0; n < 1200; n++) {
          kept.report(EventNotApplied(strategyId, '$n'));
          all.report(EventNotApplied(strategyId, '$n'));
        }
        expect(kept.reports, hasLength(SenderStore.reportsKept));
        expect(kept.reportsDropped, 200);
        expect((kept.reports.first as EventNotApplied).why, '200');
        expect(all.reports, hasLength(1200));
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

  group('the read step', () {
    List<String> readsAfter(World world, int before) =>
        [for (final call in world.server.readCalls.skip(before)) '$call'];

    test(
        'adopting the strategy the editor opens reads its page list, then each '
        'page, one read per step, as the strategy\'s account', () {
      inWorld(
        (world) {
          world.sender.adopt(strategyId);
          world.settle();
          expect(readsAfter(world, 0), ['list', 'page p1']);
          expect(
            world.server.readCalls.map((call) => call.account),
            everyElement(servedAccount),
          );
          expect(world.firstElement().publicId, isNotEmpty);
          expect(world.sender.adopting(strategyId), isFalse);
        },
        addStrategy: false,
      );
    });

    test('a strategy this account can only view is not adopted', () {
      final server = FakeServer()..roles[strategyId] = StoreReadRole.viewer;
      inWorld(
        (world) {
          world.sender.adopt(strategyId);
          world.settle();
          expect(readsAfter(world, 0), ['list']);
          expect(
            (world.store.library as LibraryOpen).list.strategies,
            isEmpty,
          );
        },
        server: server,
        addStrategy: false,
      );
    });

    test(
        'budget: 50 whole-row moves in five bursts with minute pauses read '
        'nothing before they are sent, and the page twice to retire landed '
        'work: at the first pause, then not again for five minutes', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        for (var burst = 0; burst < 5; burst++) {
          for (var n = 1; n <= 10; n++) {
            world.commitMove(burst * 10 + n);
            world.settle();
          }
          world.settle(const Duration(minutes: 1));
        }
        expect(world.server.calls, hasLength(50));
        expect(world.server.applied, 50);
        expect(readsAfter(world, before), ['page p1', 'page p1']);
        expect(world.cloud().queue.landed, isEmpty);
      });
    });

    test(
        'budget: a first edit, a field merge and a burst of ten edits to one '
        'item read nothing before they are sent; the burst\'s edits wait '
        'behind each other on the one row', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        world.commitMove(1);
        world.settle();
        world.commitMerge(2);
        world.settle();
        for (var n = 0; n < 10; n++) {
          world.commitMove(10 + n);
          world.async.elapse(const Duration(milliseconds: 50));
        }
        world.settle();
        expect(world.server.calls, hasLength(12));
        expect(world.queueLength(), 0);
        expect(readsAfter(world, before), isEmpty);
      });
    });

    test(
        'budget: a start with unsent work in three strategies sends it with no '
        'read first, then reads once per strategy to retire it', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld((world) {
        world
          ..addOtherStrategy()
          ..addOtherStrategy(id: 'hand-3')
          ..sender.hold('held by the test')
          ..commitMove(1)
          ..commitRename(otherStrategy, 'other')
          ..commitRename('hand-3', 'third')
          ..settle();
      }, storage: storage, server: server);
      inWorld(
        (world) {
          final before = server.readCalls.length;
          world.settle(const Duration(seconds: 20));
          expect(server.calls, hasLength(3));
          expect(readsAfter(world, before), isEmpty);
          world.settle(const Duration(minutes: 1));
          expect(
            readsAfter(world, before)..sort(),
            ['list', 'list', 'page p1'],
          );
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a whole write after a field merge that landed at a revision a '
        'teammate made reads its page once before it is decided', () {
      inWorld((world) {
        world.server.answerNext(strategyId, (call) async {
          world.teammateRotates(1);
          return world.server.applyAll(call);
        });
        world.commitMerge(1);
        world.settle();
        expect(world.cloud().queue.landed.single.produced, isNull);
        final before = world.server.readCalls.length;
        world.commitMove(2);
        world.settle();
        expect(readsAfter(world, before), ['page p1']);
        expect(
          world.queueLength() == 0 || world.views().single.state is NeedsUser,
          isTrue,
        );
      });
    });

    test(
        'after a restart a page delete reads the page list and the page, one '
        'per step, then goes out', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      inWorld(
        (world) {
          final before = server.readCalls.length;
          world.commitPageDelete('delete-p2', secondPage().page.publicId);
          world.settle();
          expect(readsAfter(world, before), ['list', 'page p2']);
          expect(
            [for (final call in server.calls) ...call.opIds],
            contains('delete-p2'),
          );
          world.settle(const Duration(minutes: 1));
          expect(readsAfter(world, before), ['list', 'page p2', 'list']);
          expect(world.cloud().queue.landed, isEmpty);
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'edit access lost is lifted by a page list that says the account '
        'edits, and a viewer\'s stays held, read again only after ten minutes',
        () {
      for (final role in [StoreReadRole.editor, StoreReadRole.viewer]) {
        inWorld((world) {
          world.server.roles[strategyId] = role;
          world.server.answerWith(
            strategyId,
            const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
          );
          final before = world.server.readCalls.length;
          world.commitMove(1);
          world.settle(const Duration(minutes: 1));
          expect(
            readsAfter(world, before),
            role.edits ? ['list', 'page p1'] : ['list'],
            reason: '$role',
          );
          if (role.edits) {
            expect(world.written(), contains(isA<EditAccessConfirmed>()));
            expect(world.queueLength(), 0);
          } else {
            expect(world.face(), Face.editAccessLost);
            final first = world.server.readCalls.last.at!;
            final again = first.add(const Duration(minutes: 10));
            world.settle(
              again.difference(start.add(world.async.elapsed)) -
                  const Duration(seconds: 1),
            );
            expect(readsAfter(world, before), ['list']);
            world.settle(const Duration(seconds: 2));
            expect(readsAfter(world, before), ['list', 'list']);
            expect(world.server.readCalls.last.at!.isBefore(again), isFalse);
          }
        });
      }
    });

    test(
        'a read refused as FORBIDDEN is a fact beside the sync state, read '
        'again after ten minutes and cleared by a read that is answered', () {
      inWorld((world) {
        world.server.answerReadWith(
          strategyId,
          const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden'),
        );
        world.commitMove(1);
        world.settle();
        expect(world.sender.cannotRead(strategyId), isNull);
        world.settle(const Duration(minutes: 1));
        expect(world.sender.cannotRead(strategyId), isNotNull);
        expect(world.cloud().queue.landed, isNotEmpty);
        world.settle(const Duration(minutes: 11));
        expect(world.sender.cannotRead(strategyId), isNull);
        expect(world.cloud().queue.landed, isEmpty);
      });
    });

    test('a read refused as FORBIDDEN does not hold back the next send', () {
      inWorld((world) {
        world.server.answerReadWith(
          strategyId,
          const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden'),
        );
        world.commitMove(1);
        world.settle(const Duration(minutes: 1));
        expect(world.sender.cannotRead(strategyId), isNotNull);
        world.commitMove(2);
        world.settle();
        expect(world.server.calls.last.opIds, ['move-2']);
      });
    });

    test('the run-wide refusals of a read hold the run as a call\'s do', () {
      for (final (refusal, hold) in [
        (StoreReadRefusal.accountMismatch, isA<SignInHold>()),
        (StoreReadRefusal.unauthenticated, isA<SignInHold>()),
        (StoreReadRefusal.upgradeRequired, isA<UpgradeHold>()),
      ]) {
        inWorld((world) {
          world.server.answerReadWith(
            strategyId,
            StoreReadRefused(refusal, '$refusal'),
          );
          world.commitMove(1);
          world.settle(const Duration(minutes: 1));
          expect(world.sender.runHold, hold, reason: '$refusal');
        });
      }
    });

    test('a lost read is tried again after the write retry delay', () {
      inWorld((world) {
        world.server.answerReadWith(
          strategyId,
          const StoreReadLost(TransportFailure.network, 'lost'),
        );
        world.commitMove(1);
        world.settle();
        final before = world.server.readCalls.length;
        world.settle(const Duration(seconds: 29));
        expect(readsAfter(world, before), ['page p1']);
        expect(world.cloud().queue.landed, isNotEmpty);
        world.settle(const Duration(seconds: 3));
        expect(readsAfter(world, before), ['page p1', 'page p1']);
        expect(world.cloud().queue.landed, isEmpty);
      });
    });

    test(
        'a read answered after the connection, the account or the sign-outs '
        'changed is dropped, and read again under the new inputs', () {
      for (final change in <void Function(World)>[
        (world) => world.connection = 2,
        (world) => world
          ..signIn(null)
          ..signIn(servedAccount),
      ]) {
        inWorld((world) {
          world.commitMove(1);
          world.settle();
          world.server.answerReadNext(strategyId, (call) async {
            change(world);
            return world.server.answerNow(call);
          });
          final before = world.server.readCalls.length;
          final recorded = world.readsRecorded().length;
          world.settle(const Duration(minutes: 1));
          expect(readsAfter(world, before), ['page p1', 'page p1']);
          expect(world.readsRecorded().skip(recorded), ['page p1']);
          expect(world.cloud().queue.landed, isEmpty);
        });
      }
    });

    test(
        'a sign-in refresh mid-session does not stop results: the next read '
        'is recorded', () {
      inWorld((world) {
        world.authChanges = 2;
        world.commitMove(1);
        world.settle(const Duration(minutes: 1));
        expect(world.readsRecorded().last, 'page p1');
        expect(world.cloud().queue.landed, isEmpty);
      });
    });
  });

  group('the review round', () {
    List<String> readsAfter(World world, int before) =>
        [for (final call in world.server.readCalls.skip(before)) '$call'];

    String secondId() => secondPage().page.publicId;

    test(
        'a result the disk refuses to write is not counted as read: the page '
        'is read again and recorded', () {
      inWorld(
        (world) {
          var refused = false;
          world.server.onRead = (call) {
            if (call.page != null && !refused) {
              refused = true;
              world.lease.refuseNext = 1;
            }
          };
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 10));
          expect(readsAfter(world, 0), ['list', 'page p1', 'page p1']);
          expect(world.readsRecorded(), ['the page list', 'page p1']);
          expect(world.sender.adopting(strategyId), isFalse);
        },
        addStrategy: false,
      );
    });

    test(
        'a page delete whose page a teammate deletes between its two reads '
        'is read again, not left waiting', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      inWorld(
        (world) {
          server.readCalls.clear();
          server.onRead = (call) {
            if (call.page == secondId() && server.readCalls.length == 2) {
              world.teammateDeletesPage(secondId());
            }
          };
          world.commitPageDelete('delete-p2', secondId());
          world.settle(const Duration(minutes: 1));
          expect(readsAfter(world, 0).take(2), ['list', 'page p2']);
          expect(readsAfter(world, 0).length, inInclusiveRange(3, 6));
          expect(world.queueLength(), 0);
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a need that its reads cannot settle is read three times, then shown '
        'as could not resolve, and after ten minutes read three times again',
        () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      inWorld(
        (world) {
          server.overrideRead = (call) => call.page == secondId()
              ? const StoreReadAnswered(PageGone('nowhere'))
              : null;
          server.readCalls.clear();
          world.commitPageDelete('delete-p2', secondId());
          world.settle(const Duration(minutes: 1));
          final pageReads = [
            for (final call in server.readCalls)
              if (call.page == secondId()) call,
          ];
          expect(pageReads, hasLength(3));
          expect(world.sender.couldNotResolve(strategyId), isNotNull);
          expect(world.views().single.holds, isNotEmpty);
          world.settle(const Duration(minutes: 8));
          expect(
            [
              for (final call in server.readCalls)
                if (call.page == secondId()) call
            ],
            hasLength(3),
          );
          world.settle(const Duration(minutes: 2));
          expect(
            [
              for (final call in server.readCalls)
                if (call.page == secondId()) call
            ],
            hasLength(6),
          );
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'landed work whose page a teammate deleted is not left in silence: it '
        'is read again and then shown as could not resolve', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        world.teammateDeletesPage(pageId);
        final before = world.server.readCalls.length;
        world.settle(const Duration(minutes: 40));
        for (final page in Retiring.landedByPage(world.cloud()).keys) {
          final (read, subject) = page == Retiring.list
              ? ('list', 'the page list')
              : ('page $page', 'page $page');
          expect(
            readsAfter(world, before).where((call) => call == read),
            hasLength(greaterThanOrEqualTo(3)),
            reason: subject,
          );
          expect(
            world.sender.couldNotResolve(strategyId)?.subjects,
            contains('landed work on $subject'),
          );
        }
        expect(readsAfter(world, before).length, lessThanOrEqualTo(8));
      });
    });

    test(
        'a page row\'s need is answered from the page list, which shows page '
        'rows, not from the page', () {
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
          final p2 = secondId();
          final strategyRevision = (world
              .rowOf(
                (content) => content.strategy,
              )
              .toJson()! as Map)['revision']! as int;
          world.commit([
            PageReorderOp(
              opId: 'reorder',
              pagePublicId: p2,
              sortIndex: 0,
              expectedStrategyRevision: strategyRevision,
            ),
          ]);
          world.settle(const Duration(seconds: 3));
          final pageRevision = (world
              .rowOf(
                (content) =>
                    content.pages.firstWhere((page) => page.publicId == p2),
              )
              .toJson()! as Map)['revision']! as int;
          final before = world.server.readCalls.length;
          world.commit([
            PagePatchOp(
              opId: 'rename',
              pagePublicId: p2,
              expectedPageRevision: pageRevision,
              name: 'Renamed',
            ),
          ]);
          world.settle(const Duration(seconds: 5));
          expect(readsAfter(world, before), ['list']);
          expect(world.server.calls.last.opIds, ['rename']);
        },
        addStrategy: false,
      );
    });

    test('reopening a strategy the store holds reads nothing more', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 20));
        expect(readsAfter(world, before), isEmpty);
      });
    });

    test('a restart resumes reading the pages an adoption had not read yet',
        () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          server.overrideRead = (call) => call.page != null
              ? const StoreReadLost(TransportFailure.network, 'cut')
              : null;
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 1));
          expect(world.sender.adopting(strategyId), isTrue);
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      server.overrideRead = null;
      inWorld(
        (world) {
          final before = server.readCalls.length;
          world.settle();
          expect(readsAfter(world, before), ['page p1']);
          expect(world.firstElement().publicId, isNotEmpty);
          expect(world.sender.adopting(strategyId), isFalse);
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a request to adopt is bound to the account that asked: signed in as '
        'another before it is tried, nothing is read', () {
      inWorld(
        (world) {
          world.sender.adopt(strategyId);
          world.signIn(otherAccount);
          world.settle();
          expect(world.server.readCalls, isEmpty);
        },
        addStrategy: false,
      );
    });

    test(
        'a first adoption whose write the disk refuses waits the write retry '
        'delay before it reads the page list again', () {
      inWorld(
        (world) {
          world.lease.refuseNext = 3;
          world.sender.adopt(strategyId);
          for (var n = 0; n < 3; n++) {
            world.sender.wake();
            world.async.elapse(const Duration(milliseconds: 100));
          }
          expect(readsAfter(world, 0), ['list']);
          world.settle(const Duration(seconds: 3));
          expect(readsAfter(world, 0), ['list', 'list']);
        },
        addStrategy: false,
      );
    });

    test(
        'a lost read for edit access is tried again after the read retry '
        'delay, not the viewer\'s ten minutes', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
        );
        world.server.answerReadWith(
          strategyId,
          const StoreReadLost(TransportFailure.network, 'lost'),
        );
        final before = world.server.readCalls.length;
        world.commitMove(1);
        world.settle(const Duration(seconds: 5));
        expect(readsAfter(world, before), ['list', 'list']);
        expect(world.written(), contains(isA<EditAccessConfirmed>()));
      });
    });

    test(
        'a result written while the connection changes is kept in the store '
        'but neither reported nor counted by the sender', () {
      final storage = MemoryStorage();
      inWorld(
        (world) {
          world.server.onRead = (call) {
            if (call.page != null && world.connection == 1) {
              holdNextWrite(storage, () => world.connection = 2);
            }
          };
          world.sender.adopt(strategyId);
          world.settle();
          expect(readsAfter(world, 0), ['list', 'page p1']);
          expect(world.readsRecorded(), ['the page list']);
          expect(world.firstElement().publicId, isNotEmpty);
        },
        storage: storage,
        addStrategy: false,
      );
    });

    test(
        'a read answered by a future of a narrower type is recorded, not '
        'taken for lost', () {
      inWorld((world) {
        world.server.answerReadNext(
          strategyId,
          (call) => Future<StoreReadAnswered>.value(
            world.server.answerNow(call) as StoreReadAnswered,
          ),
        );
        world.commitMove(1);
        final before = world.server.readCalls.length;
        world.settle(const Duration(minutes: 1));
        expect(readsAfter(world, before), ['page p1']);
        expect(world.cloud().queue.landed, isEmpty);
      });
    });

    test(
        'budget: an hour of edits with a pause every minute reads the page '
        'twelve times to retire landed work, and nothing else', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        for (var minute = 0; minute < 60; minute++) {
          world.commitMove(minute);
          world.settle(const Duration(minutes: 1));
        }
        expect(world.server.calls, hasLength(60));
        expect(
          readsAfter(world, before),
          [for (var n = 0; n < 12; n++) 'page p1'],
        );
      });
    });
  });

  group('reads remember one sign-in and connection', () {
    List<String> readsAfter(World world, int before) =>
        [for (final call in world.server.readCalls.skip(before)) '$call'];

    String secondId() => secondPage().page.publicId;

    void withSecondPage(MemoryStorage storage, FakeServer server) => inWorld(
          (world) {
            world.secondPageOnServer();
            world.sender.adopt(strategyId);
            world.settle();
          },
          storage: storage,
          server: server,
          addStrategy: false,
        );

    test(
        'asking to adopt a strategy the store holds reads nothing and leaves '
        'nothing pending, even when the server has deleted it', () {
      inWorld((world) {
        world.server.rows.remove(strategyId);
        final before = world.server.readCalls.length;
        world.sender.adopt(strategyId);
        world.settle(const Duration(minutes: 1));
        expect(readsAfter(world, before), isEmpty);
        expect(world.sender.adopting(strategyId), isFalse);
      });
    });

    test(
        'a page delete whose page read the disk refuses to write is read '
        'again, and a refused read is not counted toward could not resolve',
        () {
      final storage = MemoryStorage();
      final server = FakeServer();
      withSecondPage(storage, server);
      inWorld(
        (world) {
          var refused = 0;
          server.onRead = (call) {
            if (call.page == secondId() && refused < 3) {
              refused++;
              world.lease.refuseNext = 1;
            }
          };
          final before = server.readCalls.length;
          world.commitPageDelete('delete-p2', secondId());
          world.settle(const Duration(minutes: 1));
          expect(
            readsAfter(world, before).where((read) => read == 'page p2'),
            hasLength(4),
          );
          expect(
            world.readsRecorded().where((read) => read == 'page p2'),
            hasLength(1),
          );
          expect(world.sender.couldNotResolve(strategyId), isNull);
          expect(
            [for (final call in server.calls) ...call.opIds],
            contains('delete-p2'),
          );
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a need shown as could not resolve is read again at once on a new '
        'connection', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      withSecondPage(storage, server);
      inWorld(
        (world) {
          server.overrideRead = (call) => call.page == secondId()
              ? const StoreReadAnswered(PageGone('nowhere'))
              : null;
          world.commitPageDelete('delete-p2', secondId());
          world.settle(const Duration(minutes: 1));
          expect(world.sender.couldNotResolve(strategyId), isNotNull);
          final offline = server.readCalls.length;
          world.connection = null;
          world.settle();
          expect(readsAfter(world, offline), isEmpty);
          final before = server.readCalls.length;
          world.connection = 2;
          world.settle(const Duration(seconds: 5));
          expect(readsAfter(world, before), contains('page p2'));
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a second loss of edit access within ten minutes of an editor\'s '
        'answer is read at once', () {
      inWorld((world) {
        world.server
          ..roles[strategyId] = StoreReadRole.editor
          ..answerWith(
            strategyId,
            const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
          );
        world.commitMove(1);
        world.settle(const Duration(seconds: 30));
        expect(world.queueLength(), 0);
        world.server
          ..roles[strategyId] = StoreReadRole.viewer
          ..answerWith(
            strategyId,
            const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
          );
        final before = world.server.readCalls.length;
        world.commitMove(2);
        world.settle(const Duration(seconds: 5));
        expect(readsAfter(world, before), ['list']);
        expect(world.face(), Face.editAccessLost);
      });
    });

    test(
        'a request to adopt made before a sign-out is dropped: signed in again '
        'as the same account, nothing is read', () {
      inWorld(
        (world) {
          world.sender.adopt(strategyId);
          world.signIn(null);
          world.signIn(servedAccount);
          world.settle();
          expect(world.server.readCalls, isEmpty);
          expect(world.sender.adopting(strategyId), isFalse);
        },
        addStrategy: false,
      );
    });

    test(
        'the read record is replaced whole, every field, on a new connection, '
        'on a different account and after a sign-out, before anything is '
        'planned', () {
      final changes = <String, void Function(World)>{
        'a new connection': (world) => world
          ..connection = null
          ..connection = 2,
        'a different account': (world) => world
          ..signIn(otherAccount)
          ..signIn(servedAccount),
        'a sign-out': (world) => world
          ..signIn(null)
          ..signIn(servedAccount),
      };
      for (final MapEntry(key: change, value: make) in changes.entries) {
        inWorld((world) {
          final now = start.add(world.async.elapsed);
          final seeded = (
            under: readsUnder(world.sender.inputs),
            retryAt: now.add(const Duration(hours: 1)),
            failures: 4,
            cannotRead: const CannotRead('seeded'),
            viewer: (lossAttempt: 7, until: now.add(const Duration(hours: 1))),
            rounds: {PageResult(pageId): (rounds: 3, at: now)},
            retired: {
              Retiring.list: (works: {(1, 0)}, at: now, rounds: 3),
            },
          );
          world.sender.rememberReads(strategyId, seeded);
          expect(world.sender.readMemory(strategyId), seeded, reason: change);
          make(world);
          expect(
            world.sender.readMemory(strategyId),
            freshReads(readsUnder(world.sender.inputs)),
            reason: change,
          );
          final before = world.server.readCalls.length;
          world.commitMove(1);
          world.settle(const Duration(seconds: 40));
          expect(readsAfter(world, before), ['page p1'], reason: change);
        });
      }
    });
  });

  group('the bot review of the third round', () {
    List<String> readsAfter(World world, int before) =>
        [for (final call in world.server.readCalls.skip(before)) '$call'];

    test(
        'a read-back that throws after adoption saves ends the sender with the '
        'store\'s words instead of escaping the loop', () {
      inWorld(
        (world) {
          world.slowStore.readsThrow = true;
          world.sender.adopt(strategyId);
          world.settle();
          expect(world.sender.ended, contains('the store threw'));
          var finished = false;
          world.sender.done.then((_) => finished = true);
          world.settle();
          expect(finished, isTrue);
        },
        addStrategy: false,
      );
    });

    test(
        'the read is planned from the queue as it stands after the session '
        'opens, not from before it', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      inWorld(
        (world) {
          world.commitMove(1);
          world.settle(const Duration(seconds: 5));
          expect(world.cloud().queue.landed, isNotEmpty);
          world.connection = null;
          world.settle(const Duration(seconds: 40));
          final before = server.readCalls.length;
          world.slowStore.duringSessionWrite = () => world.commitPageDelete(
                'delete-p2',
                secondPage().page.publicId,
              );
          world.connection = 2;
          world.settle(const Duration(seconds: 1));
          expect(readsAfter(world, before).first, 'list');
          expect(server.readCalls[before].why, 'the queue asked for it');
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });
  });

  group('the server\'s window for unchecked sends', () {
    List<ServerCall> callsOf(World world, String opId) => [
          for (final call in world.server.calls)
            if (call.opIds.contains(opId)) call,
        ];

    test(
        'the first edit after a quiet start goes checked; the next, within '
        '20 s of an answer, goes unchecked on that answer\'s server time', () {
      inWorld((world) {
        final before = world.server.serverNow;
        world.commitMerge(1);
        world.settle();
        final [first] = callsOf(world, 'merge-1');
        expect(first.serverTime, isA<ServerTimeAsked>());
        expect(first.unchecked, isEmpty);
        expect(first.basis, isNull);
        final answeredAt = world.server.serverNow;
        world.async.elapse(const Duration(seconds: 5));
        world.commitMerge(2);
        world.settle();
        final [second] = callsOf(world, 'merge-2');
        expect(second.unchecked, ['merge-2']);
        expect(second.basis, inInclusiveRange(before, answeredAt));
        expect(world.queueLength(), 0);
      });
    });

    test(
        'a batch refused as late is sent again at once, checked, under the '
        'same op id, and a same-field edit right after it goes checked too',
        () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        world.sleep(const Duration(seconds: 40));
        var editedDuringTheResend = false;
        world.server.onCall = (call) {
          if (call.opIds.contains('merge-2') &&
              call.unchecked.isEmpty &&
              !editedDuringTheResend) {
            editedDuringTheResend = true;
            world.commitMerge(3);
          }
        };
        world.commitMerge(2);
        world.settle();
        expect(editedDuringTheResend, isTrue);
        final [late, again] = callsOf(world, 'merge-2');
        expect(late.unchecked, ['merge-2']);
        expect(again.unchecked, isEmpty);
        expect(again.basis, isNull);
        expect(
          world.written(),
          contains(
            isA<BatchRefused>().having(
              (refused) => refused.refusal,
              'refusal',
              BatchRefusal.uncheckedTooLate,
            ),
          ),
        );
        world.settle();
        final [third] = callsOf(world, 'merge-3');
        expect(third.unchecked, isEmpty);
        expect(world.queueLength(), 0);
        expect(
          world.sender.store.reports.whereType<UncheckedWithoutBasis>(),
          isEmpty,
        );
      });
    });

    test(
        'a server time answered after the connection changed is not held, '
        'so the next edit goes checked', () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        final answer = Completer<StoreBatchOutcome>();
        world.server.answerNext(strategyId, (call) {
          final outcome = world.server.applyAll(call);
          world.connection = 2;
          answer.complete(outcome);
          return answer.future;
        });
        world.async.elapse(const Duration(seconds: 1));
        world.commitMerge(2);
        world.settle();
        world.commitMerge(3);
        world.settle();
        final [third] = callsOf(world, 'merge-3');
        expect(third.unchecked, isEmpty);
      });
    });

    test('a send in flight at a restart is retried checked', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        server.answerNext(strategyId, (call) {
          world.sender.dispose();
          return Completer<StoreBatchOutcome>().future;
        });
        world.commitMerge(2);
        world.settle();
        expect(callsOf(world, 'merge-2').single.unchecked, ['merge-2']);
      }, storage: storage, server: server);
      inWorld(
        (world) {
          world.settle(const Duration(minutes: 1));
          final [_, retry] = callsOf(world, 'merge-2');
          expect(retry.unchecked, isEmpty);
          expect(retry.basis, isNull);
          expect(world.queueLength(), 0);
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
    });

    test(
        'a claim held up behind an earlier write judges its basis when it runs: '
        'held 21 s past a fresh answer, the edit goes checked', () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        world.slowStore.claimWaits = const Duration(seconds: 21);
        world.commitMerge(2);
        world.settle(const Duration(seconds: 30));
        final [held] = callsOf(world, 'merge-2');
        expect(held.unchecked, isEmpty);
        expect(held.basis, isNull);
      });
    });

    test(
        'an unchecked call lost by the transport but landed inside the window '
        'is answered "applied when first received" to its checked retry, and '
        'lands once', () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        world.server.answerNext(strategyId, (call) {
          world.server.applyAll(call);
          return Completer<StoreBatchOutcome>().future;
        });
        world.commitMerge(2);
        world.settle(const Duration(minutes: 2));
        final [lost, retry] = callsOf(world, 'merge-2');
        expect(lost.unchecked, ['merge-2']);
        expect(retry.unchecked, isEmpty);
        expect(world.server.anyAppliedTwice, isFalse);
        expect(world.queueLength(), 0);
      });
    });

    for (final (order, delivered) in [
      ('before its checked retry', const Duration(seconds: 46)),
      ('after its checked retry', const Duration(seconds: 90)),
    ]) {
      test(
          'an unchecked call the transport delivers past the cutoff, $order, is '
          'refused by the server, and the edit lands once, through the retry',
          () {
        inWorld((world) {
          world.commitMerge(1);
          world.settle();
          StoreBatchOutcome? late;
          world.server.answerNext(strategyId, (call) {
            Timer(delivered, () => late = world.server.applyAll(call));
            return Completer<StoreBatchOutcome>().future;
          });
          world.commitMerge(2);
          world.settle(const Duration(minutes: 3));
          expect(late, isA<StoreBatchOutsideWindow>());
          final [original, retry] = callsOf(world, 'merge-2');
          expect(original.unchecked, ['merge-2']);
          expect(retry.unchecked, isEmpty);
          expect(world.server.anyAppliedTwice, isFalse);
          expect(world.queueLength(), 0);
        });
      });
    }

    test(
        'the answer\'s server time is held as of the moment the answer arrived',
        () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        final arrived = Completer<StoreBatchOutcome>();
        Duration? at;
        world.server.answerNext(strategyId, (call) {
          Timer(const Duration(seconds: 3), () {
            at = world.async.elapsed;
            arrived.complete(world.server.applyAll(call));
          });
          return arrived.future;
        });
        world.commitMerge(2);
        world.settle(const Duration(seconds: 10));
        final held = world.written().whereType<ServerTimeHeld>().last;
        expect(held.at, at);
      });
    });

    test(
        'no session opens while a call is awaited, so the session the call '
        'was sent in is the one bound when its answer arrives', () {
      inWorld((world) {
        world.commitMerge(1);
        world.settle();
        final bound = world.sender.bound[strategyId]!.number;
        final arrived = Completer<StoreBatchOutcome>();
        world.server.answerNext(strategyId, (call) {
          Timer(const Duration(seconds: 3), () {
            world.connection = null;
            world.connection = 2;
            world.async.flushMicrotasks();
            expect(world.sender.bound[strategyId]?.number, bound);
            arrived.complete(world.server.applyAll(call));
          });
          return arrived.future;
        });
        world.commitMerge(2);
        world.settle(const Duration(seconds: 10));
        final written = world.written();
        final held = written.whereType<ServerTimeHeld>().last;
        expect(held.session, bound);
        final claimed = written.lastIndexWhere(
          (event) => event is BatchClaimed,
          written.indexOf(held),
        );
        expect(
          written.sublist(claimed, written.indexOf(held)).where(
                (event) =>
                    event is ConnectionLost ||
                    event is ConnectionReturned ||
                    event is AccountChanged ||
                    event is AppRestarted,
              ),
          isEmpty,
        );
      });
    });
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
              required serverTime,
            }) {
              calls.add([for (final op in ops) op.opId]);
              return answer.future;
            }),
            convexSignInsProvider.overrideWithValue(const Stream.empty()),
            storeReadsProvider.overrideWithValue(world.server.reads),
            senderEditorProvider.overrideWithValue(_editorOpen),
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
