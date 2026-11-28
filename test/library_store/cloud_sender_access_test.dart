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

bool viewerAnswered(World world) =>
    switch (world.sender.accessRung(strategyId)) {
      (cannot: null, account: _, signIns: _, connection: _, count: _, at: _) =>
        true,
      _ => false,
    };

void refusedAsViewer(World world) {
  world.server.roles[strategyId] = StoreReadRole.viewer;
  world.server.answerWith(
    strategyId,
    const StoreBatchRefusedWhole(BatchRefusal.editAccessRemoved,
        point: stampedWhenAnswered),
  );
  world.commitMove(1);
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
        world.sender
          ..liveOpened(strategyId, theList)
          ..liveArrived(strategyId, theList, servedAccount, held);
        world.settle(const Duration(minutes: 1));
        expect(listReads(world, from), isEmpty);
        expect(world.sender.liveTaken, 1);
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
          world.sender
            ..liveOpened(strategyId, live)
            ..liveArrived(
              strategyId,
              live,
              servedAccount,
              live is ReadOfList ? listNow(world) : pageNow(world),
            );
          world.settle(const Duration(minutes: 1));
          expect(world.sender.liveTaken, 1, reason: '$live');
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
