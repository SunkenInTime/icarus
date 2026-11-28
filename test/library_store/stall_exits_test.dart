import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/stall_exits.dart';
import 'package:icarus_library/icarus_library.dart';

import 'server_fixtures.dart' show servedAccount, strategyId;
import 'sender_world.dart';

typedef Call = ({Duration at, String what});

final class Stall {
  const Stall({
    required this.start,
    required this.goAgain,
    required this.wentAgain,
    this.prepare,
    this.adopts = false,
    this.held = true,
    this.look = const Duration(hours: 1),
    this.named = true,
  });

  final void Function(World world)? prepare;
  final bool adopts;
  final bool held;
  final Duration look;
  final bool named;
  final void Function(World world) start;
  final void Function(World world) goAgain;
  final bool Function(World world, List<Call> after) wentAgain;
}

const pageId = 'p1';

StoreBatchAnswered rowReplaced(ServerCall call) => StoreBatchAnswered(
      [
        for (final op in call.opIds)
          RejectedAnswer(op, RejectionReason.rowReplaced, const NoServerCopy()),
      ],
      complete: true,
      point: stampedWhenAnswered,
    );

StoreReadAnswered laterPage(World world, String page) {
  final rows = world.server.rows[strategyId]!;
  final held = rows.page(page)! as LivePage;
  return StoreReadAnswered(
    PageRead(
      page: bornIn(held, lifeOfRow(held.key) + 1000) as PageRow,
      elements: const [],
      lineupGroups: const [],
    ),
    point: stampedWhenAnswered,
  );
}

PageRead newPageOf(World world) {
  final rows = world.server.rows[strategyId]!;
  final page = rows.pages.first as LivePage;
  return PageRead(
    page: bornIn(
      LivePage(
        publicId: 'p-new',
        strategyPublicId: page.strategyPublicId,
        name: 'New',
        isAutoNamed: false,
        sortIndex: page.sortIndex + 1,
        isAttack: page.isAttack,
        revision: 1,
      ),
      rows.strategy.createdAt.millisecondsSinceEpoch + 5000,
    ) as PageRow,
    elements: const [],
    lineupGroups: const [],
  );
}

void answerEverySend(
    World world, StoreBatchOutcome Function(ServerCall) answer) {
  for (var n = 0; n < 40; n++) {
    world.server.answerNext(strategyId, (call) => Future.value(answer(call)));
  }
}

void record(World world, List<QueueEvent> events) {
  Saving<Recorded, CommitRefusal>? recorded;
  world.store
      .record(servedAccount, strategyId, events)
      .then((value) => recorded = value);
  world.async.flushMicrotasks();
  expect(recorded, isA<Saved<Recorded, CommitRefusal>>());
}

bool sent(List<Call> after) =>
    after.any((call) => call.what.startsWith('send'));

bool read(List<Call> after) =>
    after.any((call) => !call.what.startsWith('send'));

final stalls = <StallExit, Stall>{
  StallExit.firstRead: Stall(
    held: false,
    look: const Duration(seconds: 20),
    named: false,
    start: (world) {
      world.pagesOnServer(['p2']);
      for (var n = 0; n < 3; n++) {
        world.server.answerReadNext(strategyId, (call) {
          final answer = world.server.answerNow(call);
          return call.page == null
              ? Future.value(answer)
              : Future.delayed(const Duration(seconds: 30), () => answer);
        });
      }
      world.sender.adopt(strategyId);
    },
    goAgain: (world) {},
    wentAgain: (world, after) => world.face() == null,
  ),
  StallExit.clockOnWatch: Stall(
    adopts: true,
    start: (world) {
      final strategy = world.rowOf((content) => content.strategy);
      world.commit([
        PageReorderOp(
          opId: 'reorder',
          pagePublicId: 'p2',
          sortIndex: 0,
          expectedStrategyRevision:
              (strategy.toJson()! as Map)['revision']! as int,
        ),
      ]);
      world.settle(const Duration(seconds: 5));
      world.server.skew = -const Duration(hours: 3).inMilliseconds;
      world.connection = 2;
      world.sender
        ..liveOpened(strategyId, const ReadOfPage('p2'))
        ..liveArrived(
          strategyId,
          const ReadOfPage('p2'),
          servedAccount,
          world.server.answerNow(ReadCall(strategyId, 'p2', servedAccount)),
        );
      world.settle();
      world.commitPageDelete('delete-p2', 'p2');
    },
    goAgain: (world) {
      world.server.skew = 0;
      world.onReconnect = () {
        world.connection = 3;
        world.sender.liveArrived(
          strategyId,
          const ReadOfPage('p2'),
          servedAccount,
          world.server.answerNow(ReadCall(strategyId, 'p2', servedAccount)),
        );
      };
      world.sender.retryNow(strategyId);
    },
    wentAgain: (world, after) =>
        after.any((call) => call.what == 'send delete-p2'),
  ),
  StallExit.liveNoFirstResult: Stall(
    held: false,
    look: const Duration(seconds: 5),
    start: (world) {
      world.pagesOnServer(['p2']);
      world.sender.liveOpened(strategyId, const ReadOfPage('p2'));
      world.sender.adopt(strategyId);
    },
    goAgain: (world) {},
    wentAgain: (world, after) => world.face() == null,
  ),
  StallExit.unsettledResult: Stall(
    adopts: true,
    start: (world) {
      world.server.overrideRead = (call) => call.page == 'p2'
          ? const StoreReadAnswered(PageGone('nowhere'),
              point: stampedWhenAnswered)
          : null;
      world
        ..connection = null
        ..connection = 2;
      world.commitPageDelete('delete-p2', 'p2');
    },
    goAgain: (world) => world
      ..connection = null
      ..connection = 3,
    wentAgain: (world, after) => after.any((call) => call.what == 'page p2'),
  ),
  StallExit.answerAhead: Stall(
    adopts: true,
    start: (world) {
      final strategy = world.rowOf((content) => content.strategy);
      world.commit([
        PageReorderOp(
          opId: 'reorder',
          pagePublicId: 'p2',
          sortIndex: 0,
          expectedStrategyRevision:
              (strategy.toJson()! as Map)['revision']! as int,
        ),
      ]);
      world.settle(const Duration(seconds: 5));
      world.server.skew = -const Duration(hours: 3).inMilliseconds;
      world
        ..connection = null
        ..connection = 2;
      world.commitPageDelete('delete-p2', 'p2');
    },
    goAgain: (world) {
      world.server.skew = 0;
      world
        ..connection = null
        ..connection = 3;
    },
    wentAgain: (world, after) =>
        after.any((call) => call.what == 'send delete-p2'),
  ),
  StallExit.refusedResult: Stall(
    prepare: (world) {
      final truth = world.server.rows[strategyId]!;
      world.replaceStrategyOnServer(later: const Duration(days: 365));
      world.aheadOfTheServer();
      world.server.rows[strategyId] = truth;
    },
    start: (world) => world.recordRead([newPageOf(world)]),
    goAgain: (world) {
      world.replaceStrategyOnServer(later: const Duration(days: 400));
      world.sender.retryNow(strategyId);
    },
    wentAgain: (world, after) => world.face() != Face.unreadableWork,
  ),
  StallExit.pageAheadOfList: Stall(
    start: (world) {
      world.server.answerNext(
        strategyId,
        (call) => Future.value(rowReplaced(call)),
      );
      world.server.overrideRead =
          (call) => call.page == pageId ? laterPage(world, pageId) : null;
      world.commitMove(1);
    },
    goAgain: (world) {
      world.server.overrideRead = null;
      world.connection = 2;
    },
    wentAgain: (world, after) => world.face() != Face.unreadableWork,
  ),
  StallExit.lostRead: Stall(
    adopts: true,
    start: (world) {
      world.server.overrideRead = (call) => call.page == 'p2'
          ? const StoreReadLost(TransportFailure.network, 'the read was lost')
          : null;
      world
        ..connection = null
        ..connection = 2;
      world.commitPageDelete('delete-p2', 'p2');
    },
    goAgain: (world) {
      world.server.overrideRead = null;
      world
        ..connection = null
        ..connection = 3;
    },
    wentAgain: (world, after) => after.any((call) => call.what == 'page p2'),
  ),
  StallExit.unreadableRead: Stall(
    adopts: true,
    start: (world) {
      world.server.overrideRead = (call) => call.page == 'p2'
          ? const StoreReadUnreadable('rows this build cannot read',
              point: stampedWhenAnswered)
          : null;
      world
        ..connection = null
        ..connection = 2;
      world.commitPageDelete('delete-p2', 'p2');
    },
    goAgain: (world) {
      world.server.overrideRead = null;
      world
        ..connection = null
        ..connection = 3;
    },
    wentAgain: (world, after) => after.any((call) => call.what == 'page p2'),
  ),
  StallExit.viewerOnly: Stall(
    start: (world) {
      world.server.roles[strategyId] = StoreReadRole.viewer;
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
            point: stampedWhenAnswered),
      );
      world.commitMove(1);
    },
    goAgain: (world) => world
      ..signIn(null)
      ..signIn(servedAccount),
    wentAgain: (world, after) => read(after),
  ),
  StallExit.forbidden: Stall(
    start: (world) {
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
            point: stampedWhenAnswered),
      );
      world.server.overrideRead = (call) => const StoreReadRefused(
          StoreReadRefusal.forbidden, 'forbidden',
          point: stampedWhenAnswered);
      world.commitMove(1);
    },
    goAgain: (world) => world
      ..signIn(null)
      ..signIn(servedAccount),
    wentAgain: (world, after) => read(after),
  ),
  StallExit.signIn: Stall(
    start: (world) {
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.unauthenticated,
            point: stampedWhenAnswered),
      );
      world.commitMove(1);
    },
    goAgain: (world) => world.signIn(servedAccount),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.upgrade: Stall(
    start: (world) {
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.upgradeRequired,
            point: stampedWhenAnswered),
      );
      world.commitMove(1);
    },
    goAgain: (world) {},
    wentAgain: (world, after) => after.isEmpty,
  ),
  StallExit.lookupGivenUp: Stall(
    named: false,
    start: (world) {
      world.server.lookup =
          () => Completer<({int client, int connection})>().future;
      world.commitMove(1);
    },
    goAgain: (world) {
      world.server.lookup = null;
      record(world, const [UserRetried('move-1')]);
    },
    wentAgain: (world, after) => sent(after) && world.queueLength() == 0,
  ),
  StallExit.offline: Stall(
    start: (world) {
      world.connection = null;
      world.commitMove(1);
    },
    goAgain: (world) => world.connection = 1,
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.signedOut: Stall(
    start: (world) {
      world.signIn(null);
      world.commitMove(1);
    },
    goAgain: (world) => world.signIn(servedAccount),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.heldByHand: Stall(
    start: (world) {
      world.sender.hold('a check');
      world.commitMove(1);
    },
    goAgain: (world) => world.sender.release(),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.lostSend: Stall(
    start: (world) {
      answerEverySend(
        world,
        (call) => const StoreBatchLost(TransportFailure.network, 'lost'),
      );
      world.commitMove(1);
    },
    goAgain: (world) {
      world.server.answerNormally();
      record(world, const [UserRetried('move-1')]);
    },
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.replaced: Stall(
    start: (world) {
      world.server.answerNext(strategyId, (call) {
        world.replaceStrategyOnServer();
        return Future.value(
          const StoreBatchRefusedWhole(BatchRefusal.strategyReplaced,
              point: stampedWhenAnswered),
        );
      });
      world.commitMove(1);
    },
    goAgain: (world) => record(world, const [UserDiscardedReplaced()]),
    wentAgain: (world, after) => world.face() == null,
  ),
  StallExit.deletedOnServer: Stall(
    start: (world) {
      world.server.answerWith(
        strategyId,
        const StoreBatchRefusedWhole(BatchRefusal.strategyDeleted,
            point: stampedWhenAnswered),
      );
      world.commitMove(1);
    },
    goAgain: (world) => record(world, const [UserDiscarded('move-1')]),
    wentAgain: (world, after) => world.queueLength() == 0,
  ),
  StallExit.refusedEdit: Stall(
    start: (world) {
      world.server.answerNext(
        strategyId,
        (call) => Future.value(
          StoreBatchAnswered(
            [
              for (final op in call.opIds)
                RejectedAnswer(
                  op,
                  RejectionReason.mergeInvalid,
                  const NoServerCopy(),
                ),
            ],
            complete: true,
            point: stampedWhenAnswered,
          ),
        ),
      );
      world.commitMove(1);
    },
    goAgain: (world) => record(world, const [UserDiscarded('move-1')]),
    wentAgain: (world, after) => world.queueLength() == 0,
  ),
  StallExit.pageInTrash: Stall(
    prepare: (world) {
      world.pagesOnServer(['p2']);
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(minutes: 1));
    },
    start: (world) {
      world.connection = null;
      world.commitMove(1);
      final rows = world.server.rows[strategyId]!;
      world.server.teammate(
        strategyId,
        PageDeleteOp(
          opId: 'teammate-deletes-p1',
          pagePublicId: 'p1',
          expectedStrategyRevision: rows.strategy.revision,
        ),
      );
      world.connection = 1;
    },
    goAgain: (world) {
      final rows = world.server.rows[strategyId]!;
      final trashed = rows.page('p1')! as TrashedPage;
      world.server.rows[strategyId] = rows.withRows([
        LivePage(
          publicId: trashed.publicId,
          strategyPublicId: trashed.strategyPublicId,
          name: trashed.name,
          sortIndex: trashed.sortIndex,
          isAttack: trashed.isAttack,
          isAutoNamed: trashed.isAutoNamed,
          revision: trashed.revision,
          unknownFields: trashed.unknownFields,
        ),
        rows.strategy.rewritten(revision: rows.strategy.revision + 1),
      ]);
      world.sender.owesFreshRead(strategyId, const ReadOfList());
    },
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.landedWork: Stall(
    look: const Duration(seconds: 10),
    start: (world) => world.commitMove(1),
    goAgain: (world) => world.commitMove(2),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.viewerOnTakeUp: Stall(
    held: false,
    start: (world) {
      world.server.roles[strategyId] = StoreReadRole.viewer;
      world.sender.adopt(strategyId);
    },
    goAgain: (world) {
      world.server.roles[strategyId] = StoreReadRole.owner;
      world.sender.adopt(strategyId);
    },
    wentAgain: (world, after) => read(after) && world.holds(strategyId),
  ),
  StallExit.goneOnTakeUp: Stall(
    held: false,
    start: (world) {
      world.server.overrideRead = (call) => call.page == null
          ? const StoreReadAnswered(StrategyGone(), point: stampedWhenAnswered)
          : null;
      world.sender.adopt(strategyId);
    },
    goAgain: (world) {
      world.server.overrideRead = null;
      world.sender.adopt(strategyId);
    },
    wentAgain: (world, after) => read(after) && world.holds(strategyId),
  ),
  StallExit.uncheckedTooLate: Stall(
    named: false,
    start: (world) {
      world.server.answerNext(
        strategyId,
        (call) => Future.value(const StoreBatchOutsideWindow('refused',
            point: stampedWhenAnswered)),
      );
      world.commitMove(1);
    },
    goAgain: (world) => world.commitMove(2),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.localTrouble: Stall(
    start: (world) {
      world.server.answerNext(
        strategyId,
        (call) => Future.value(rowReplaced(call)),
      );
      world.slowStore.refusesBaseWrites = 1000;
      world.commitMove(1);
    },
    goAgain: (world) => world.slowStore.refusesBaseWrites = 0,
    wentAgain: (world, after) =>
        after.length == 1 &&
        after.single.what == 'page p1' &&
        world.sender.waitingOn(strategyId) != StallExit.localTrouble &&
        world.readsRecorded().where((read) => read == 'page p1').length == 3,
  ),
  StallExit.sendSpacing: Stall(
    look: const Duration(milliseconds: 300),
    start: (world) {
      for (var n = 1; n <= 3; n++) {
        world.commitMove(n);
        world.async.elapse(const Duration(milliseconds: 20));
      }
    },
    goAgain: (world) => world.commitMove(4),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.editsSettling: Stall(
    look: const Duration(milliseconds: 100),
    start: (world) => world.commitMove(1),
    goAgain: (world) => world.commitMove(2),
    wentAgain: (world, after) => sent(after),
  ),
  StallExit.notBeingRead: Stall(
    start: (world) => world.teammateMoves(1),
    goAgain: (world) => world.commitMove(2),
    wentAgain: (world, after) => sent(after),
  ),
};

const logs = <StallExit, List<String>>{
  StallExit.firstRead: [
    '0 s list',
    '0 s page p1',
    '30 s page p2',
  ],
  StallExit.clockOnWatch: [
    '0 s send reorder',
    '7 s list',
  ],
  StallExit.liveNoFirstResult: [
    '0 s list',
    '0 s page p1',
    '10 s page p2',
  ],
  StallExit.unsettledResult: [
    '0 s list',
    '0 s page p2',
    '2 s page p2',
    '6 s page p2',
    '14 s page p2',
    '30 s page p2',
    '62 s page p2',
    '126 s page p2',
    '254 s page p2',
    '510 s page p2',
    '1022 s page p2',
    '1622 s page p2',
    '2222 s page p2',
    '2822 s page p2',
    '3422 s page p2',
    '4022 s page p2',
    '4622 s page p2',
    '5222 s page p2',
    '5822 s page p2',
    '6422 s page p2',
    '7022 s page p2',
  ],
  StallExit.answerAhead: [
    '0 s send reorder',
    '5 s list',
    '5 s page p2',
    '7 s page p2',
    '11 s page p2',
    '19 s page p2',
    '35 s page p2',
    '67 s page p2',
    '131 s page p2',
    '259 s page p2',
    '515 s page p2',
    '1027 s page p2',
    '1627 s page p2',
    '2227 s page p2',
    '2827 s page p2',
    '3427 s page p2',
    '4027 s page p2',
    '4627 s page p2',
    '5227 s page p2',
    '5827 s page p2',
    '6427 s page p2',
    '7027 s page p2',
  ],
  StallExit.refusedResult: [
    '0 s list',
    '2 s list',
    '6 s list',
    '14 s list',
    '30 s list',
    '62 s list',
    '126 s list',
    '254 s list',
    '510 s list',
    '1022 s list',
    '1622 s list',
    '2222 s list',
    '2822 s list',
    '3422 s list',
    '4022 s list',
    '4622 s list',
    '5222 s list',
    '5822 s list',
    '6422 s list',
    '7022 s list',
  ],
  StallExit.pageAheadOfList: [
    '0 s send move-1',
    '0 s page p1',
    '0 s list',
    '2 s page p1',
    '2 s list',
    '6 s page p1',
    '6 s list',
    '14 s page p1',
    '14 s list',
    '30 s page p1',
    '30 s list',
    '62 s page p1',
    '62 s list',
    '126 s page p1',
    '126 s list',
    '254 s page p1',
    '254 s list',
    '510 s page p1',
    '510 s list',
    '1022 s page p1',
    '1022 s list',
    '1622 s page p1',
    '1622 s list',
    '2222 s page p1',
    '2222 s list',
    '2822 s page p1',
    '2822 s list',
    '3422 s page p1',
    '3422 s list',
    '4022 s page p1',
    '4022 s list',
    '4622 s page p1',
    '4622 s list',
    '5222 s page p1',
    '5222 s list',
    '5822 s page p1',
    '5822 s list',
    '6422 s page p1',
    '6422 s list',
    '7022 s page p1',
    '7022 s list',
  ],
  StallExit.lostRead: [
    '0 s list',
    '0 s page p2',
    '2 s page p2',
    '6 s page p2',
    '14 s page p2',
    '30 s page p2',
    '62 s page p2',
    '126 s page p2',
    '254 s page p2',
    '510 s page p2',
    '1022 s page p2',
    '1622 s page p2',
    '2222 s page p2',
    '2822 s page p2',
    '3422 s page p2',
    '4022 s page p2',
    '4622 s page p2',
    '5222 s page p2',
    '5822 s page p2',
    '6422 s page p2',
    '7022 s page p2',
  ],
  StallExit.unreadableRead: [
    '0 s list',
    '0 s page p2',
    '2 s page p2',
    '6 s page p2',
    '14 s page p2',
    '30 s page p2',
    '62 s page p2',
    '126 s page p2',
    '254 s page p2',
    '510 s page p2',
    '1022 s page p2',
    '1622 s page p2',
    '2222 s page p2',
    '2822 s page p2',
    '3422 s page p2',
    '4022 s page p2',
    '4622 s page p2',
    '5222 s page p2',
    '5822 s page p2',
    '6422 s page p2',
    '7022 s page p2',
  ],
  StallExit.landedWork: [
    '0 s send move-1',
    '30 s page p1',
  ],
  StallExit.viewerOnly: [
    '0 s send move-1',
    '0 s list',
    '600 s list',
    '1200 s list',
    '1800 s list',
    '2400 s list',
    '3000 s list',
  ],
  StallExit.forbidden: [
    '0 s send move-1',
    '0 s list',
    '600 s list',
    '1200 s list',
    '1800 s list',
    '2400 s list',
    '3000 s list',
  ],
  StallExit.viewerOnTakeUp: [
    '0 s list',
  ],
  StallExit.goneOnTakeUp: [
    '0 s list',
  ],
  StallExit.signIn: [
    '0 s send move-1',
  ],
  StallExit.upgrade: [
    '0 s send move-1',
  ],
  StallExit.lookupGivenUp: [
    '0 s send move-1',
    '10 s send move-1',
    '21 s send move-1',
    '34 s send move-1',
    '49 s send move-1',
    '68 s send move-1',
    '97 s send move-1',
    '127 s send move-1',
  ],
  StallExit.offline: [],
  StallExit.signedOut: [],
  StallExit.heldByHand: [],
  StallExit.lostSend: [
    '0 s send move-1',
    '0 s send move-1',
    '1 s send move-1',
    '4 s send move-1',
    '9 s send move-1',
    '18 s send move-1',
    '37 s send move-1',
    '57 s send move-1',
  ],
  StallExit.uncheckedTooLate: [
    '0 s send move-1',
    '0 s send move-1',
    '30 s page p1',
  ],
  StallExit.replaced: [
    '0 s send move-1',
    '0 s list',
    '0 s page p1',
  ],
  StallExit.deletedOnServer: [
    '0 s send move-1',
  ],
  StallExit.refusedEdit: [
    '0 s send move-1',
  ],
  StallExit.localTrouble: [
    '0 s send move-1',
    '0 s page p1',
  ],
  StallExit.sendSpacing: [
    '0 s send move-1',
    '0 s send move-2',
    '0 s send move-3',
    '30 s page p1',
  ],
  StallExit.editsSettling: [
    '0 s send move-1',
    '30 s page p1',
  ],
  StallExit.notBeingRead: [],
  StallExit.pageInTrash: ['0 s send move-1', '0 s list'],
};

final measured = <StallExit, ({int firstHour, int laterHour})>{};

String tableOf(SenderTiming timing) => [
      '| Stall | Waits for | Calls | How often | Bound | On screen | '
          'Calls, first hour | Calls an hour after | Goes again on |',
      '|---|---|---|---|---|---|---|---|---|',
      for (final row in StallExit.values)
        '| ${row.title} | ${row.waitsFor} | ${row.calls} | '
            '${row.schedule(timing)} | ${row.bound(timing)} | '
            '${row.shown} | '
            '${measured[row]?.firstHour ?? 'not run here'} | '
            '${measured[row]?.laterHour ?? 'not run here'} | '
            '${row.goesAgain} |',
    ].join('\n');

const readme = 'packages/icarus_library/README.md';
const opening = '<!-- stall exits: generated by '
    'test/library_store/stall_exits_test.dart -->';
const closing = '<!-- end of stall exits -->';

void main() {
  for (final row in StallExit.values) {
    test('${row.name}: ${row.title}', () {
      final stall = stalls[row]!;
      inWorld(
        (world) {
          if (stall.adopts) {
            world.pagesOnServer(['p2']);
            world.sender.adopt(strategyId);
            world.settle(const Duration(minutes: 1));
          }
          stall.prepare?.call(world);
          final calls = <Call>[];
          final reads = world.server.onRead;
          final sends = world.server.onCall;
          world.server.onRead = (call) {
            reads?.call(call);
            calls.add((at: world.async.elapsed, what: '$call'));
          };
          world.server.onCall = (call) {
            sends?.call(call);
            calls.add((
              at: world.async.elapsed,
              what: 'send ${call.opIds.join(',')}'
                  '${call.basis == null ? '' : ' on a live basis'}',
            ));
          };
          final begun = world.async.elapsed;
          stall.start(world);
          world.settle(stall.look);
          if (row.shownAs?.startsWith('nothing: not in the library') ?? false) {
            expect(world.holds(strategyId), isFalse, reason: row.name);
          } else {
            expect(world.face(), row.onScreen, reason: row.name);
          }
          if (stall.named) {
            expect(world.sender.waitingOn(strategyId), row, reason: row.name);
          }
          world.settle(const Duration(hours: 1) - stall.look);
          final firstHour = calls.length;
          world.settle(const Duration(hours: 1));
          final laterHour = calls.length - firstHour;
          final ticks = [for (final call in calls) (call.at, call.what)];
          expect(ticks.toSet().length, ticks.length, reason: '$calls');
          measured[row] = (firstHour: firstHour, laterHour: laterHour);
          final log = [
            for (final call in calls)
              '${(call.at - begun).inSeconds} s ${call.what}',
          ];
          expect(log, logs[row], reason: row.name);
          final before = calls.length;
          stall.goAgain(world);
          world.settle(const Duration(minutes: 2));
          expect(
            stall.wentAgain(world, calls.sublist(before)),
            isTrue,
            reason: '${row.name}: ${calls.sublist(before)}',
          );
        },
        addStrategy: stall.held && !stall.adopts,
      );
    });
  }

  test(
      'an edit refused as its page deleted costs one send and one page list, '
      'and nothing more across a reconnect and a restart', () {
    final storage = MemoryStorage();
    final server = FakeServer();
    final calls = <String>[];
    void watch(World world) {
      world.server.onRead = (call) => calls.add('$call');
      world.server.onCall = (call) => calls.add('send ${call.opIds.join(',')}');
    }

    inWorld(
      (world) {
        final stall = stalls[StallExit.pageInTrash]!;
        stall.prepare!(world);
        watch(world);
        stall.start(world);
        world.settle(const Duration(minutes: 10));
        expect(calls, ['send move-1', 'list']);
        expect(world.sender.waitingOn(strategyId), StallExit.pageInTrash);
        world.connection = null;
        world.settle(const Duration(minutes: 1));
        world.connection = 2;
        world.settle(const Duration(hours: 1));
        expect(calls, ['send move-1', 'list']);
      },
      storage: storage,
      server: server,
    );
    inWorld(
      (world) {
        watch(world);
        world.settle(const Duration(hours: 1));
        expect(calls, ['send move-1', 'list', 'list']);
        expect(world.sender.waitingOn(strategyId), StallExit.pageInTrash);
      },
      storage: storage,
      server: server,
      addStrategy: false,
    );
  });

  test(
      'a page restored while the app was closed is noticed by the one page '
      'list the next run reads, and the edit is sent again', () {
    final storage = MemoryStorage();
    final server = FakeServer();
    final calls = <String>[];
    void watch(World world) {
      world.server.onRead = (call) => calls.add('$call');
      world.server.onCall = (call) => calls.add('send ${call.opIds.join(',')}');
    }

    inWorld(
      (world) {
        final stall = stalls[StallExit.pageInTrash]!;
        stall.prepare!(world);
        watch(world);
        stall.start(world);
        world.settle(const Duration(minutes: 10));
        expect(world.sender.waitingOn(strategyId), StallExit.pageInTrash);
        final rows = world.server.rows[strategyId]!;
        final trashed = rows.page('p1')! as TrashedPage;
        world.server.rows[strategyId] = rows.withRows([
          LivePage(
            publicId: trashed.publicId,
            strategyPublicId: trashed.strategyPublicId,
            name: trashed.name,
            sortIndex: trashed.sortIndex,
            isAttack: trashed.isAttack,
            isAutoNamed: trashed.isAutoNamed,
            revision: trashed.revision,
            unknownFields: trashed.unknownFields,
          ),
          rows.strategy.rewritten(revision: rows.strategy.revision + 1),
        ]);
      },
      storage: storage,
      server: server,
    );
    inWorld(
      (world) {
        watch(world);
        world.settle(const Duration(minutes: 10));
        expect(calls, [
          'send move-1',
          'list',
          'list',
          'send move-1~again',
          'page p1',
        ]);
        expect(world.queueLength(), 0);
      },
      storage: storage,
      server: server,
      addStrategy: false,
    );
  });

  group('what ends a stalled wait before its time', () {
    List<Duration> listReads(World world) => [
          for (final call in world.server.readCalls)
            if (call.page == null) call.at!.difference(start),
        ];

    test(
        'the user pressing retry: a record stalled on lists of an earlier life '
        'reads the list at once and follows the replacement', () {
      inWorld((world) {
        final truth = world.server.rows[strategyId]!;
        world.replaceStrategyOnServer(later: const Duration(days: 365));
        world.aheadOfTheServer();
        world.server.rows[strategyId] = truth;
        final page = truth.pages.first as LivePage;
        world.recordRead([
          PageRead(
            page: bornIn(
              LivePage(
                publicId: 'p-new',
                strategyPublicId: page.strategyPublicId,
                name: 'New',
                isAutoNamed: false,
                sortIndex: page.sortIndex + 1,
                isAttack: page.isAttack,
                revision: 1,
              ),
              truth.strategy.createdAt.millisecondsSinceEpoch + 5000,
            ) as PageRow,
            elements: const [],
            lineupGroups: const [],
          ),
        ]);
        world.settle(const Duration(seconds: 40));
        final stalled = listReads(world).length;
        expect(stalled, greaterThanOrEqualTo(3));
        world.replaceStrategyOnServer(later: const Duration(days: 400));
        world.commitMove(1);
        world.settle(const Duration(seconds: 15));
        expect(listReads(world), hasLength(stalled));
        world.sender.retryNow(strategyId);
        world.settle();
        expect(listReads(world).length, greaterThan(stalled));
        expect(
          world.viewedLife(),
          world.server.rows[strategyId]!.strategy.createdAt
              .millisecondsSinceEpoch,
        );
      });
    });

    test(
        'the user pressing retry: an edit-access check that stopped at its '
        'bound reads the page list again, once', () {
      inWorld((world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
              point: stampedWhenAnswered),
        );
        world.server.overrideRead = (call) => const StoreReadRefused(
            StoreReadRefusal.forbidden, 'forbidden',
            point: stampedWhenAnswered);
        final before = listReads(world).length;
        world.commitMove(1);
        world.settle(const Duration(hours: 1));
        final stopped = listReads(world).length;
        expect(stopped - before, timing.accessReads);
        world.settle(const Duration(hours: 1));
        expect(listReads(world), hasLength(stopped));
        world.sender.retryNow(strategyId);
        world.settle();
        expect(listReads(world), hasLength(stopped + 1));
        world.server.overrideRead = null;
        world.sender.retryNow(strategyId);
        world.settle(const Duration(minutes: 1));
        expect(world.face(), isNot(Face.editAccessLost));
      });
    });

    for (final (kind, answer)
        in <(String, StoreBatchOutcome Function(ServerCall))>[
      ('an edit rejected', rowReplaced),
      (
        'a batch refused whole',
        (call) => const StoreBatchRefusedWhole(BatchRefusal.uncheckedTooLate,
            point: stampedWhenAnswered),
      ),
    ]) {
      test(
          'a new answer from the server ($kind): a need its reads could not '
          'settle is read again right after the send is answered', () {
        inWorld(
          (world) {
            world.pagesOnServer(['p2']);
            world.sender.adopt(strategyId);
            world.settle(const Duration(minutes: 1));
            world.server.overrideRead = (call) => call.page == 'p2'
                ? const StoreReadAnswered(PageGone('nowhere'),
                    point: stampedWhenAnswered)
                : null;
            world
              ..connection = null
              ..connection = 2;
            world.commitPageDelete('delete-p2', 'p2');
            world.settle(const Duration(minutes: 1));
            bool p2(ReadCall call) => call.page == 'p2';
            final stalled = world.server.readCalls.where(p2).length;
            expect(stalled, greaterThanOrEqualTo(3));
            world.server.answerNext(
              strategyId,
              (call) => Future.value(answer(call)),
            );
            world.commitMove(1);
            world.settle(const Duration(seconds: 5));
            expect(world.server.log, contains('send move-1'));
            expect(
              world.server.readCalls.where(p2).length,
              greaterThan(stalled),
            );
          },
          addStrategy: false,
        );
      });
    }

    test(
        'answers that only confirm this device\'s edits do not: a drag of '
        'ten moves, sent and applied, reads nothing stalled', () {
      inWorld(
        (world) {
          world.pagesOnServer(['p2']);
          world.sender.adopt(strategyId);
          world.settle(const Duration(minutes: 1));
          world.server.overrideRead = (call) => call.page == 'p2'
              ? const StoreReadAnswered(PageGone('nowhere'),
                  point: stampedWhenAnswered)
              : null;
          world
            ..connection = null
            ..connection = 2;
          world.commitPageDelete('delete-p2', 'p2');
          world.settle(const Duration(seconds: 40));
          bool p2(ReadCall call) => call.page == 'p2';
          final stalled = world.server.readCalls.where(p2).length;
          final sends = world.server.calls.length;
          for (var n = 1; n <= 10; n++) {
            world.commitMove(n);
            world.settle(const Duration(milliseconds: 400));
          }
          world.settle(const Duration(seconds: 10));
          expect(world.server.calls.length, greaterThan(sends));
          expect(world.server.readCalls.where(p2).length, stalled);
        },
        addStrategy: false,
      );
    });
  });

  test('upgrade: the app starting again sends the waiting edit', () {
    final storage = MemoryStorage();
    final server = FakeServer();
    inWorld(
      (world) {
        world.server.answerWith(
          strategyId,
          const StoreBatchRefusedWhole(BatchRefusal.upgradeRequired,
              point: stampedWhenAnswered),
        );
        world.commitMove(1);
        world.settle(const Duration(minutes: 10));
        expect(world.server.calls, hasLength(1));
        expect(world.face(), Face.upgradeRequired);
      },
      storage: storage,
      server: server,
    );
    inWorld(
      (world) {
        world.settle(const Duration(minutes: 1));
        expect(world.server.calls, hasLength(2));
        expect(world.queueLength(), 0);
      },
      storage: storage,
      server: server,
      addStrategy: false,
      build: 'a-newer-build',
    );
  });

  test('the table in the README is the one the code gives', () {
    final text = File(readme).readAsStringSync().replaceAll('\r\n', '\n');
    final from = text.indexOf(opening);
    final to = text.indexOf(closing);
    expect(from, isNot(-1));
    expect(to, greaterThan(from));
    final generated = '$opening\n\n${tableOf(timing)}\n\n$closing';
    final current = text.substring(from, to + closing.length);
    if (Platform.environment['UPDATE_STALL_EXITS'] == '1') {
      File(readme).writeAsStringSync(text.replaceRange(
        from,
        to + closing.length,
        generated,
      ));
      return;
    }
    expect(current, generated);
  });
}
