import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender.dart';
import 'package:icarus/library_store/sender_store.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_shadow_test.dart' show strategyId;
import 'sender_world.dart';

ResultPoint onConnection(World world, int connection) => ResultPoint(
      client: 1,
      connection: connection,
      snapshot: world.server.stamp().snapshot,
      serverTime: world.server.serverNow,
    );

Map<String, Map<String, String>> copied(MemoryStorage storage) => {
      for (final MapEntry(:key, :value) in storage.contents.entries)
        key: {...value},
    };

void main() {
  test(
      'a move sent on connection 1 and refused UNAUTHENTICATED on connection '
      '1 after the client moved to connection 2 is sent again under the same '
      'op id once the app reconnects on the same sign-in', () {
    inWorld((world) {
      world.settle();
      world.server.answerNext(strategyId, (call) async {
        world.server.connection = 2;
        return StoreBatchRefusedWhole(
          BatchRefusal.unauthenticated,
          point: onConnection(world, 1),
        );
      });
      world.commitMove(1);
      world.settle(const Duration(seconds: 1));
      expect(world.sender.runHold, isNull);
      world.connection = 2;
      world.settle(const Duration(minutes: 2));
      expect(world.sender.signInWaitFrom, isNull);
      expect(world.server.calls, hasLength(2));
      expect(
        [for (final call in world.server.calls) call.opIds],
        [
          ['move-1'],
          ['move-1'],
        ],
      );
      expect(world.queueLength(), 0);
    });
  });

  test(
      'a page list read refused ACCOUNT_MISMATCH on connection 1 after the '
      'client moved to connection 2 holds nothing: the list is read again and '
      'the next edit is sent', () {
    inWorld((world) {
      world.settle();
      final reads = world.server.readCalls.length;
      world.server.answerReadNext(strategyId, (call) async {
        world.server.connection = 2;
        return StoreReadRefused(
          StoreReadRefusal.accountMismatch,
          'another account',
          point: onConnection(world, 1),
        );
      });
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 30));
      expect(world.sender.runHold, isNull);
      expect(world.sender.signInWaitFrom, isNull);
      expect(
        [for (final call in world.server.readCalls.skip(reads)) '$call'],
        ['list', 'list'],
      );
      world.commitMove(1);
      world.settle(const Duration(seconds: 5));
      expect(world.server.calls.last.opIds, ['move-1']);
      expect(world.queueLength(), 0);
    });
  });

  test(
      'a page read refused for an upgrade on a connection that has ended '
      'holds nothing and shows nothing', () {
    inWorld((world) {
      world.settle();
      world.server.answerReadNext(strategyId, (call) async {
        world.server.connection = 2;
        return StoreReadRefused(
          StoreReadRefusal.upgradeRequired,
          'upgrade',
          point: onConnection(world, 1),
        );
      });
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 30));
      expect(world.sender.upgradeAsked, isFalse);
      expect(world.face(), isNull);
      world.commitMove(1);
      world.settle(const Duration(seconds: 5));
      expect(world.server.calls.last.opIds, ['move-1']);
    });
  });

  test(
      'a batch refused whole on a connection that has ended keeps the read '
      'backoff it found: a FORBIDDEN read is not forgotten', () {
    inWorld((world) {
      world.settle();
      world.server.answerReadWith(
        strategyId,
        const StoreReadRefused(
          StoreReadRefusal.forbidden,
          'forbidden',
          point: stampedWhenAnswered,
        ),
      );
      world.sender.owesFreshRead(strategyId, const ReadOfList());
      world.settle(const Duration(seconds: 5));
      expect(world.sender.cannotRead(strategyId), isNotNull);
      world.server.answerNext(strategyId, (call) async {
        world.server.connection = 2;
        return StoreBatchRefusedWhole(
          BatchRefusal.strategyReplaced,
          point: onConnection(world, 1),
          currentLife: firstLife + 1,
        );
      });
      world.commitMove(1);
      world.settle(const Duration(milliseconds: 500));
      expect(world.server.calls, hasLength(1));
      expect(world.sender.cannotRead(strategyId), isNotNull);
    });
  });

  test(
      'a batch refused whole on a connection that has ended leaves the read '
      'ladder where it was', () {
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
      final list = '${const ReadOfList()}';
      final ladder = world.sender.readMemory(strategyId).settle[list];
      expect(ladder?.count, 2);
      world.server.answerNext(strategyId, (call) async {
        world.server.connection = 2;
        return StoreBatchRefusedWhole(
          BatchRefusal.strategyReplaced,
          point: onConnection(world, 1),
          currentLife: firstLife + 1,
        );
      });
      world.commitMove(1);
      world.settle(const Duration(milliseconds: 500));
      expect(world.server.calls, hasLength(1));
      expect(world.sender.readMemory(strategyId).settle[list], ladder);
    });
  });

  for (final (refusal, connection, holds) in [
    (BatchRefusal.unauthenticated, 1, true),
    (BatchRefusal.unauthenticated, 0, false),
  ]) {
    test(
        'a batch refused with no server time, before the client applied any '
        'state, is judged by its connection: '
        '${holds ? 'the current one holds the run' : 'an ended one is lost'}',
        () {
      inWorld((world) {
        world.settle();
        world.server.answerNext(strategyId, (call) async {
          world.server.connection = 2;
          return StoreBatchRefusedWhole(
            refusal,
            point: ResultPoint(
              client: 1,
              connection: connection + 1,
              snapshot: 0,
            ),
          );
        });
        world.commitMove(1);
        world.settle(const Duration(seconds: 5));
        expect(world.sender.runHold, holds ? isA<SignInHold>() : isNull);
        expect(world.server.calls, hasLength(holds ? 1 : 2));
      });
    });
  }

  test(
      'an answer that acknowledges nothing proposes no server time to judge '
      'live writes by', () {
    inWorld((world) {
      world.settle();
      final held = world.written().whereType<ServerTimeHeld>().length;
      world.server.answerWith(
        strategyId,
        StoreBatchAnswered(
          const [],
          complete: false,
          point: stampedWhenAnswered,
          serverTime: world.server.serverNow,
        ),
      );
      world.commitMerge(1);
      world.settle(const Duration(milliseconds: 500));
      expect(world.server.calls, hasLength(1));
      expect(world.written().whereType<ServerTimeHeld>(), hasLength(held));
    });
  });

  test(
      'a strategy the store refuses after the sender loaded its queue, while '
      'its session is bound, gets no read', () {
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
    final contents = copied(storage);
    final area = strategyArea(strategyId);
    final damaged = contents[area]!.keys.firstWhere(
          (key) => key.contains('/e/'),
        );
    contents[area]![damaged] = '{"broken":true}';
    inWorld(
      (world) {
        world.settle(const Duration(minutes: 1));
        world.sender.owesFreshRead(strategyId, const ReadOfList());
        world.settle(const Duration(seconds: 10));
        expect(world.sender.bound[strategyId], isNotNull);
        final before = server.readCalls.length;
        world.slowStore.afterRead = const Duration(seconds: 10);
        world.sender.owesFreshRead(strategyId, const ReadOfList());
        world.async.elapse(const Duration(seconds: 1));
        expect(world.sender.busy, isTrue);
        for (final page in server.rows[strategyId]!.pages) {
          world.store.readPage(strategyId, page.publicId);
        }
        world.settle(Duration.zero);
        expect(world.store.refusedStrategies.keys, [strategyId]);
        world.slowStore.afterRead = Duration.zero;
        world.settle(const Duration(hours: 1));
        expect(server.readCalls.skip(before), isEmpty);
        expect(
          world.sender.store.reports
              .whereType<StoredRowsRefused>()
              .map((report) => report.strategyId),
          [strategyId],
        );
      },
      storage: MemoryStorage(contents),
      server: server,
      addStrategy: false,
    );
  });
}
