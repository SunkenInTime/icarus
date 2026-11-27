import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart' show RemoteStrategyShell;
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/store_reads.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/call_governor.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_open.dart' show appCanRead;
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/library_store/live_results.dart';
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

const theList = 'the page list';

Map<String, Object?> wirePageFields(PageRow page) {
  final fields = jsonOf(page);
  return {
    'publicId': page.publicId,
    'strategyPublicId': strategyId,
    'name': fields['name'],
    if (fields['isAutoNamed'] case final named?) 'isAutoNamed': named,
    'sortIndex': fields['sortIndex'],
    'isAttack': fields['isAttack'],
    'revision': fields['revision'],
    'createdAt': lifeOf(page),
    'updatedAt': lifeOf(page),
  };
}

ConvexValue wireList(World world) {
  final header = world.server.headerOf(strategyId);
  final strategy = jsonOf(header.strategy);
  final settings = {
    for (final row in header.settings) row.pagePublicId: row,
  };
  return ConvexValue.fromDart({
    'header': {
      'publicId': strategyId,
      'name': strategy['name'],
      'mapData': strategy['mapData'],
      'revision': strategy['revision'],
      'createdAt': lifeOf(header.strategy),
      'updatedAt': lifeOf(header.strategy),
      'themeProfileId': null,
      'themeOverridePalette': null,
      'role': (world.server.roles[strategyId] ?? StoreReadRole.owner).name,
    },
    'pages': [
      for (final page in header.pages)
        {
          ...wirePageFields(page),
          'settings': jsonOf(settings[page.publicId]!)['settings'],
          'contentRevision': jsonOf(settings[page.publicId]!)['revision'],
          'contentCreatedAt': lifeOf(settings[page.publicId]!),
          'contentUpdatedAt': lifeOf(settings[page.publicId]!),
        },
    ],
  });
}

final class LivePageServer implements StampedConvexTransport {
  LivePageServer(this.world);

  final World world;
  final calls = <String>[];
  final arguments = <String, List<Map<String, Object?>>>{};
  final _watching = <(String, StreamController<Stamped<ConvexValue>>)>[];
  final _plain = <(String, StreamController<ConvexValue>)>[];

  String _subjectOf(String name, ConvexObject args) =>
      name == 'strategy:getPageList'
          ? theList
          : args.value['pagePublicId']!.toDart()! as String;

  ConvexValue _wire(String subject) =>
      subject == theList ? wireList(world) : wirePage(world, subject);

  void _record(String call, String name, ConvexObject args) {
    calls.add('$call $name');
    (arguments[name] ??= []).add(args.toDart());
  }

  Stamped<ConvexValue> _answer(String subject) =>
      StampedValue(_wire(subject), stampOf(world.server.stamp()));

  void publish(String page) {
    for (final (watched, controller) in _watching) {
      if (watched == page) controller.add(_answer(page));
    }
    for (final (watched, controller) in _plain) {
      if (watched == page) controller.add(_wire(page));
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
    final page = _subjectOf(name, args);
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
    final page = _subjectOf(name, args);
    late final StreamController<ConvexValue> controller;
    controller = StreamController<ConvexValue>(
      onListen: () {
        _plain.add((page, controller));
        controller.add(_wire(page));
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

String moved(World world) => world.firstElement().publicId;

List<String> pageReads(World world, Duration from) => [
      for (final call in world.server.readCalls)
        if (call.page == pageId && call.at!.difference(start) >= from)
          '${(call.at!.difference(start) - from).inSeconds} s',
    ];

const theListRead = ReadOfList();

StoreReadAnswered liveList(World world) =>
    world.server.answerNow(ReadCall(strategyId, null, servedAccount))
        as StoreReadAnswered;

List<String> listReads(World world, Duration from) => [
      for (final call in world.server.readCalls)
        if (call.page == null && call.at!.difference(start) >= from)
          '${(call.at!.difference(start) - from).inSeconds} s',
    ];

void teammateRenamesPage(World world, String name) {
  final page = world.server.rows[strategyId]!.page(pageId)!;
  world.server.teammate(
    strategyId,
    PagePatchOp(
      opId: 'teammate-renames-$name',
      pagePublicId: pageId,
      expectedPageRevision: revisionOf(page)!,
      name: name,
    ),
  );
}

String storedPageName(World world) => jsonOf(
      world.rowOf(
        (content) =>
            content.pages.firstWhere((page) => page.publicId == pageId),
      ),
    )['name']! as String;

List<BaseArrived> listResultsWritten(World world) => [
      for (final event in world.written())
        if (event case BaseArrived(base: HeaderRead())) event,
    ];

StoreReadAnswered at(StoreReadAnswered result, int snapshot) =>
    StoreReadAnswered(
      result.base,
      point: ResultPoint(
        client: result.point.client,
        connection: result.point.connection,
        snapshot: snapshot,
        serverTime: result.point.serverTime,
      ),
      role: result.role,
    );

final class _ThrowingStore implements LiveResults {
  var told = 0;

  @override
  void liveOpened(String strategyId, ReadOf subject) =>
      throw StateError('the store broke on open');

  @override
  void liveArrived(
    String strategyId,
    ReadOf subject,
    Account account,
    StoreReadOutcome outcome,
  ) {
    told++;
    throw StateError('the store broke');
  }

  @override
  void liveClosed(String strategyId, ReadOf subject) =>
      throw StateError('the store broke on close');
}

const watchedP2 = ReadOfPage('p2');

StoreReadAnswered p2Of(World world) =>
    world.server.answerNow(ReadCall(strategyId, 'p2', servedAccount))
        as StoreReadAnswered;

int clockHeldOnWatch(World world) {
  world.pagesOnServer(['p2']);
  world.sender.adopt(strategyId);
  world.settle(const Duration(minutes: 1));
  final strategy = world.rowOf((content) => content.strategy);
  world.commit([
    PageReorderOp(
      opId: 'reorder',
      pagePublicId: 'p2',
      sortIndex: 0,
      expectedStrategyRevision: (strategy.toJson()! as Map)['revision']! as int,
    ),
  ]);
  world.settle(const Duration(seconds: 5));
  world.server.skew = -const Duration(hours: 3).inMilliseconds;
  world.connection = 2;
  world.sender
    ..liveOpened(strategyId, watchedP2)
    ..liveArrived(strategyId, watchedP2, servedAccount, p2Of(world));
  world.settle();
  final readsBefore = world.server.readsOf(strategyId).length;
  world.commitPageDelete('delete-p2', 'p2');
  return readsBefore;
}

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
        'a watch that has given a result on this connection holds a read of '
        'its page for the grace only, then reads it once: a debt no change on '
        'the server pays is not left to wait for the next edit', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.sender
          ..liveOpened(strategyId, openPage)
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(timing.liveGrace - const Duration(milliseconds: 500));
        expect(pageReads(world, from), isEmpty);
        world.settle(const Duration(seconds: 1));
        expect(pageReads(world, from), hasLength(1));
        world.settle(const Duration(minutes: 1));
        expect(pageReads(world, from), hasLength(1));

        world.connection = 2;
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle(const Duration(seconds: 5));
        expect(pageReads(world, from), hasLength(1));
        world.settle(const Duration(seconds: 10));
        expect(pageReads(world, from), hasLength(2));

        world.sender.liveClosed(strategyId, openPage);
        world.sender.owesFreshRead(strategyId, openPage);
        world.settle();
        expect(pageReads(world, from), hasLength(3));
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
      expect(world.sender.waitingOn(strategyId), StallExit.clockOnWatch);
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

  group('with the store switch on, the editor\'s list watch', () {
    test(
        'a teammate\'s page rename seen through the live list is taken by the '
        'store, and no one-shot page list is read while the watch is current',
        () {
      inWorld((world) {
        final live = LivePageServer(world);
        final container = editorOver(world, live, const CloudStoreSend());
        final shells = <RemoteStrategyShell>[];
        final watch = container
            .read(editorSubscriptionsProvider)
            .shell(strategyId)
            .listen(shells.add);
        world.settle();
        final from = world.async.elapsed;

        world.sender.owesFreshRead(strategyId, theListRead);
        world.settle(timing.liveGrace - const Duration(milliseconds: 500));
        expect(listReads(world, from), isEmpty);
        teammateRenamesPage(world, 'Retake');
        live.publish(theList);
        world.settle(const Duration(minutes: 2));

        expect(storedPageName(world), 'Retake');
        expect(shells.last.pages.single.name, 'Retake');
        expect(listReads(world, from), isEmpty);
        expect(live.calls, ['subscribeStamped strategy:getPageList']);
        expect(
          live.arguments['strategy:getPageList']!.single['accountSubject'],
          servedAccount.subject,
        );

        unawaited(watch.cancel());
        container.dispose();
        world.settle();
      });
    });

    test('a share-link list watch never reaches the store', () {
      inWorld((world) {
        final live = LivePageServer(world);
        final container = editorOver(world, live, const CloudStoreSend());
        final watch = container
            .read(editorSubscriptionsProvider)
            .shell(strategyId, shareToken: 'shared')
            .listen((_) {});
        world.settle();
        final before = listResultsWritten(world).length;
        teammateRenamesPage(world, 'Retake');
        live.publish(theList);
        world.settle();
        expect(listResultsWritten(world), hasLength(before));
        expect(world.sender.liveTaken, 0);
        unawaited(watch.cancel());
        container.dispose();
        world.settle();
      });
    });
  });

  group('the page list as a live subject', () {
    test(
        'the bound, the grace and a reconnect hold one-shot list reads as '
        'they do a page\'s', () {
      inWorld((world) {
        final from = world.async.elapsed;
        world.sender.liveOpened(strategyId, theListRead);
        world.sender.owesFreshRead(strategyId, theListRead);
        world.settle(const Duration(seconds: 5));
        expect(listReads(world, from), isEmpty);
        expect(
          world.sender.waitingOn(strategyId),
          StallExit.liveNoFirstResult,
        );
        world.settle(const Duration(seconds: 6));
        expect(
            listReads(world, from), ['${timing.firstLiveResult.inSeconds} s']);

        world.sender.liveArrived(
            strategyId, theListRead, servedAccount, liveList(world));
        world.settle();
        world.sender.owesFreshRead(strategyId, theListRead);
        world.settle(timing.liveGrace - const Duration(milliseconds: 500));
        expect(listReads(world, from), hasLength(1));
        world.settle(const Duration(seconds: 1));
        expect(listReads(world, from), hasLength(2));

        world.connection = 2;
        world.sender.owesFreshRead(strategyId, theListRead);
        world.settle(const Duration(seconds: 5));
        expect(listReads(world, from), hasLength(2));
        world.settle(const Duration(seconds: 10));
        expect(listReads(world, from), hasLength(3));
      });
    });

    test(
        'newest only: a burst of lists while one is being taken leaves only '
        'the newest', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, theListRead);
        world.slowStore.baseWritesWait = const Duration(seconds: 1);
        final delivered = <ResultPoint>[];
        for (var n = 0; n < 4; n++) {
          teammateRenamesPage(world, 'Name $n');
          final result = liveList(world);
          delivered.add(result.point);
          world.sender
              .liveArrived(strategyId, theListRead, servedAccount, result);
          if (n == 0) world.async.elapse(const Duration(milliseconds: 100));
        }
        world.settle(const Duration(seconds: 10));
        final taken = [
          for (final result in listResultsWritten(world)) result.point,
        ];
        expect(taken.skip(taken.length - 2), [delivered.first, delivered.last]);
        expect(taken,
            isNot(anyOf(contains(delivered[1]), contains(delivered[2]))));
        expect(storedPageName(world), 'Name 3');
        expect(world.sender.liveReplaced, 2);
      });
    });

    test('a live list from a connection that has ended is not taken', () {
      inWorld((world) {
        world.sender.liveOpened(strategyId, theListRead);
        world.settle();
        final before = storedPageName(world);
        teammateRenamesPage(world, 'Retake');
        final stale = liveList(world);
        world.server.connection = 2;
        world.sender.liveArrived(strategyId, theListRead, servedAccount, stale);
        world.settle();
        expect(storedPageName(world), before);
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
  });

  group('a delivered live result reaches the store or leaves a read owed', () {
    test(
        'an older callback does not replace a newer pending result: 6 then 5 '
        'while 3 is being taken ends with 6 taken', () {
      inWorld((world) {
        world.sender
          ..liveOpened(strategyId, openPage)
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        final base = world.server.stamp().snapshot;
        world.slowStore.baseWritesWait = const Duration(seconds: 1);
        world.teammateMoves(1);
        world.sender.liveArrived(
            strategyId, openPage, servedAccount, at(livePage(world), base + 3));
        world.async.elapse(const Duration(milliseconds: 100));
        world.teammateMoves(2);
        final five = at(livePage(world), base + 5);
        world.teammateMoves(3);
        final six = at(livePage(world), base + 6);
        world.sender
          ..liveArrived(strategyId, openPage, servedAccount, six)
          ..liveArrived(strategyId, openPage, servedAccount, five)
          ..liveArrived(
            strategyId,
            openPage,
            servedAccount,
            const StoreReadLost(TransportFailure.network, 'dropped'),
          );
        world.settle(const Duration(seconds: 10));
        final taken = [
          for (final result in pageResultsWritten(world)) result.point.snapshot,
        ];
        expect(taken.last, base + 6);
        expect(taken, isNot(contains(base + 5)));
        expect(revisionInStore(world), revisionOnServer(world, moved(world)));
      });
    });

    test(
        'a watch closed with a result pending still gets it to the store, with '
        'no further edit', () {
      inWorld((world) {
        world.sender
          ..liveOpened(strategyId, openPage)
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        world.slowStore.baseWritesWait = const Duration(seconds: 1);
        world.teammateMoves(1);
        world.sender
            .liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.async.elapse(const Duration(milliseconds: 100));
        world.teammateMoves(2);
        world.sender
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world))
          ..liveClosed(strategyId, openPage);
        world.settle(const Duration(minutes: 1));
        expect(revisionInStore(world), revisionOnServer(world, moved(world)));
      });
    });

    test(
        'a connection lookup that fails once with a result pending gets the '
        'result to the store within the read retry timing', () {
      inWorld((world) {
        world.sender
          ..liveOpened(strategyId, openPage)
          ..liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle();
        world.server.lookup = () {
          world.server.lookup = null;
          throw StateError('the lookup broke');
        };
        world.teammateMoves(1);
        world.sender
            .liveArrived(strategyId, openPage, servedAccount, livePage(world));
        world.settle(timing.readRetryAfter(1) + timing.liveGrace);
        expect(revisionInStore(world), revisionOnServer(world, moved(world)));
      });
    });
  });

  test(
      'the editor gets every update even when the hand-off to the store throws',
      () {
    inWorld((world) {
      final live = LivePageServer(world);
      final store = _ThrowingStore();
      final subscriptions = StampedSubscriptions(
        ConvexStrategyRepository.stamped(live),
        accountSubject: () => servedAccount.subject,
        live: store,
        canRead: appCanRead,
      );
      final pages = <Object>[];
      final errors = <Object>[];
      final shells = <Object>[];
      final watches = [
        subscriptions
            .page(strategyPublicId: strategyId, pagePublicId: pageId)
            .listen(pages.add, onError: errors.add),
        subscriptions.shell(strategyId).listen(shells.add, onError: errors.add),
      ];
      world.settle();
      world.teammateMoves(1);
      live.publish(pageId);
      live.publish(theList);
      world.settle();
      world.teammateMoves(2);
      live.publish(pageId);
      live.publish(theList);
      world.settle();
      expect(pages, hasLength(3));
      expect(shells, hasLength(3));
      expect(errors, isEmpty);
      expect(store.told, 6);
      for (final watch in watches) {
        unawaited(watch.cancel());
      }
      world.settle();
    });
  });

  group('the clock wait on a current watch', () {
    test(
        'is bounded: after the ladder\'s rounds, with no read, it shows as '
        'could not resolve, with its row', () {
      inWorld((world) {
        final readsBefore = clockHeldOnWatch(world);
        final rounds = [
          for (var n = 1; n < timing.unresolvedRounds; n++)
            timing.settleAfter(n),
        ].fold(Duration.zero, (sum, rung) => sum + rung);
        world.settle(const Duration(seconds: 1));
        expect(world.sender.couldNotResolve(strategyId), isNull);
        world.settle(rounds + const Duration(seconds: 1));
        expect(
          world.sender.couldNotResolve(strategyId)?.subjects,
          ['page p2'],
        );
        expect(world.sender.waitingOn(strategyId), StallExit.clockOnWatch);
        world.settle(const Duration(hours: 1));
        expect(
          world.server.readsOf(strategyId).skip(readsBefore),
          isNot(contains('page p2')),
        );
      }, addStrategy: false);
    });

    test(
        'the user\'s retry asks the client to reconnect, once, and the '
        'watch\'s answer on the new connection pays it', () {
      inWorld((world) {
        clockHeldOnWatch(world);
        world.settle(const Duration(minutes: 10));
        world.server.skew = 0;
        world.onReconnect = () {
          world.connection = 3;
          world.sender
              .liveArrived(strategyId, watchedP2, servedAccount, p2Of(world));
        };
        world.sender.retryNow(strategyId);
        world.settle(const Duration(minutes: 1));
        expect(world.reconnects, 1);
        expect(world.cloud().queue.shown.waitsOnClock('p2'), isFalse);
        expect(world.server.log, contains('send delete-p2'));
        world.sender.retryNow(strategyId);
        world.settle();
        expect(world.reconnects, 1);
      }, addStrategy: false);
    });
  });
}
