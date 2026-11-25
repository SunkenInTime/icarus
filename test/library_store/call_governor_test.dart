import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/stall_exits.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show servedAccount, strategyId;
import 'sender_world.dart';

const pageId = 'p1';

List<Duration> readTimes(World world, String? page, {Duration? after}) => [
      for (final call in world.server.readCalls)
        if (call.page == page &&
            (after == null || call.at!.difference(start) > after))
          call.at!.difference(start),
    ];

List<Duration> sendTimes(World world) => [
      for (final call in world.server.calls)
        if (call.at case final at?) at.difference(start),
    ];

Future<StoreBatchOutcome> rowReplaced(ServerCall call) => Future.value(
      StoreBatchAnswered(
        [
          for (final op in call.opIds)
            RejectedAnswer(
                op, RejectionReason.rowReplaced, const NoServerCopy()),
        ],
        complete: true,
      ),
    );

StoreReadAnswered laterLifePage(World world, String page) {
  final held = world.server.rows[strategyId]!.page(page)! as LivePage;
  return StoreReadAnswered(
    PageRead(
      page: bornIn(held, lifeOfRow(held.key) + 1000) as PageRow,
      elements: const [],
      lineupGroups: const [],
    ),
  );
}

void record(World world, List<QueueEvent> events) {
  Saving<Recorded, CommitRefusal>? recorded;
  world.store
      .record(servedAccount, strategyId, events)
      .then((value) => recorded = value);
  world.async.flushMicrotasks();
  expect(recorded, isA<Saved<Recorded, CommitRefusal>>());
}

void stallPageTwo(World world) {
  world.pagesOnServer(['p2']);
  world.sender.adopt(strategyId);
  world.settle(const Duration(minutes: 1));
  world.server.overrideRead = (call) =>
      call.page == 'p2' ? const StoreReadAnswered(PageGone('nowhere')) : null;
  world
    ..connection = null
    ..connection = 2;
  world.commitPageDelete('delete-p2', 'p2');
}

void main() {
  test(
      '1: a marker write the disk refuses is kept and written again from '
      'memory: no read is made while the disk refuses, and the marker lands '
      'once the disk takes it', () {
    inWorld((world) {
      world.server.answerNext(strategyId, rowReplaced);
      world.server.overrideRead =
          (call) => call.page == pageId ? laterLifePage(world, pageId) : null;
      world.slowStore.refusesRefusedResult = 1 << 30;
      final from = world.async.elapsed;
      world.commitMove(1);
      world.settle(const Duration(hours: 2));
      final reads = readTimes(world, pageId, after: from);
      expectTheLadder(reads);
      expect(reads, hasLength(timing.unresolvedRounds));
      expect(world.face(), isNot(Face.unreadableWork));
      world.slowStore.refusesRefusedResult = 0;
      final recovered = world.async.elapsed;
      world.settle(const Duration(seconds: 61));
      expect(world.face(), Face.unreadableWork);
      final again = readTimes(world, pageId, after: recovered);
      expect(again.length, greaterThanOrEqualTo(2), reason: '$again');
      expect(
        again[1] - again[0],
        greaterThanOrEqualTo(timing.settleAfter(timing.unresolvedRounds + 1)),
        reason: 'the read that reached the bound was counted: $again',
      );
    });
  });

  group('2: sends go through one gate', () {
    test(
        'a batch refused for edit access while the page list says this '
        'account edits climbs the send ladder and stops at its bound, needing '
        'the user', () {
      inWorld((world) {
        for (var n = 0; n < 40; n++) {
          world.server.answerWith(
            strategyId,
            const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
          );
        }
        world.commitMove(1);
        world.settle(const Duration(seconds: 30));
        final early = sendTimes(world);
        for (var n = 1; n < early.length; n++) {
          expect(
            early[n] - early[n - 1],
            greaterThanOrEqualTo(timing.sendFloor),
            reason: '$early',
          );
        }
        world.settle(const Duration(hours: 1));
        expect(sendTimes(world), hasLength(retriesBeforePause));
        expect(world.face(), Face.needsYou);
        expect(world.sender.waitingOn(strategyId), StallExit.lostSend);
        world.settle(const Duration(hours: 1));
        expect(sendTimes(world), hasLength(retriesBeforePause));
        record(world, const [UserRetried('move-1')]);
        world.settle(const Duration(minutes: 1));
        expect(sendTimes(world).length, greaterThan(retriesBeforePause));
      });
    });

    test(
        '#779: a server that refuses every batch as outside its window gets '
        'the batch on the send ladder, at most the bound, then the user is '
        'asked', () {
      inWorld((world) {
        for (var n = 0; n < 200; n++) {
          world.server.answerNext(
            strategyId,
            (call) => Future.value(const StoreBatchOutsideWindow('refused')),
          );
        }
        world.commitMove(1);
        world.settle(const Duration(hours: 1));
        expect(sendTimes(world), hasLength(retriesBeforePause));
        expect(world.face(), Face.needsYou);
      });
    });
  });

  test(
      '3: an upgrade asked for on a confirmation read holds every send and '
      'shows upgradeRequired', () {
    inWorld((world) {
      world.commitMove(1);
      world.settle(const Duration(seconds: 5));
      expect(world.face(), isNull);
      world.server.overrideRead = (call) => const StoreReadRefused(
            StoreReadRefusal.upgradeRequired,
            'upgrade',
          );
      world.settle(const Duration(minutes: 1));
      expect(world.face(), Face.upgradeRequired);
      final sends = world.server.calls.length;
      world.commitMove(2);
      world.settle(const Duration(hours: 1));
      expect(world.server.calls, hasLength(sends));
      expect(world.face(), Face.upgradeRequired);
      expect(world.sender.waitingOn(strategyId), StallExit.upgrade);
    });
  });

  group('4: open in the editor is read from state', () {
    test('an open that is still under way counts, before any snapshot exists',
        () {
      final container = ProviderContainer(
        overrides: [senderEditorShowsProvider.overrideWith((ref) => null)],
      );
      addTearDown(container.dispose);
      final open = container.read(senderEditorProvider);
      expect(container.read(open), isNull);
      final attempt = container
          .read(strategyOpeningProvider.notifier)
          .begin(strategyId, source: StrategySource.cloud);
      expect(container.read(open), strategyId);
      container.read(strategyOpeningProvider.notifier).settle(attempt);
      expect(container.read(open), isNull);
      container
          .read(strategyOpeningProvider.notifier)
          .begin(strategyId, source: StrategySource.local);
      expect(container.read(open), isNull);
    });

    test(
        'the access check follows what the editor shows now: it keeps going '
        'while shown, past its bound, and stops the moment nothing shows it, '
        'with no call to clear it', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
        );
        world.server.overrideRead = (call) =>
            const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden');
        world.editorShows = strategyId;
        world.commitMove(1);
        world.settle(const Duration(hours: 2));
        expect(world.sender.accessCheckStopped(strategyId), isFalse);
        final shown = readTimes(world, null).length;
        expect(shown, greaterThan(timing.accessReads));
        world.editorShows = null;
        expect(world.sender.accessCheckStopped(strategyId), isTrue);
        world.settle(const Duration(hours: 1));
        expect(readTimes(world, null), hasLength(shown));
      });
    });

    test('ten reopens at one instant after the check stopped make one call',
        () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved),
        );
        world.server.overrideRead = (call) =>
            const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden');
        world.commitMove(1);
        world.settle(const Duration(hours: 2));
        expect(world.sender.accessCheckStopped(strategyId), isTrue);
        final stopped = readTimes(world, null).length;
        for (var n = 0; n < 10; n++) {
          world.openInEditor(strategyId);
          world.async.flushMicrotasks();
          world.openInEditor(null);
          world.async.flushMicrotasks();
        }
        world.settle(const Duration(seconds: 1));
        expect(readTimes(world, null).length - stopped, lessThanOrEqualTo(1));
      });
    });
  });

  test(
      '6: a take-up list kept through a write failure and written late is '
      'read once more, so a page added meanwhile is not missed', () {
    inWorld(
      (world) {
        var added = false;
        world.server.overrideRead = (call) {
          if (call.page != null || added) return null;
          added = true;
          final before = world.server.answerNow(call);
          world.pagesOnServer(['p2']);
          return before;
        };
        world.lease.refuseNext = 3;
        world.sender.adopt(strategyId);
        world.settle(const Duration(minutes: 1));
        expect(readTimes(world, null), hasLength(2));
        expect(world.cloud().queue.shown.pages.keys, contains('p2'));
        expect(readTimes(world, 'p2'), hasLength(1));
        expect(world.face(), isNull);
      },
      addStrategy: false,
    );
  });

  test(
      '7: an edit the server rejects ends the wait for its own page only, not '
      'for a stalled page elsewhere', () {
    inWorld(
      (world) {
        stallPageTwo(world);
        world.settle(const Duration(seconds: 40));
        final stalled = readTimes(world, 'p2').length;
        world.server.answerNext(strategyId, rowReplaced);
        world.commitMove(1);
        world.settle(const Duration(seconds: 15));
        expect(world.server.log, contains('send move-1'));
        expect(readTimes(world, 'p2'), hasLength(stalled));
      },
      addStrategy: false,
    );
  });

  test('8: a strategy deleted on the server is not read again', () {
    inWorld((world) {
      world.server.answerNext(strategyId, rowReplaced);
      world.server.overrideRead = (call) => call.page == pageId
          ? const StoreReadLost(TransportFailure.network, 'lost')
          : null;
      world.commitMove(1);
      world.settle(const Duration(seconds: 10));
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.strategyDeleted),
      );
      world.commitRename(strategyId, 'rename-1');
      world.settle(const Duration(seconds: 10));
      expect(world.face(), Face.deletedOnServer);
      final gone = world.server.readCalls.length;
      world.settle(const Duration(hours: 1));
      expect(world.server.readCalls, hasLength(gone));
    });
  });

  group('a write after a server answer goes through one keep-and-retry path',
      () {
    test(
        '1b: a page the store will not keep marks it unreadable from memory: '
        'with the marker write refused, the page is not read again, and the '
        'marker lands once the disk takes it', () {
      inWorld((world) {
        world.server.answerNext(strategyId, rowReplaced);
        world.slowStore
          ..rejectsBasesOutOfPlace = 1 << 30
          ..refusesRefusedResult = 1 << 30;
        final from = world.async.elapsed;
        world.commitMove(1);
        world.settle(const Duration(hours: 2));
        expect(
          readTimes(world, pageId, after: from).length,
          lessThanOrEqualTo(timing.unresolvedRounds),
        );
        world.slowStore.refusesRefusedResult = 0;
        world.settle(const Duration(seconds: 61));
        expect(world.face(), Face.unreadableWork);
      });
    });

    test(
        '2b: an upgrade status the disk refuses is written again while sends '
        'are held, and then shown', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle(const Duration(seconds: 5));
        world.slowStore.refusesUpgradeWrites = 3;
        world.server.overrideRead = (call) => const StoreReadRefused(
              StoreReadRefusal.upgradeRequired,
              'upgrade',
            );
        world.settle(const Duration(minutes: 1));
        final sends = world.server.calls.length;
        world.commitMove(2);
        world.settle(const Duration(minutes: 5));
        expect(world.face(), Face.upgradeRequired);
        expect(world.server.calls, hasLength(sends));
      });
    });
  });

  test(
      '3c: a strategy is looked at whenever the planner would read it: a '
      'fresh read owed in memory, with nothing in the saved status, is made',
      () {
    inWorld((world) {
      world.settle(const Duration(minutes: 5));
      final before = readTimes(world, null).length;
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 10));
      expect(readTimes(world, null), hasLength(before + 1));
    });
  });

  test(
      '4: a batch refused again and again is spaced on the lost-send ladder: '
      'the eight sends are 0.6, 1.2, 2.4, 4.8, 9.6, 19.2 and 19.2 s apart', () {
    inWorld((world) {
      for (var n = 0; n < 40; n++) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(const StoreBatchOutsideWindow('refused')),
        );
      }
      world.commitMove(1);
      world.settle(const Duration(minutes: 5));
      final times = sendTimes(world);
      expect(times, hasLength(retriesBeforePause));
      final gaps = [
        for (var n = 1; n < times.length; n++) times[n] - times[n - 1],
      ];
      printOnFailure('sends at $times, gaps $gaps');
      for (var n = 1; n < times.length; n++) {
        final rung = Duration(milliseconds: 300 * (1 << n.clamp(0, 6)));
        expect(
          gaps[n - 1],
          allOf(
            greaterThan(rung - storedPrecision),
            lessThan(rung + const Duration(milliseconds: 500)),
          ),
          reason: 'send ${n + 1}: $gaps',
        );
      }
    });
  });

  test(
      '4b: refusals after a lost send count on the same ladder, with their '
      'own times', () {
    inWorld((world) {
      world.server.answerNext(
        strategyId,
        (call) => Future.value(
          const StoreBatchLost(TransportFailure.network, 'lost'),
        ),
      );
      for (var n = 0; n < 40; n++) {
        world.server.answerNext(
          strategyId,
          (call) => Future.value(const StoreBatchOutsideWindow('refused')),
        );
      }
      world.commitMove(1);
      world.settle(const Duration(minutes: 5));
      final times = sendTimes(world);
      expect(times, hasLength(retriesBeforePause));
      for (var n = 2; n < times.length; n++) {
        expect(
          times[n] - times[n - 1],
          greaterThanOrEqualTo(
            Duration(milliseconds: 300 * (1 << n.clamp(0, 6))),
          ),
          reason: '$times',
        );
      }
    });
  });
}
