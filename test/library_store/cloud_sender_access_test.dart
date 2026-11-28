import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/landed_retiring.dart';
import 'package:icarus_library/icarus_library.dart';

import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

const theList = ReadOfList();

StoreReadAnswered listNow(World world) =>
    world.server.answerNow(ReadCall(strategyId, null, servedAccount))
        as StoreReadAnswered;

StoreReadAnswered pageNow(World world) =>
    world.server.answerNow(ReadCall(strategyId, pageId, servedAccount))
        as StoreReadAnswered;

List<Duration> listReads(World world, Duration from) => [
      for (final call in world.server.readCalls)
        if (call.page == null && call.at!.difference(start) >= from)
          call.at!.difference(start) - from,
    ];

void ownerChangesTheStrategy(World world, String name) {
  final page = world.server.rows[strategyId]!.page(pageId)!;
  world.server.teammate(
    strategyId,
    PagePatchOp(
      opId: 'owner-renames-$name',
      pagePublicId: pageId,
      expectedPageRevision: revisionOf(page)!,
      name: name,
    ),
  );
}

bool viewerAnswered(World world) {
  final word = world.sender.readWord(strategyId);
  return word != null && word.cannot == null;
}

int checksMade(World world) =>
    world.sender.accessChecks(strategyId)?.count ?? 0;

void refusedAsViewer(World world) {
  world.server.roles[strategyId] = StoreReadRole.viewer;
  world.server.answerWith(
    strategyId,
    const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
        point: stampedWhenAnswered),
  );
  world.commitMove(1);
}

List<Duration> readsOf(World world, String strategy, Duration from) => [
      for (final call in world.server.readCalls)
        if (call.strategyId == strategy &&
            call.page == null &&
            call.at!.difference(start) >= from)
          call.at!.difference(start) - from,
    ];

void reconnectEvery(World world, int times, Duration apart) {
  for (var n = 0; n < times; n++) {
    world.connection = (world.connection ?? 1) + 1;
    world.settle(apart);
  }
}

const forbiddenRead = StoreReadRefused(
  StoreReadRefusal.forbidden,
  'forbidden',
  point: stampedWhenAnswered,
);

int accessReadsBetween(World world, Duration from, Duration to) => [
      for (final call in world.server.readCalls)
        if (call.page == null &&
            call.why == 'edit access was lost' &&
            call.at!.difference(start) >= from &&
            call.at!.difference(start) < to)
          call,
    ].length;

void liveListNow(World world, String change) {
  ownerChangesTheStrategy(world, change);
  world.sender.liveArrived(strategyId, theList, servedAccount, listNow(world));
}

void main() {
  group('a result at the point of one the store already took is settled', () {
    test('a live list at the point of the list the store took owes no read',
        () {
      inWorld((world) {
        final held = listNow(world);
        world.server.overrideRead = (call) => call.page == null ? held : null;
        world.addServedStrategy();
        final from = world.async.elapsed;
        final taken = world.sender.liveTaken;
        world.sender
          ..liveOpened(strategyId, theList)
          ..liveArrived(strategyId, theList, servedAccount, held);
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), isEmpty);
        expect(world.sender.liveTaken - taken, 1);
      }, addStrategy: false);
    });

    test(
        'a read to retire landed work, answered at the point of the live list '
        'the store took, is recorded: one read in three minutes, not the '
        'settle ladder', () {
      inWorld((world) {
        world.commitMove(1);
        world.settle();
        world.teammateDeletesPage(pageId);
        final live = listNow(world);
        world.server.overrideRead = (call) => call.page == null ? live : null;
        world.sender
          ..liveOpened(strategyId, theList)
          ..liveArrived(strategyId, theList, servedAccount, live);
        final from = world.async.elapsed;
        world.settle(const Duration(minutes: 3));
        expect(Retiring.landedByPage(world.cloud()).keys, [Retiring.list]);
        expect(listReads(world, from), hasLength(1));
        expect(world.sender.couldNotResolve(strategyId), isNull);
      });
    });
  });

  group('the access answer across reconnects and refusals', () {
    test(
        'a page read refused as FORBIDDEN, then a live viewer list: the owed '
        'page is read at once, not after the refusal\'s ten minutes', () {
      inWorld((world) {
        world.server.answerReadWith(
          strategyId,
          const StoreReadRefused(StoreReadRefusal.forbidden, 'forbidden',
              point: stampedWhenAnswered),
        );
        world.commitMove(1);
        world.settle(const Duration(minutes: 1));
        expect(world.sender.cannotRead(strategyId), isNotNull);
        world.server.roles[strategyId] = StoreReadRole.viewer;
        ownerChangesTheStrategy(world, 'Shared again');
        world.sender
          ..liveOpened(strategyId, theList)
          ..liveArrived(strategyId, theList, servedAccount, listNow(world));
        world.settle();
        expect(world.sender.cannotRead(strategyId), isNull);
        final from = world.async.elapsed;
        world.sender.owesFreshRead(strategyId, const ReadOfPage(pageId));
        world.settle(const Duration(seconds: 5));
        expect(
          [
            for (final call in world.server.readCalls)
              if (call.page == pageId && call.at!.difference(start) >= from)
                call,
          ],
          hasLength(1),
        );
      });
    });

    test(
        'ten reconnects 2.01 s apart make no more than the ladder\'s six page '
        'list reads, then stop', () {
      inWorld((world) {
        final from = world.async.elapsed;
        refusedAsViewer(world);
        world.settle(const Duration(minutes: 1));
        reconnectEvery(world, 10, const Duration(milliseconds: 2010));
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), hasLength(timing.accessReads));
        reconnectEvery(world, 10, const Duration(milliseconds: 2010));
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), hasLength(timing.accessReads));
        expect(world.face(), Face.editAccessLost);
      });
    });

    test(
        'twenty held strategies under ten reconnects make no more than six '
        'page list reads each', () {
      inWorld((world) {
        final ids = [for (var n = 0; n < 20; n++) 'held-$n'];
        for (final id in ids) {
          world.addOtherStrategy(id: id);
          world.server
            ..roles[id] = StoreReadRole.viewer
            ..answerWith(
              id,
              const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
                  point: stampedWhenAnswered),
            );
          world.commitRename(id, 'rename-$id');
        }
        final from = world.async.elapsed;
        world.settle(const Duration(minutes: 2));
        for (final id in ids) {
          expect(world.face(id), Face.editAccessLost, reason: id);
        }
        reconnectEvery(world, 10, const Duration(milliseconds: 2010));
        world.settle(const Duration(minutes: 2));
        for (final id in ids) {
          expect(
            readsOf(world, id, from),
            allOf(isNotEmpty, hasLength(lessThanOrEqualTo(timing.accessReads))),
            reason: id,
          );
        }
      });
    });
  });

  group('the count of access checks has two writers', () {
    test(
        'six sender reads answered FORBIDDEN stop the check, and a live viewer '
        'list after that makes no seventh', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.server.overrideRead =
            (call) => call.page == null ? forbiddenRead : null;
        refusedAsViewer(world);
        world.settle(const Duration(minutes: 70));
        expect(listReads(world, from), hasLength(timing.accessReads));
        expect(world.sender.accessCheckStopped(strategyId), isTrue);
        world.server.overrideRead = null;
        final taken = world.sender.liveTaken;
        liveListNow(world, 'Viewers again');
        world.settle(const Duration(minutes: 30));
        expect(world.sender.liveTaken - taken, 1);
        expect(world.sender.cannotRead(strategyId), isNull);
        expect(checksMade(world), timing.accessReads);
        expect(listReads(world, from), hasLength(timing.accessReads));
      });
    });

    test(
        'a live viewer list between each of ten reconnects, with every sender '
        'read answered FORBIDDEN, makes no more than six reads', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.server.overrideRead =
            (call) => call.page == null ? forbiddenRead : null;
        refusedAsViewer(world);
        world.settle(const Duration(minutes: 1));
        for (var n = 0; n < 10; n++) {
          world.connection = world.connection! + 1;
          world.settle(const Duration(seconds: 1));
          liveListNow(world, 'Between $n');
          world.settle(const Duration(milliseconds: 1010));
        }
        world.settle(const Duration(minutes: 30));
        expect(
          listReads(world, from),
          hasLength(lessThanOrEqualTo(timing.accessReads)),
        );
        expect(checksMade(world), listReads(world, from).length);
      });
    });

    test(
        'every kind of answer: the count moves only by the sender\'s own '
        'access reads, and an editor\'s answer clears it', () {
      inWorld((world) {
        final steps = <(String, void Function())>[
          ('a send refused as a viewer', () => refusedAsViewer(world)),
          ('a live viewer list', () => liveListNow(world, 'Viewer list')),
          (
            'a live page',
            () => world.sender
              ..liveOpened(strategyId, const ReadOfPage(pageId))
              ..liveArrived(strategyId, const ReadOfPage(pageId), servedAccount,
                  pageNow(world)),
          ),
          (
            'a live list refused as FORBIDDEN',
            () => world.sender.liveArrived(
                  strategyId,
                  theList,
                  servedAccount,
                  StoreReadRefused(
                    StoreReadRefusal.forbidden,
                    'forbidden',
                    point: world.server.stamp(),
                  ),
                ),
          ),
          ('a reconnect', () => world.connection = world.connection! + 1),
          (
            'a sender read answered FORBIDDEN',
            () {
              world.server.overrideRead =
                  (call) => call.page == null ? forbiddenRead : null;
              world.connection = world.connection! + 1;
            },
          ),
          (
            'a live viewer list again',
            () {
              world.server.overrideRead = null;
              liveListNow(world, 'Viewer list again');
            },
          ),
        ];
        for (final (name, step) in steps) {
          final before = checksMade(world);
          final from = world.async.elapsed;
          step();
          world.settle(const Duration(minutes: 1));
          expect(
            checksMade(world) - before,
            accessReadsBetween(world, from, world.async.elapsed),
            reason: name,
          );
        }
        expect(checksMade(world), greaterThan(0));
        world.server.roles[strategyId] = StoreReadRole.editor;
        liveListNow(world, 'Editors again');
        world.settle(const Duration(minutes: 1));
        expect(checksMade(world), 0);
        expect(world.sender.readWord(strategyId), isNull);
        expect(world.queueLength(), 0);
      });
    });
  });

  group('edit access lost', () {
    test(
        'the access read answered at the point of a live list already taken '
        'gives the viewer answer with one page list read, and still one a '
        'minute later', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, theList);
        final from = world.async.elapsed;
        refusedAsViewer(world);
        world.settle(const Duration(seconds: 1));
        expect(world.face(), Face.editAccessLost);
        ownerChangesTheStrategy(world, 'Viewers only');
        final live = listNow(world);
        world.server.overrideRead = (call) => call.page == null ? live : null;
        world.sender.liveArrived(strategyId, theList, servedAccount, live);
        world.settle(const Duration(seconds: 10));
        expect(listReads(world, from), hasLength(1));
        expect(viewerAnswered(world), isTrue);
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), hasLength(1));
        expect(viewerAnswered(world), isTrue);
        expect(world.face(), Face.editAccessLost);
      });
    });

    test(
        'a live list or page after the viewer answer leaves the answer '
        'standing and reads nothing more', () {
      for (final live in [theList, const ReadOfPage(pageId)]) {
        inWorld((world) {
          final from = world.async.elapsed;
          refusedAsViewer(world);
          world.settle(const Duration(minutes: 1));
          expect(listReads(world, from), hasLength(1), reason: '$live');
          expect(viewerAnswered(world), isTrue, reason: '$live');
          ownerChangesTheStrategy(world, 'Still viewers');
          final taken = world.sender.liveTaken;
          world.sender
            ..liveOpened(strategyId, live)
            ..liveArrived(
              strategyId,
              live,
              servedAccount,
              live is ReadOfList ? listNow(world) : pageNow(world),
            );
          world.settle(const Duration(minutes: 1));
          expect(world.sender.liveTaken - taken, 1, reason: '$live');
          expect(viewerAnswered(world), isTrue, reason: '$live');
          expect(listReads(world, from), hasLength(1), reason: '$live');
        });
      }
    });

    test(
        'a reconnect owes one page list read on the new connection, and a '
        'flapping connection makes no more than the read floor lets through',
        () {
      inWorld((world) {
        final from = world.async.elapsed;
        refusedAsViewer(world);
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), hasLength(1));

        world.connection = 2;
        world.settle(const Duration(minutes: 1));
        final once = listReads(world, from);
        expect(once, hasLength(2));
        expect(viewerAnswered(world), isTrue);

        for (final connection in [3, 4, 5, 6]) {
          world.connection = connection;
          world.settle(const Duration(milliseconds: 100));
        }
        world.settle(const Duration(minutes: 1));
        final flapped = listReads(world, from).skip(2).toList();
        expect(flapped, hasLength(2));
        expect(flapped.last - flapped.first,
            greaterThanOrEqualTo(timing.readFloor));
        expect(viewerAnswered(world), isTrue);
        expect(world.face(), Face.editAccessLost);
      });
    });
  });
}
