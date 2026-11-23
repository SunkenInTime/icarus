import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart' as app;
import 'package:icarus/collab/generated/convex_error_codes.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/cloud_shadow_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show servedAccount, strategyId;
import 'sender_world.dart';

final _signIns = StateProvider<int>((ref) => 0);

void holdWhen(World world, bool Function(StrategyStatus status) when) {
  var held = false;
  world.sender.views.listen((view) {
    if (held) return;
    final status = view.strategies[strategyId];
    if (status != null && when(status)) {
      held = true;
      world.sender.hold('held by the test');
    }
  });
}

bool claiming(StrategyStatus status) =>
    status is StatusBusy && status.flight is ClaimInFlight;

bool calling(StrategyStatus status) =>
    status is StatusBusy && status.flight is CallInFlight;

bool writingAnswer(StrategyStatus status) => switch (status) {
      StatusBusy(
        flight: WriteInFlight(write: StoreWrite(purpose: AnswerOf()))
      ) =>
        true,
      _ => false,
    };

void main() {
  group('the plan for a strategy, from facts', () {
    late StrategySummary summary;

    setUp(() {
      inWorld((world) {
        summary = (world.store.library as LibraryOpen).list.strategies.single;
      });
    });

    StoredStrategy withTally(Tally tally, {Account? owner}) =>
        StoredStrategy(summary, OwnedBy(owner ?? servedAccount), tally);

    final unsent = Tally(
      standing: Standing.good,
      waiting: const {Underway.unsent: 1},
    );
    const online = (account: null, connection: 1, authChanges: 1);
    final signedIn = (account: servedAccount, connection: 1, authChanges: 1);
    final mark = (connection: 1, authChanges: 1, account: servedAccount);

    Plan plan(
      StrategyMemory memory, {
      RunMemory? run,
      SenderInputs? inputs,
      Tally? tally,
      DateTime? now,
    }) =>
        planFor(
          withTally(tally ?? unsent),
          memory,
          run ?? RunMemory(),
          inputs ?? signedIn,
          now ?? start.add(const Duration(seconds: 1)),
          timing,
          build: 'b',
        );

    StrategyMemory opened() => StrategyMemory()
      ..session = mark
      ..restarted = true;

    test('work with an open session is claimed under that session', () {
      final next = plan(opened());
      expect(
        next.action,
        isA<StartClaim>().having((claim) => claim.session, 'session', mark),
      );
    });

    test(
        'a session is opened first: the restart once per run, the account '
        'change when the sign-in count moved, then the connection', () {
      final first = plan(StrategyMemory());
      expect(
        (first.action! as StartWrite).write.events,
        [isA<AppRestarted>(), isA<ConnectionReturned>()],
      );
      final moved = plan(
        opened(),
        inputs: (account: servedAccount, connection: 1, authChanges: 2),
      );
      expect(
        (moved.action! as StartWrite).write.events,
        [isA<AccountChanged>(), isA<ConnectionReturned>()],
      );
    });

    test('an owed write goes before anything else, even while held', () {
      final batch = ClaimedBatch(
        strategyId: strategyId,
        attempt: 1,
        clientId: 'c',
        session: mark,
        ops: const [],
      );
      final owed = StoreWrite(
        servedAccount,
        [ClaimReleased(1)],
        ReleaseOf(batch, ReleaseCause.held),
      );
      final memory = opened()..owed = owed;
      final next = plan(memory, run: RunMemory()..held = 'held');
      expect(next.action, isA<StartWrite>().having((w) => w.write, 'w', owed));
      final waiting = plan(
        memory
          ..retry = WriteRetry(1, start.add(const Duration(minutes: 1)), 'x'),
      );
      expect(waiting.action, isNull);
      expect(waiting.wakeAt, start.add(const Duration(minutes: 1)));
    });

    test('offline with a session open records the connection lost', () {
      final next = plan(
        opened(),
        inputs: (account: servedAccount, connection: null, authChanges: 1),
      );
      expect(
        (next.action! as StartWrite).write.events,
        [isA<ConnectionLost>()],
      );
      expect(
        plan(
          StrategyMemory(),
          inputs: (account: servedAccount, connection: null, authChanges: 1),
        ).action,
        isNull,
      );
    });

    test('another account, or nobody, signed in: nothing is done', () {
      expect(plan(opened(), inputs: online).action, isNull);
      expect(
        plan(
          opened(),
          inputs: (account: otherAccount, connection: 1, authChanges: 1),
        ).status.toString(),
        allOf(contains('account-a'), contains('account-b')),
      );
    });

    test('run holds are read on every plan', () {
      expect(plan(opened(), run: RunMemory()..held = 'x').action, isNull);
      expect(
          plan(opened(), run: RunMemory()..upgradeAsked = true).action, isNull);
      expect(
        plan(opened(), run: RunMemory()..signInWaitsFrom = 1).action,
        isNull,
      );
      expect(
        plan(
          opened(),
          run: RunMemory()..signInWaitsFrom = 1,
          inputs: (account: servedAccount, connection: 1, authChanges: 2),
        ).action,
        isA<StartWrite>(),
      );
    });

    test('a look that found nothing holds until the strategy changes', () {
      final memory = opened()..looked = Looked(summary, 'nothing', null);
      expect(plan(memory).action, isNull);
      final retry = start.add(const Duration(seconds: 30));
      memory.looked = Looked(summary, 'retry', retry);
      expect(plan(memory).wakeAt, retry);
      expect(
        plan(memory, now: retry.add(const Duration(seconds: 1))).action,
        isA<StartClaim>(),
      );
    });

    test('work seen just now settles before it is claimed', () {
      final memory = opened()..seenAt = start;
      expect(plan(memory, now: start).action, isNull);
      expect(plan(memory, now: start).wakeAt, start.add(timing.wait));
    });

    test('a queue standing other than good is the queue\'s hold', () {
      expect(
        plan(
          opened(),
          tally: Tally(
            standing: Standing.editAccessLost,
            waiting: const {Underway.unsent: 1},
          ),
        ).status.toString(),
        contains('editAccessLost'),
      );
    });

    test('a strategy parked by the store stays parked until it changes', () {
      final memory = opened()..parked = Parked(summary, 'held queue');
      expect(plan(memory).status.toString(), contains('held queue'));
    });
  });

  group('the sender over the real queue', () {
    test('sends a commit once, after the wait, as the strategy\'s owner', () {
      inWorld((world) {
        world.commitMove(1);
        world.async.elapse(const Duration(milliseconds: 100));
        expect(world.server.calls, isEmpty);
        world.settle();
        expect(world.server.calls, hasLength(1));
        expect(world.server.calls.single.account, servedAccount);
        expect(world.server.calls.single.opIds, ['move-1']);
        expect(world.queueLength(), 0);
        expect(world.server.wrongAccount, isEmpty);
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

    test('another account\'s work is not sent, and is sent when it is back',
        () {
      inWorld((world) {
        world.commitMove(1);
        world.signIn(otherAccount);
        world.settle();
        expect(world.server.calls, isEmpty);
        expect(world.status(), allOf(contains('account-a'), contains('b')));
        world.signIn(servedAccount);
        world.settle();
        expect(world.server.calls.single.account, servedAccount);
      });
    });

    test(
        'held during the claim, the claim is given back with no call, and '
        'released it is sent once', () {
      inWorld((world) {
        holdWhen(world, claiming);
        world.commitMove(1);
        world.settle();
        expect(world.server.calls, isEmpty);
        expect(world.written(), contains(isA<ClaimReleased>()));
        expect(world.views().single.sendable, isTrue);
        world.sender.release();
        world.settle();
        expect(world.server.calls, hasLength(1));
        expect(world.queueLength(), 0);
      });
    });

    test('held during the call or the answer\'s write, the answer is written',
        () {
      for (final when in [calling, writingAnswer]) {
        inWorld((world) {
          holdWhen(world, when);
          world.commitMove(1);
          world.settle();
          expect(world.server.calls, hasLength(1));
          expect(world.queueLength(), 0);
          world.commitMove(2);
          world.settle();
          expect(world.server.calls, hasLength(1));
        });
      }
    });

    test(
        'disposed during a claim, a call or a write, it ends quietly and the '
        'next run sends the work once under its original client', () {
      for (final when in [claiming, calling, writingAnswer]) {
        final storage = MemoryStorage();
        final server = FakeServer();
        inWorld(
          (world) {
            var disposed = false;
            world.sender.views.listen((view) {
              final status = view.strategies[strategyId];
              if (!disposed && status != null && when(status)) {
                disposed = true;
                scheduleMicrotask(world.sender.dispose);
              }
            });
            world.commitMove(1);
            world.settle();
            expect(world.async.pendingTimers, isEmpty);
          },
          storage: storage,
          server: server,
        );
        inWorld(
          (world) {
            world.sender.nudge();
            world.settle(const Duration(minutes: 5));
            expect(world.queueLength(), 0);
            expect(server.appliedOf(strategyId), 1);
            expect(server.anyAppliedTwice, isFalse);
            if (server.calls.length == 2) {
              expect(server.calls.last.clientId, server.calls.first.clientId);
            }
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
        'UNAUTHENTICATED with the sign-in unchanged makes no further call, '
        'and a hold and release does not clear that wait', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.unauthenticated),
        );
        world.commitMove(1);
        world.settle(const Duration(minutes: 10));
        world.sender
          ..hold('x')
          ..release()
          ..nudge();
        world.settle(const Duration(minutes: 10));
        expect(world.server.calls, hasLength(1));
        world.authChanges = 2;
        world.settle(const Duration(minutes: 5));
        expect(world.server.calls, hasLength(2));
        expect(world.queueLength(), 0);
      });
    });

    test('ACCOUNT_MISMATCH gives the claim back and waits for the sign-in', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchAccountMismatch('signed in as someone else'),
        );
        world.commitMove(1);
        world.settle(const Duration(minutes: 10));
        world.sender
          ..hold('x')
          ..release();
        world.settle(const Duration(minutes: 10));
        expect(world.server.calls, hasLength(1));
        expect(world.written(), contains(isA<ClaimReleased>()));
        world.authChanges = 2;
        world.settle(const Duration(minutes: 5));
        expect(world.server.calls, hasLength(2));
        expect(world.queueLength(), 0);
      });
    });

    test(
        'an upgrade refusal holds every strategy for the run, through a hold '
        'and release', () {
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
          expect(world.server.calls.map((call) => call.strategyId), [
            strategyId,
            otherStrategy,
          ]);
          expect(world.queueLength(otherStrategy), 0);
        });
      }
    });

    test(
        'a disconnect with no editor open is recorded as the owner, and work '
        'made offline is sent once it returns', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        world.showResult();
        world.connection = null;
        world.settle();
        expect(world.written(), contains(isA<ConnectionLost>()));
        world.commitRename(strategyId, 'offline');
        world.settle();
        expect(world.server.calls, hasLength(1));
        world.connection = 2;
        world.settle();
        expect(world.server.calls.last.opIds, ['offline']);
        expect(world.queueLength(), 0);
      });
    });

    test(
        'a storage error in the offline record does not lose the reconnect: '
        'work is sent once the connection is back', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        world.showResult();
        world.commitRename(strategyId, 'queued');
        world.lease.refuseNext = 1;
        world.connection = null;
        world.async.flushMicrotasks();
        world.connection = 2;
        world.settle(const Duration(seconds: 10));
        expect(world.server.calls.last.opIds, ['queued']);
        expect(world.queueLength(), 0);
      });
    });

    test(
        'held while an answer waits to be written again, then released: the '
        'answer is written', () {
      inWorld((world) {
        world.sender.views.listen((view) {
          final status = view.strategies[strategyId];
          if (status != null && calling(status)) {
            world.lease.refusedAreas.add(strategyId);
          }
        });
        world.commitMove(1);
        world.settle();
        expect(world.server.calls, hasLength(1));
        expect(world.status(), contains('could not be written'));
        world.sender.hold('x');
        world.lease.refusedAreas.clear();
        world.sender.release();
        world.settle(const Duration(minutes: 2));
        expect(world.queueLength(), 0);
        expect(world.server.calls, hasLength(1));
      });
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
        expect(world.queueLength(otherStrategy), 0);
        expect(world.status(), contains('could not be written'));
      });
    });

    test('a store closed during a call ends the sender with the reason', () {
      inWorld(
        (world) {
          final answer = Completer<StoreBatchOutcome>();
          world.server.answerNext(strategyId, (_) => answer.future);
          world.commitMove(1);
          world.settle();
          world.store.close();
          world.async.flushMicrotasks();
          answer.complete(world.server.applyAll(world.server.calls.single));
          world.settle(const Duration(minutes: 5));
          expect(world.sender.run.shut, isNotNull);
          expect(world.sender.view.run, startsWith('ended'));
          expect(world.lease.commits, lessThan(20));
        },
      );
    });

    test(
        'the shadow and the sender opening one strategy at once write the '
        'restart once and one session', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      var before = 0;
      inWorld((world) {
        world.commitMove(1);
        world.sender.hold('x');
        world.settle();
        before = world.cloud().queue.nextSession;
      }, storage: storage, server: server);
      inWorld(
        (world) {
          world.sender.nudge();
          world.addServedStrategy();
          world.settle();
          expect(world.cloud().queue.nextSession, before + 2);
          final events = world.written();
          expect(events.whereType<AppRestarted>(), hasLength(1));
          expect(events.whereType<ConnectionReturned>(), hasLength(1));
          expect(server.calls, hasLength(1));
        },
        storage: storage,
        server: server,
        addStrategy: false,
        clientId: 'client-2',
      );
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
        inWorld((world) {
          var changed = false;
          world.sender.views.listen((view) {
            final status = view.strategies[strategyId];
            if (!changed && status != null && claiming(status)) {
              changed = true;
              change(world);
            }
          });
          world.commitMove(1);
          world.settle();
          expect(world.written(), contains(isA<ClaimReleased>()));
          restore(world);
          world.settle();
          expect(world.server.calls, hasLength(1));
          expect(world.server.wrongAccount, isEmpty);
          expect(world.queueLength(), 0);
        });
      }
    });

    test(
        'a session write the disk refused is tried again with its restart '
        'still in it', () {
      final storage = MemoryStorage();
      inWorld((world) {
        world.commitMove(1);
        world.sender.hold('x');
        world.settle();
      }, storage: storage);
      inWorld(
        (world) {
          world.lease.refuseNext = 1;
          world.sender.nudge();
          world.settle(const Duration(seconds: 10));
          expect(world.written().whereType<AppRestarted>(), hasLength(1));
          expect(world.server.calls, hasLength(1));
          expect(world.queueLength(), 0);
        },
        storage: storage,
        shadow: false,
        addStrategy: false,
      );
    });
  });

  group('through the real provider', () {
    test(
        'disposing the container during a call ends quietly: the answer is '
        'not written, nothing throws, and the attempt is left for the next '
        'run', () {
      inWorld((world) {
        world.sender.hold('this world\'s own sender stays out of it');
        world.settle();
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
        expect(world.async.pendingTimers, isEmpty);
      });
    });
  });

  group('the server\'s answers as the queue reads them', () {
    test('applied, changed nothing, rejected and failed', () {
      expect(
        storeAnswerOf(const app.AppliedOpAck(opId: 'a', revision: 4)),
        isA<AppliedAnswer>().having((answer) => answer.revision, 'rev', 4),
      );
      expect(
        storeAnswerOf(
          const app.NoopOpAck(opId: 'a', currentRevision: 4, wasApplied: true),
        ),
        isA<NoopAnswer>().having(
          (answer) => answer.replay,
          'replay',
          NoopReplay.appliedWhenFirstReceived,
        ),
      );
      expect(
        storeAnswerOf(const app.NoopOpAck(opId: 'a')),
        isA<NoopWithoutRevision>(),
      );
      expect(
        storeAnswerOf(
          const app.FailedOpAck(
            opId: 'a',
            code: 'PAGE_DELETED',
            rawCode: 'PAGE_DELETED',
            message: 'gone',
          ),
        ),
        isA<FailedAnswer>().having(
          (answer) => answer.code,
          'code',
          const KnownFailure(FailureCode.pageDeleted),
        ),
      );
    });

    test('each refusal code has one meaning to the queue', () {
      StoreBatchOutcome of(String code) => storeBatchOutcomeOfError(
            ConvexFunctionException(
              code: ConvexErrorCode.fromWireName(code),
              rawCode: code,
              message: 'refused',
            ),
          );
      Matcher refused(BatchRefusal refusal) =>
          isA<StoreBatchRefusedWhole>().having((o) => o.refusal, 'r', refusal);
      expect(of('UNAUTHENTICATED'), refused(BatchRefusal.unauthenticated));
      expect(
        of('CLIENT_UPGRADE_REQUIRED'),
        refused(BatchRefusal.upgradeRequired),
      );
      expect(of('FORBIDDEN'), refused(BatchRefusal.editAccessRemoved));
      expect(of('NOT_FOUND'), refused(BatchRefusal.strategyDeleted));
      expect(of('ACCOUNT_MISMATCH'), isA<StoreBatchAccountMismatch>());
      expect(of('RATE_LIMITED'), isA<StoreBatchLost>());
      expect(
        storeBatchOutcomeOfError(TimeoutException('slow')),
        isA<StoreBatchLost>().having(
          (o) => o.failure,
          'failure',
          TransportFailure.timeout,
        ),
      );
    });
  });
}
