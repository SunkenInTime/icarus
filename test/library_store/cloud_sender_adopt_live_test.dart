import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/store_batch.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus_library/icarus_library.dart';

import 'cloud_sender_live_test.dart' show liveList;
import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

const _list = ReadOfList();

int _listReads(World world) =>
    world.server.readCalls.where((call) => call.page == null).length;

bool _adopted(World world) =>
    world.store.refusedStrategies[strategyId] == null &&
    !world.sender.adopting(strategyId) &&
    world.cloud().queue.session.number > 0;

void _offerList(World world, {Account? as}) => world.sender.liveArrived(
      strategyId,
      _list,
      as ?? servedAccount,
      liveList(world),
    );

void main() {
  group('adoption takes the editor\'s live page list', () {
    test('offered before adoption is asked: taken, no list read', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, _list);
        _offerList(world);
        world.sender.adopt(strategyId);
        world.settle();
        expect(_listReads(world), 0);
        expect(_adopted(world), isTrue);
        expect(world.sender.liveTaken, 1);
      }, addStrategy: false);
    });

    test('asked while the watch waits for its first answer: waits, then takes',
        () {
      inWorld((world) {
        world.openInEditor(strategyId);
        world.sender.liveOpened(strategyId, _list);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 0);
        expect(world.sender.adopting(strategyId), isTrue);
        _offerList(world);
        world.settle();
        expect(_listReads(world), 0);
        expect(_adopted(world), isTrue);
      }, addStrategy: false);
    });

    test('asked by the editor before its watch opens: waits for the watch', () {
      inWorld((world) {
        world.openInEditor(strategyId);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 0);
        world.sender.liveOpened(strategyId, _list);
        _offerList(world);
        world.settle();
        expect(_listReads(world), 0);
        expect(_adopted(world), isTrue);
      }, addStrategy: false);
    });

    test('a watch that never answers: one read after the first-result wait',
        () {
      inWorld((world) {
        world.openInEditor(strategyId);
        world.sender.liveOpened(strategyId, _list);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 9));
        expect(_listReads(world), 0);
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
        world.settle(const Duration(seconds: 30));
        expect(_listReads(world), 1);
      }, addStrategy: false);
    });

    test(
        'asked by the editor whose watch never opens: one read once the '
        'first-result wait has passed, counted from the first ask', () {
      inWorld((world) {
        world.openInEditor(strategyId);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 6));
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 0);
        world.settle(const Duration(seconds: 2));
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
      }, addStrategy: false);
    });

    test(
        'a page the store already holds is not read again for being shown, '
        'even while its watch stays silent', () {
      inWorld((world) {
        final before = world.server.readCalls.length;
        world.sender.liveOpened(strategyId, const ReadOfPage(pageId));
        world.settle(const Duration(minutes: 1));
        expect(world.server.readCalls.skip(before), isEmpty);
      });
    });

    test(
        'a page whose held content the queue owes a read is read without '
        'being shown, and a page it neither owes nor shows is not', () {
      final storage = MemoryStorage();
      final server = FakeServer();
      inWorld(
        (world) {
          world.secondPageOnServer();
          world.sender.adopt(strategyId);
          world.settle();
          world
            ..show(pageId)
            ..show('p2');
          world.connection = null;
          world.commitMove(1);
          world.settle();
        },
        storage: storage,
        server: server,
        addStrategy: false,
      );
      final contents = {
        for (final MapEntry(:key, :value) in storage.contents.entries)
          key: {...value},
      };
      contents[strategyArea(strategyId)]!['read/header'] = '{"version":99}';
      inWorld(
        (world) {
          final before = world.server.readCalls.length;
          world.settle(const Duration(minutes: 1));
          final pages = [
            for (final call in world.server.readCalls.skip(before))
              if (call.page case final page?) page,
          ];
          expect(world.cloud().queue.shown.content.keys, [pageId]);
          expect(pages, contains(pageId));
          expect(pages, isNot(contains('p2')));
          expect(world.server.applied, 1);
        },
        storage: MemoryStorage(contents),
        server: server,
        addStrategy: false,
      );
    });

    test(
        'a page the queue still owes a read once its edit is discarded is read '
        'without being shown', () {
      inWorld((world) {
        world.server.overrideRead = (call) => call.page == pageId
            ? const StoreReadLost(TransportFailure.network, 'held by the test')
            : null;
        world.server.answerNext(
          strategyId,
          (call) => Future.value(
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
              point: world.server.stamp(),
            ),
          ),
        );
        world.commitMove(1);
        world.settle(const Duration(seconds: 3));
        Saving<Recorded, CommitRefusal>? discarded;
        world.store.record(servedAccount, strategyId, [
          const UserDiscarded('move-1'),
        ]).then((value) => discarded = value);
        world.async.flushMicrotasks();
        expect(discarded, isA<Saved<Recorded, CommitRefusal>>());
        expect(world.cloud().queue.entries, isEmpty);
        expect(
          owedReads(world.cloud().queue),
          contains(const PageResult(pageId)),
        );
        world.server.overrideRead = null;
        final before = world.server.readCalls.length;
        world.settle(const Duration(minutes: 10));
        expect(
          [
            for (final call in world.server.readCalls.skip(before))
              if (call.page != null) call.page,
          ],
          contains(pageId),
        );
        expect(owedReads(world.cloud().queue), isEmpty);
      });
    });

    test('no editor and no watch: read at once, once', () {
      inWorld((world) {
        world.sender.adopt(strategyId);
        world.settle(const Duration(milliseconds: 500));
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
      }, addStrategy: false);
    });

    test('a refused live list is not adopted from: today\'s read, once', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, _list);
        world.sender.liveArrived(
          strategyId,
          _list,
          servedAccount,
          StoreReadRefused(
            StoreReadRefusal.forbidden,
            'forbidden',
            point: world.server.stamp(),
          ),
        );
        world.sender.adopt(strategyId);
        world.settle();
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
        world.settle(const Duration(minutes: 1));
        expect(_listReads(world), 1);
        expect(world.face(), isNull);
        expect(world.sender.liveTaken, 0);
      }, addStrategy: false);
    });

    test('a live list read as another account: today\'s read, once', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, _list);
        _offerList(world, as: Account('someone-else'));
        world.sender.adopt(strategyId);
        world.settle();
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
        expect(world.sender.liveTaken, 0);
      }, addStrategy: false);
    });

    void notTakenThenReadOnce(
      World world,
      StoreReadOutcome Function() answer, {
      bool reconnectFirst = false,
    }) {
      world.openInEditor(strategyId);
      world.sender.liveOpened(strategyId, _list);
      world.sender.liveArrived(strategyId, _list, servedAccount, answer());
      if (reconnectFirst) world.connection = 2;
      world.settle();
      world.sender.adopt(strategyId);
      world.settle();
      expect(_listReads(world), 1);
      expect(_adopted(world), isTrue);
      expect(world.sender.bound[strategyId]?.connection, world.connection);
      world.settle(const Duration(minutes: 1));
      expect(_listReads(world), 1);
      expect(world.sender.liveTaken, 0);
      expect(_adopted(world), isTrue);
      expect(world.face(), isNull);
    }

    test('a live list saying the strategy is gone is not taken: read, once',
        () {
      inWorld(
        (world) => notTakenThenReadOnce(
          world,
          () => StoreReadAnswered(
            const StrategyGone(),
            point: world.server.stamp(),
          ),
        ),
        addStrategy: false,
      );
    });

    test('an unreadable live list is not taken: read, once', () {
      inWorld(
        (world) => notTakenThenReadOnce(
          world,
          () => StoreReadUnreadable(
            'a shape this build cannot read',
            point: world.server.stamp(),
          ),
        ),
        addStrategy: false,
      );
    });

    test(
        'a live list from before a reconnect, picked after it, is not taken: '
        'read, once, on the connection that is current', () {
      inWorld(
        (world) => notTakenThenReadOnce(
          world,
          () => liveList(world),
          reconnectFirst: true,
        ),
        addStrategy: false,
      );
    });

    test(
        'a live gone from a connection that has ended is not taken: read, '
        'once, on the connection that is current', () {
      inWorld(
        (world) => notTakenThenReadOnce(
          world,
          () => StoreReadAnswered(
            const StrategyGone(),
            point: world.server.stamp(),
          ),
          reconnectFirst: true,
        ),
        addStrategy: false,
      );
    });

    group('one clock per take-up, from the first ask:', () {
      void readAtTheBound(World world) {
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 0);
        world.settle(const Duration(seconds: 2));
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
        world.settle(const Duration(minutes: 1));
        expect(_listReads(world), 1);
      }

      test('a watch opening later does not restart it', () {
        inWorld((world) {
          world.openInEditor(strategyId);
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 6));
          world.sender.liveOpened(strategyId, _list);
          readAtTheBound(world);
        }, addStrategy: false);
      });

      test('a connection change does not restart it', () {
        inWorld((world) {
          world.openInEditor(strategyId);
          world.sender.liveOpened(strategyId, _list);
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 6));
          world.connection = 2;
          readAtTheBound(world);
        }, addStrategy: false);
      });

      test('a reopen does not restart it', () {
        inWorld((world) {
          world.openInEditor(strategyId);
          world.sender.liveOpened(strategyId, _list);
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 6));
          world.sender.liveClosed(strategyId, _list);
          world.openInEditor(null);
          world.openInEditor(strategyId);
          world.sender.adopt(strategyId);
          world.sender.liveOpened(strategyId, _list);
          readAtTheBound(world);
        }, addStrategy: false);
      });

      test('a watch left behind by a closed editor does not keep it alive', () {
        inWorld((world) {
          world.openInEditor(strategyId);
          world.sender.liveOpened(strategyId, _list);
          world.sender.adopt(strategyId);
          world.settle(const Duration(seconds: 3));
          expect(_listReads(world), 0);
          world.openInEditor(null);
          world.settle(const Duration(milliseconds: 500));
          expect(_listReads(world), 1);
          expect(_adopted(world), isTrue);
        }, addStrategy: false);
      });
    });

    test('the editor closes while adoption waits on its watch: one read', () {
      inWorld((world) {
        world.openInEditor(strategyId);
        world.sender.liveOpened(strategyId, _list);
        world.sender.adopt(strategyId);
        world.settle(const Duration(seconds: 3));
        expect(_listReads(world), 0);
        world.sender.liveClosed(strategyId, _list);
        world.openInEditor(null);
        world.settle();
        expect(_listReads(world), 1);
        expect(_adopted(world), isTrue);
        world.settle(const Duration(minutes: 1));
        expect(_listReads(world), 1);
      }, addStrategy: false);
    });

    test('the same strategy opened twice in a row reads its list never', () {
      inWorld((world) {
        for (var open = 0; open < 2; open++) {
          world.openInEditor(strategyId);
          world.sender.adopt(strategyId);
          world.sender.liveOpened(strategyId, _list);
          _offerList(world);
          world.settle();
          world.sender.liveClosed(strategyId, _list);
          world.openInEditor(null);
          world.settle();
        }
        expect(_listReads(world), 0);
        expect(_adopted(world), isTrue);
        expect(world.sender.liveTaken, 2);
      }, addStrategy: false);
    });
  });

  test(
      'every order of the editor opening, the adoption asked, the watch '
      'opening, its answer and the editor closing adopts once, reading the '
      'list only when no answer can come first', () {
    const events = ['open', 'adopt', 'watch', 'answer', 'close'];
    Iterable<List<String>> orders(List<String> left) sync* {
      if (left.isEmpty) {
        yield const [];
        return;
      }
      for (final event in left) {
        for (final rest in orders([...left]..remove(event))) {
          yield [event, ...rest];
        }
      }
    }

    bool before(List<String> order, String a, String b) =>
        order.indexOf(a) < order.indexOf(b);
    var tried = 0;
    var readOnce = 0;
    for (final order in orders(events)) {
      if (!before(order, 'open', 'watch') ||
          !before(order, 'watch', 'answer') ||
          !before(order, 'open', 'close')) {
        continue;
      }
      tried++;
      final answered = before(order, 'answer', 'close');
      final askedFirst = before(order, 'adopt', 'open');
      inWorld((world) {
        for (final event in order) {
          switch (event) {
            case 'open':
              world.openInEditor(strategyId);
            case 'adopt':
              world.sender.adopt(strategyId);
            case 'watch':
              world.sender.liveOpened(strategyId, _list);
            case 'answer':
              if (answered) _offerList(world);
            case 'close':
              world.sender.liveClosed(strategyId, _list);
              world.openInEditor(null);
          }
          world.settle(const Duration(seconds: 1));
        }
        world.settle(const Duration(seconds: 30));
        final reads = _listReads(world);
        expect(_adopted(world), isTrue, reason: '$order');
        expect(reads, lessThanOrEqualTo(1), reason: '$order');
        if (askedFirst || !answered) {
          expect(reads, 1, reason: '$order');
          readOnce++;
        } else {
          expect(reads, 0, reason: '$order');
        }
      }, addStrategy: false);
    }
    printOnFailure('$tried orders, $readOnce of them read the list once');
    expect(tried, greaterThan(10));
  });
}
