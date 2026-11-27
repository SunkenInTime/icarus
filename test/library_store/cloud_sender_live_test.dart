import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/stall_exits.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/editor_subscriptions_provider.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show User;

import 'sender_world.dart';
import 'server_fixtures.dart' show pageId, servedAccount, strategyId;

const openPage = ReadOfPage(pageId);

ResultStamp stampOf(ResultPoint point) => ResultStamp(
      client: point.client,
      connection: point.connection,
      snapshot: point.snapshot,
      serverTime: point.serverTime,
    );

double lifeOf(Row row) => (createdAtOf(row) ?? firstLife).toDouble();

Map<String, Object?> jsonOf(Row row) => row.toJson()! as Map<String, Object?>;

ConvexValue wirePage(World world, String page) {
  final rows = world.server.rows[strategyId]!;
  final read =
      (world.server.answerNow(ReadCall(strategyId, page, servedAccount))
              as StoreReadAnswered)
          .base as PageRead;
  final fields = jsonOf(read.page);
  final settings = rows.settingsOf(page)!;
  return ConvexValue.fromDart({
    'page': {
      'publicId': read.page.publicId,
      'strategyPublicId': strategyId,
      'name': fields['name'],
      if (fields['isAutoNamed'] case final named?) 'isAutoNamed': named,
      'sortIndex': fields['sortIndex'],
      'isAttack': fields['isAttack'],
      'revision': fields['revision'],
      'createdAt': lifeOf(read.page),
      'updatedAt': lifeOf(read.page),
    },
    'content': {
      'settings': jsonOf(settings)['settings'],
      'revision': jsonOf(settings)['revision'],
      'createdAt': lifeOf(lived(settings)),
      'updatedAt': lifeOf(lived(settings)),
    },
    'elements': [
      for (final element in read.elements)
        {
          'publicId': element.publicId,
          'strategyPublicId': strategyId,
          'pagePublicId': page,
          'elementType': (jsonOf(element)['payload']! as Map)['kind'],
          'payload': jsonOf(element)['payload'],
          'sortIndex': jsonOf(element)['sortIndex'],
          'revision': jsonOf(element)['revision'],
          'deleted': jsonOf(element)['deleted'] ?? false,
          'createdAt': lifeOf(element),
          'updatedAt': lifeOf(element),
        },
    ],
    'lineups': const <Object?>[],
    'assets': const <Object?>[],
  });
}

final class LivePageServer implements StampedConvexTransport {
  LivePageServer(this.world);

  final World world;
  final calls = <String>[];
  final arguments = <String, List<Map<String, Object?>>>{};
  final _watching = <(String, StreamController<Stamped<ConvexValue>>)>[];
  final _plain = <(String, StreamController<ConvexValue>)>[];

  String _pageOf(ConvexObject args) =>
      args.value['pagePublicId']!.toDart()! as String;

  void _record(String call, String name, ConvexObject args) {
    calls.add('$call $name');
    (arguments[name] ??= []).add(args.toDart());
  }

  Stamped<ConvexValue> _answer(String page) =>
      StampedValue(wirePage(world, page), stampOf(world.server.stamp()));

  void publish(String page) {
    for (final (watched, controller) in _watching) {
      if (watched == page) controller.add(_answer(page));
    }
    for (final (watched, controller) in _plain) {
      if (watched == page) controller.add(wirePage(world, page));
    }
  }

  void refuse(String page, String code) {
    for (final (watched, controller) in _watching) {
      if (watched == page) {
        controller.add(StampedError(
          ConvexTransportError(rawCode: code, message: 'refused'),
          stampOf(world.server.stamp()),
        ));
      }
    }
  }

  @override
  Stream<Stamped<ConvexValue>> subscribeStamped(
    String name,
    ConvexObject args,
  ) {
    _record('subscribeStamped', name, args);
    final page = _pageOf(args);
    late final StreamController<Stamped<ConvexValue>> controller;
    controller = StreamController<Stamped<ConvexValue>>(
      onListen: () {
        _watching.add((page, controller));
        controller.add(_answer(page));
      },
      onCancel: () => _watching.removeWhere((each) => each.$2 == controller),
    );
    return controller.stream;
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    _record('subscribe', name, args);
    final page = _pageOf(args);
    late final StreamController<ConvexValue> controller;
    controller = StreamController<ConvexValue>(
      onListen: () {
        _plain.add((page, controller));
        controller.add(wirePage(world, page));
      },
      onCancel: () => _plain.removeWhere((each) => each.$2 == controller),
    );
    return controller.stream;
  }

  @override
  Future<({int client, int connection})> generation() =>
      world.server.generation();

  @override
  Future<Stamped<ConvexValue>> queryStamped(String name, ConvexObject args) =>
      throw UnimplementedError('queryStamped $name');

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError('query $name');

  @override
  Future<Stamped<ConvexValue>> mutationStamped(
    String name,
    ConvexObject args,
  ) =>
      throw UnimplementedError('mutationStamped $name');

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError('mutation $name');

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError('action $name');

  @override
  Stream<Stamped<List<ConvexValue>>> subscribeTogetherStamped(
    List<(String, ConvexObject)> queries,
  ) =>
      throw UnimplementedError('subscribeTogetherStamped');

  @override
  Stream<List<ConvexValue>> subscribeTogether(
    List<(String, ConvexObject)> queries,
  ) =>
      throw UnimplementedError('subscribeTogether');
}

class _SignedIn extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: servedAccount.subject,
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

ProviderContainer editorOver(
  World world,
  LivePageServer live,
  CloudStoreSwitch cloud,
) {
  final container = ProviderContainer(overrides: [
    cloudStoreSwitchProvider.overrideWithValue(cloud),
    convexStrategyRepositoryProvider.overrideWithValue(
      ConvexStrategyRepository(IcarusConvexApi(live)),
    ),
    storeRepositoryProvider.overrideWithValue(
      ConvexStrategyRepository.stamped(live),
    ),
    authProvider.overrideWith(_SignedIn.new),
  ]);
  container.read(storeLiveResultsProvider).attach(world.sender);
  return container;
}

StoreReadAnswered livePage(World world) =>
    world.server.answerNow(ReadCall(strategyId, pageId, servedAccount))
        as StoreReadAnswered;

List<BaseArrived> pageResultsWritten(World world) => [
      for (final event in world.written())
        if (event case BaseArrived(base: PageRead() || PageGone())) event,
    ];

int revisionOnServer(World world, String element) =>
    revisionOf(world.server.rows[strategyId]!.element(element))!;

int revisionInStore(World world) => world.firstElement().revision;

void main() {
  group('with the store switch on, the editor\'s page watch', () {
    test(
        'an edit sent and answered, then seen through the live watch, is '
        'taken by the store, and the open page is never read one-shot', () {
      inWorld((world) {
        final live = LivePageServer(world);
        final container = editorOver(world, live, const CloudStoreSend());
        final shown = <Object>[];
        final watch = container
            .read(editorSubscriptionsProvider)
            .page(strategyPublicId: strategyId, pagePublicId: pageId)
            .listen(shown.add);
        world.settle();
        final readsBefore = world.server.readsOf(strategyId).length;

        world.commitMove(1);
        world.settle();
        expect(world.server.log, contains('send move-1'));
        expect(world.cloud().queue.landed, isNotEmpty);
        live.publish(pageId);
        world.settle(const Duration(minutes: 5));

        expect(world.cloud().queue.landed, isEmpty);
        final moved = world.firstElement().publicId;
        expect(revisionInStore(world), revisionOnServer(world, moved));
        expect(world.server.readsOf(strategyId).skip(readsBefore), isEmpty);
        expect(live.calls, ['subscribeStamped page:getSnapshot']);
        expect(
          live.arguments['page:getSnapshot']!.single['accountSubject'],
          servedAccount.subject,
        );
        expect(shown, hasLength(2));
        expect(world.sender.liveTaken, 2);

        unawaited(watch.cancel());
        container.dispose();
        world.settle();
      });
    });

    test('a teammate\'s edit seen through the watch is taken without a read',
        () {
      inWorld((world) {
        final live = LivePageServer(world);
        final container = editorOver(world, live, const CloudStoreSend());
        final watch = container
            .read(editorSubscriptionsProvider)
            .page(strategyPublicId: strategyId, pagePublicId: pageId)
            .listen((_) {});
        world.settle();
        final readsBefore = world.server.readsOf(strategyId).length;
        world.teammateMoves(1);
        live.publish(pageId);
        world.settle();
        final moved = world.firstElement().publicId;
        expect(revisionInStore(world), revisionOnServer(world, moved));
        expect(world.server.readsOf(strategyId).skip(readsBefore), isEmpty);
        unawaited(watch.cancel());
        container.dispose();
        world.settle();
      });
    });
  });

  test(
      'with the switch off, the editor watches today\'s queries without the '
      'account, and the store gets nothing from it', () {
    inWorld((world) {
      final live = LivePageServer(world);
      final container = editorOver(world, live, const CloudStoreOff());
      final watch = container
          .read(editorSubscriptionsProvider)
          .page(strategyPublicId: strategyId, pagePublicId: pageId)
          .listen((_) {});
      world.settle();
      final resultsBefore = pageResultsWritten(world).length;
      world.teammateMoves(1);
      live.publish(pageId);
      world.settle();
      expect(live.calls, ['subscribe page:getSnapshot']);
      expect(
        live.arguments['page:getSnapshot']!.single
            .containsKey('accountSubject'),
        isFalse,
      );
      expect(world.sender.liveTaken, 0);
      expect(pageResultsWritten(world), hasLength(resultsBefore));
      unawaited(watch.cancel());
      container.dispose();
      world.settle();
    });
  });

  test(
      'newest only: a burst that arrives while a live result is being taken '
      'leaves only its newest to take after it', () {
    inWorld((world) {
      world.sender.liveOpened(strategyId, openPage);
      world.slowStore.baseWritesWait = const Duration(seconds: 1);
      final delivered = <ResultPoint>[];
      for (var n = 0; n < 4; n++) {
        world.teammateMoves(n);
        final result = livePage(world);
        delivered.add(result.point);
        world.sender.liveArrived(strategyId, openPage, servedAccount, result);
        if (n == 0) world.async.elapse(const Duration(milliseconds: 100));
      }
      world.settle(const Duration(seconds: 10));
      expect(
        [for (final result in pageResultsWritten(world)) result.point].skip(
          pageResultsWritten(world).length - 2,
        ),
        [delivered.first, delivered.last],
      );
      expect(
        pageResultsWritten(world).map((result) => result.point),
        isNot(anyOf(contains(delivered[1]), contains(delivered[2]))),
      );
      expect(world.sender.liveReplaced, 2);
      expect(world.sender.liveTaken, 2);
    });
  });

  group('the same admission as a read', () {
    test('a live result is labelled with the queue\'s current session', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, openPage);
        world.teammateMoves(1);
        world.sender
            .liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        expect(
          pageResultsWritten(world).last.session,
          world.cloud().queue.session.number,
        );
        final moved = world.firstElement().publicId;
        expect(revisionInStore(world), revisionOnServer(world, moved));
      });
    });

    test(
        'a live result from a connection that has ended is not taken: the '
        'current connection goes ahead of it', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, openPage);
        world.settle();
        final moved = world.firstElement().publicId;
        final before = revisionInStore(world);
        world.teammateMoves(1);
        final stale = livePage(world);
        world.server.connection = 2;
        world.sender.liveArrived(strategyId, openPage, servedAccount, stale);
        world.settle();
        expect(revisionInStore(world), before);
        final written = world.written();
        final arrived = written.lastIndexWhere(
          (event) => event is BaseArrived && event.point == stale.point,
        );
        expect(arrived, greaterThan(0));
        expect(
          written[arrived - 1],
          isA<ConnectionReturned>().having(
            (event) => event.generation,
            'generation',
            const Generation(client: 1, connection: 2),
          ),
        );
      });
    });

    for (final code in ['ACCOUNT_MISMATCH', 'FORBIDDEN', 'NOT_FOUND']) {
      test('a live $code reaches the queue as a one-shot read\'s would', () {
        StoreReadOutcome refused(World world) => pageOutcomeOf(
              StampedError(
                ConvexTransportError(rawCode: code, message: 'refused'),
                stampOf(world.server.stamp()),
              ),
              pagePublicId: pageId,
              canRead: appCanRead,
            );

        ({List<String> events, StallExit? waits, bool cannotRead}) after(
          void Function(World world) deliver,
        ) {
          late ({List<String> events, StallExit? waits, bool cannotRead}) seen;
          inWorld((world) {
            final from = world.written().length;
            deliver(world);
            world.settle();
            seen = (
              events: [
                for (final event in world.written().skip(from))
                  switch (event) {
                    BaseArrived(:final base) =>
                      'BaseArrived ${base.runtimeType}',
                    ReadRefusedForSignIn(:final refusal) =>
                      'ReadRefusedForSignIn ${refusal.name}',
                    _ => '${event.runtimeType}',
                  },
              ],
              waits: world.sender.waitingOn(strategyId),
              cannotRead: world.sender.cannotRead(strategyId) != null,
            );
          });
          return seen;
        }

        final read = after((world) {
          world.server.overrideRead =
              (call) => call.page == pageId ? refused(world) : null;
          world.sender.owesFreshRead(strategyId, openPage);
        });
        final live = after((world) {
          world.sender
            ..liveOpened(strategyId, openPage)
            ..liveArrived(strategyId, openPage, servedAccount, refused(world));
        });
        expect(live.events, read.events);
        expect(live.waits, read.waits);
        expect(live.cannotRead, read.cannotRead);
        expect(
          code == 'FORBIDDEN' ? read.cannotRead : read.events.isNotEmpty,
          isTrue,
        );
      });
    }
  });

  group('one-shot reads of a watched page step back', () {
    List<String> pageReads(World world, Duration from) => [
          for (final call in world.server.readCalls)
            if (call.page == pageId && call.at!.difference(start) >= from)
              '${(call.at!.difference(start) - from).inSeconds} s',
        ];

    test(
        'a watch with no first result holds the read for the bound, then the '
        'page is read as before', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.sender.liveOpened(strategyId, openPage);
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(const Duration(seconds: 5));
        expect(pageReads(world, from), isEmpty);
        expect(
          world.sender.waitingOn(strategyId),
          StallExit.liveNoFirstResult,
        );
        world.settle(const Duration(seconds: 10));
        expect(pageReads(world, from), [
          '${timing.firstLiveResult.inSeconds} s',
        ]);
      });
    });

    test(
        'a watch that has given a result on this connection holds every read '
        'of its page until it closes; a reconnect starts the bound again', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.sender
          ..liveOpened(strategyId, openPage)
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(const Duration(minutes: 1));
        expect(pageReads(world, from), isEmpty);

        world.connection = 2;
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(const Duration(seconds: 5));
        expect(pageReads(world, from), isEmpty);
        world.settle(const Duration(seconds: 10));
        expect(pageReads(world, from), hasLength(1));

        world.sender
            .liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(const Duration(minutes: 1));
        expect(pageReads(world, from), hasLength(1));

        world.sender.liveClosed(strategyId, openPage);
        world.settle();
        expect(pageReads(world, from), hasLength(2));
      });
    });
  });

  test(
      'an answer ahead of every live result waits on the watch with its face: '
      'no read of the page while the watch is current, counted once, and the '
      'next change seen through the watch pays it', () {
    inWorld((world) {
      const watched = ReadOfPage('p2');
      StoreReadAnswered p2(World world) =>
          world.server.answerNow(ReadCall(strategyId, 'p2', servedAccount))
              as StoreReadAnswered;
      world.pagesOnServer(['p2']);
      world.sender.adopt(strategyId);
      world.settle(const Duration(minutes: 1));
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
        ..liveOpened(strategyId, watched)
        ..liveArrived(strategyId, watched, servedAccount, p2(world));
      world.settle();
      final readsBefore = world.server.readsOf(strategyId).length;
      world.commitPageDelete('delete-p2', 'p2');
      world.settle(const Duration(minutes: 10));

      expect(world.cloud().queue.shown.waitsOnClock('p2'), isTrue);
      expect(world.face(), Face.awaitingResult);
      expect(world.sender.waitingOn(strategyId), StallExit.answerAhead);
      expect(
        world.server.readsOf(strategyId).skip(readsBefore),
        isNot(contains('page p2')),
      );
      expect(world.sender.clockWaitsOnLive, 1);

      world.server.skew = 0;
      world.sender.liveArrived(strategyId, watched, servedAccount, p2(world));
      world.settle(const Duration(minutes: 1));
      expect(world.cloud().queue.shown.waitsOnClock('p2'), isFalse);
      expect(world.server.log, contains('send delete-p2'));
      expect(world.sender.clockWaitsOnLive, 1);
    }, addStrategy: false);
  });
}
