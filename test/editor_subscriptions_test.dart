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
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
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

const stampedCalls = [
  'query strategy:getShell',
  'query page:getSnapshot',
  'subscribeStamped strategy:getShell',
  'subscribeStamped page:getSnapshot',
  'subscribeTogetherStamped page:getFrame,page:getElementSlice,'
      'page:getElementSlice',
];

typedef Outcome = ({int recoveries, String rereads, bool upgradeAsked});

void main() {
  late _TwoPageServer server;
  late StampedOver editorTransport;
  late StampedOver storeTransport;

  void freshServer() {
    server = _TwoPageServer();
    editorTransport = StampedOver(server);
    storeTransport = StampedOver(server);
  }

  setUp(freshServer);

  ProviderContainer start({CloudStoreSwitch? cloud}) {
    final container = ProviderContainer(overrides: [
      if (cloud != null) cloudStoreSwitchProvider.overrideWithValue(cloud),
      convexStrategyRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository(IcarusConvexApi(editorTransport)),
      ),
      storeRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository.stamped(storeTransport),
      ),
      authProvider.overrideWith(_RecoveringAuthProvider.new),
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

  RemoteEditorSnapshot? shownIn(ProviderContainer container) =>
      container.read(remoteEditorSnapshotProvider).valueOrNull;

  Future<RemoteEditorSnapshot?> openThenTeammateEditsPageA(
    ProviderContainer container,
  ) async {
    await container.read(remoteEditorSnapshotProvider.future);
    await container
        .read(remoteEditorSnapshotProvider.notifier)
        .openStrategy('strategy', activePagePublicId: 'a');
    await pumpEventQueue();
    server.publishPage('a', _agents(20, moved: {_id(1)}));
    await pumpEventQueue();
    return shownIn(container);
  }

  Future<RemoteEditorSnapshot?> thenTeammateEditsAgainAndAddsAPage(
    ProviderContainer container,
  ) async {
    server.publishPage('a', _agents(20, moved: {_id(1), _id(12)}));
    server.publishShell(['a', 'b', 'c']);
    await pumpEventQueue();
    return shownIn(container);
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
        'stamped, and nothing through the editor\'s transport', () async {
      final cloud = LibraryStoreLaunch.parse(
        ['--library-store=store', '--cloud-store=send'],
        mayShadow: true,
      ).cloud;
      expect(cloud, isA<CloudStoreSend>());

      await openThenTeammateEditsPageA(start(cloud: cloud));

      expect(editorTransport.calls, isEmpty);
      expect(storeTransport.calls, stampedCalls);
    });
  });

  for (final cloud in [const CloudStoreOff(), const CloudStoreSend()]) {
    test(
        'with the switch ${cloud is CloudStoreSend ? 'on' : 'off'}, the editor '
        'shows a teammate\'s edits before and after the page is watched in '
        'slices, and a new page in the shell', () async {
      final container = start(cloud: cloud);

      final whole = await openThenTeammateEditsPageA(container);
      expect(_revisionsOf(whole), {_id(1): 2});

      final sliced = await thenTeammateEditsAgainAndAddsAPage(container);
      expect(_revisionsOf(sliced), {_id(1): 2, _id(12): 2});
      expect(sliced?.shell.pages.map((page) => page.publicId), [
        'a',
        'b',
        'c',
      ]);
      expect(
        (cloud is CloudStoreSend ? storeTransport : editorTransport).calls,
        cloud is CloudStoreSend ? stampedCalls : todaysCalls,
      );
    });
  }

  group('a refused watch reaches the editor the same with either kind', () {
    Future<Outcome> refused(
      CloudStoreSwitch cloud,
      String code,
      String watch,
    ) async {
      freshServer();
      final container = start(cloud: cloud);
      await openThenTeammateEditsPageA(container);
      final transport =
          cloud is CloudStoreSend ? storeTransport : editorTransport;
      final before = transport.calls.length;
      server.refuse(
        ConvexTransportError(rawCode: code, message: 'refused'),
        watch: watch,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await pumpEventQueue();
      return (
        recoveries:
            (container.read(authProvider.notifier) as _RecoveringAuthProvider)
                .recoveries,
        rereads: [
          for (final call in transport.calls.skip(before))
            if (call.startsWith('query ')) call,
        ].join(', '),
        upgradeAsked: container.read(clientUpgradeRequiredProvider),
      );
    }

    const shell = 'query strategy:getShell';
    const both = 'query strategy:getShell, query page:getSnapshot';
    for (final (code, watch, expected) in <(String, String, Outcome)>[
      (
        'UNAUTHENTICATED',
        'shell',
        (recoveries: 1, rereads: '', upgradeAsked: false)
      ),
      (
        'UNAUTHENTICATED',
        'page',
        (recoveries: 3, rereads: '', upgradeAsked: false)
      ),
      (
        'FORBIDDEN',
        'shell',
        (recoveries: 0, rereads: shell, upgradeAsked: false)
      ),
      (
        'FORBIDDEN',
        'page',
        (recoveries: 0, rereads: both, upgradeAsked: false)
      ),
      (
        'CLIENT_UPGRADE_REQUIRED',
        'shell',
        (recoveries: 0, rereads: '', upgradeAsked: true)
      ),
      (
        'CLIENT_UPGRADE_REQUIRED',
        'page',
        (recoveries: 0, rereads: '', upgradeAsked: true)
      ),
      (
        'NOT_FOUND',
        'shell',
        (recoveries: 0, rereads: shell, upgradeAsked: false)
      ),
      (
        'NOT_FOUND',
        'page',
        (recoveries: 0, rereads: both, upgradeAsked: false)
      ),
      (
        'A_CODE_THIS_CLIENT_DOES_NOT_KNOW',
        'shell',
        (recoveries: 0, rereads: shell, upgradeAsked: false)
      ),
      (
        'A_CODE_THIS_CLIENT_DOES_NOT_KNOW',
        'page',
        (recoveries: 0, rereads: both, upgradeAsked: false)
      ),
    ]) {
      test('$code on the $watch watch, the page watched in slices', () async {
        expect(await refused(const CloudStoreOff(), code, watch), expected);
        expect(await refused(const CloudStoreSend(), code, watch), expected);
      });
    }
  });
}

Map<String, int> _revisionsOf(RemoteEditorSnapshot? shown) => {
      for (final element in shown?.activePage?.elements ?? const <Never>[])
        if (element.revision != 1) element.publicId: element.revision,
    };

String _id(int index) =>
    '${'0123456789abcdef'[index % 16]}${index.toString().padLeft(2, '0')}';

List<Map<String, Object?>> _agents(int count, {Set<String> moved = const {}}) =>
    [
      for (var index = 0; index < count; index++)
        agentRow(
          _id(index),
          'a',
          revision: moved.contains(_id(index)) ? 2 : 1,
        ),
    ];

final class _TwoPageServer
    with SubscribeTogetherFromEach
    implements ConvexTransport {
  var _shellPages = ['a', 'b'];
  var _shellRevision = 1;
  final _elements = <String, List<Map<String, Object?>>>{
    'a': _agents(20),
    'b': const [],
    'c': const [],
  };
  final _live = <(String, ConvexObject, StreamController<ConvexValue>)>[];

  void publishPage(String page, List<Map<String, Object?>> elements) {
    _elements[page] = elements;
    for (final (name, args, controller) in _live) {
      if (name.startsWith('page:')) controller.add(_answer(name, args));
    }
  }

  void publishShell(List<String> pages) {
    _shellPages = pages;
    _shellRevision++;
    for (final (name, args, controller) in _live) {
      if (name == 'strategy:getShell') controller.add(_answer(name, args));
    }
  }

  void refuse(ConvexTransportError error, {required String watch}) {
    for (final (name, _, controller) in _live) {
      if (watch == 'shell'
          ? name == 'strategy:getShell'
          : name != 'strategy:getShell') {
        controller.addError(error);
      }
    }
  }

  ConvexValue _answer(String name, ConvexObject args) {
    if (name == 'strategy:getShell') {
      return shellAnswer(_shellPages, revision: _shellRevision);
    }
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

class _RecoveringAuthProvider extends AuthProvider {
  var recoveries = 0;

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

  @override
  Future<void> reportConvexUnauthenticated({
    required String source,
    Object? error,
    StackTrace? stackTrace,
  }) async {
    recoveries++;
  }
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
