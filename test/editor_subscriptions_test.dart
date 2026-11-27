import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_switch.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'collab/stamped_over.dart';
import 'collab/strategy_copy_fixtures.dart';
import 'collab/subscribe_together_from_each.dart';

const todaysCalls = [
  'query strategy:getShell',
  'query page:getSnapshot',
  'subscribe strategy:getShell',
  'subscribe page:getSnapshot',
  'subscribeTogether page:getFrame,page:getElementSlice,page:getElementSlice',
];

void main() {
  late _TwoPageServer server;
  late StampedOver editorTransport;
  late StampedOver storeTransport;

  setUp(() {
    server = _TwoPageServer();
    editorTransport = StampedOver(server);
    storeTransport = StampedOver(server);
  });

  ProviderContainer start({CloudStoreSwitch? cloud}) {
    final container = ProviderContainer(overrides: [
      if (cloud != null) cloudStoreSwitchProvider.overrideWithValue(cloud),
      convexStrategyRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository(IcarusConvexApi(editorTransport)),
      ),
      storeRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository.stamped(storeTransport),
      ),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
      convexConnectionSnapshotProvider.overrideWith((ref) => true),
      cloudOfflineProvider.overrideWith((ref) => false),
      cloudStrategyCopyStoreProvider.overrideWith(
        (ref) => MemoryCloudStrategyCopyStore(),
      ),
      cloudCopyScopeProvider.overrideWith(
        (ref) => CloudCopyScope.begin(
          deploymentUrl: 'https://one.convex.cloud',
          accountId: 'account-a',
        ),
      ),
      strategyCopyRefresherProvider.overrideWith(_IdleRefresher.new),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<RemoteEditorSnapshot?> openThenTeammateEditsPageA(
      ProviderContainer container) async {
    await container.read(remoteEditorSnapshotProvider.future);
    await container
        .read(remoteEditorSnapshotProvider.notifier)
        .openStrategy('strategy', activePagePublicId: 'a');
    await pumpEventQueue();
    server.publish('a', _agents(20, moved: _id(1)));
    await pumpEventQueue();
    return container.read(remoteEditorSnapshotProvider).requireValue;
  }

  group('with the store switch off', () {
    test(
        'the editor makes today\'s calls, by name, and none through the '
        'store\'s transport', () async {
      final shown = await openThenTeammateEditsPageA(start());

      expect(editorTransport.calls, todaysCalls);
      expect(storeTransport.calls, isEmpty);
      expect(shown?.activePage?.elements, hasLength(20));
    });

    for (final (where, args, mayShadow) in [
      ('a native start with no switch', <String>[], true),
      (
        'a web start, even asked for the store',
        ['--library-store=store', '--cloud-store=send'],
        false,
      ),
    ]) {
      test('$where hands the editor today\'s subscriptions', () async {
        final cloud =
            LibraryStoreLaunch.parse(args, mayShadow: mayShadow).cloud;
        expect(cloud, isA<CloudStoreOff>());

        await openThenTeammateEditsPageA(start(cloud: cloud));

        expect(editorTransport.calls, todaysCalls);
        expect(storeTransport.calls, isEmpty);
      });
    }
  });

  group('with the store switch on', () {
    test(
        'a native start asked for the store watches the same queries '
        'stamped, and the editor shows what they answer', () async {
      final cloud = LibraryStoreLaunch.parse(
        ['--library-store=store', '--cloud-store=send'],
        mayShadow: true,
      ).cloud;
      expect(cloud, isA<CloudStoreSend>());

      final shown = await openThenTeammateEditsPageA(start(cloud: cloud));

      expect(editorTransport.calls, isEmpty);
      expect(storeTransport.calls, [
        'query strategy:getShell',
        'query page:getSnapshot',
        'subscribeStamped strategy:getShell',
        'subscribeStamped page:getSnapshot',
        'subscribeTogetherStamped page:getFrame,page:getElementSlice,'
            'page:getElementSlice',
      ]);
      expect(shown?.activePage?.elements, hasLength(20));
      expect(
        shown?.activePage?.elements
            .singleWhere((element) => element.publicId == _id(1))
            .revision,
        2,
      );
    });

    test(
        'a refused page watch reaches the editor as it does with the switch '
        'off: it reads the strategy again', () async {
      Future<List<String>> readsAfterRefusal(CloudStoreSwitch cloud) async {
        server = _TwoPageServer();
        editorTransport = StampedOver(server);
        storeTransport = StampedOver(server);
        final container = start(cloud: cloud);
        await openThenTeammateEditsPageA(container);
        final transport =
            cloud is CloudStoreSend ? storeTransport : editorTransport;
        final before = transport.calls.length;
        server.refuse(
          const ConvexTransportError(rawCode: 'FORBIDDEN', message: 'page'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await pumpEventQueue();
        return [
          for (final call in transport.calls.skip(before))
            if (call.startsWith('query ')) call,
        ];
      }

      final off = await readsAfterRefusal(const CloudStoreOff());
      expect(off, ['query strategy:getShell', 'query page:getSnapshot']);
      expect(await readsAfterRefusal(const CloudStoreSend()), off);
    });
  });
}

String _id(int index) =>
    '${'0123456789abcdef'[index % 16]}${index.toString().padLeft(2, '0')}';

List<Map<String, Object?>> _agents(int count, {String? moved}) => [
      for (var index = 0; index < count; index++)
        agentRow(_id(index), 'a', revision: _id(index) == moved ? 2 : 1),
    ];

final class _TwoPageServer
    with SubscribeTogetherFromEach
    implements ConvexTransport {
  final _elements = <String, List<Map<String, Object?>>>{
    'a': _agents(20),
    'b': const [],
  };
  final _live = <(String, ConvexObject, StreamController<ConvexValue>)>[];

  void publish(String page, List<Map<String, Object?>> elements) {
    _elements[page] = elements;
    for (final (name, args, controller) in _live) {
      if (name.startsWith('page:')) controller.add(_answer(name, args));
    }
  }

  void refuse(ConvexTransportError error) {
    for (final (name, _, controller) in _live) {
      if (name.startsWith('page:')) controller.addError(error);
    }
  }

  ConvexValue _answer(String name, ConvexObject args) {
    if (name == 'strategy:getShell') return shellAnswer(['a', 'b']);
    final page = args.value['pagePublicId']!.toDart() as String;
    final whole = pageAnswer(page, elements: _elements[page]!).toDart();
    switch (name) {
      case 'page:getSnapshot':
        return ConvexValue.fromDart(whole);
      case 'page:getFrame':
        return ConvexValue.fromDart({
          'page': whole['page'],
          'content': whole['content'],
          'lineups': whole['lineups'],
          'assets': whole['assets'],
        });
      case 'page:getElementSlice':
        final from = args.value['fromPublicId']!.toDart() as String;
        final to = args.value['toPublicId']?.toDart() as String?;
        return ConvexValue.fromDart({
          'elements': [
            for (final element in whole['elements']! as List<Object?>)
              if (_inRange((element! as Map)['publicId'] as String, from, to))
                element,
          ],
          'assets': const <Object?>[],
        });
    }
    throw UnimplementedError(name);
  }

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async =>
      _answer(name, args);

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    final controller = StreamController<ConvexValue>();
    _live.add((name, args, controller));
    controller.add(_answer(name, args));
    return controller.stream;
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError(name);

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError(name);
}

bool _inRange(String id, String from, String? to) =>
    id.compareTo(from) >= 0 && (to == null || id.compareTo(to) < 0);

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _IdleOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'strategy',
        clientId: 'client',
        durableLoaded: true,
      );

  @override
  void setActiveStrategy(
    String? strategyPublicId, {
    required String? accountId,
  }) {}

  @override
  List<StrategyOp> pageChangesToDraw(RemoteEditorSnapshot snapshot) => const [];

  @override
  bool isDeletedHere(String pageId) => false;
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}

class _IdleRefresher extends StrategyCopyRefresher {
  @override
  void build() {}

  @override
  void keepOpenedStrategy(String strategyId) {}
}
