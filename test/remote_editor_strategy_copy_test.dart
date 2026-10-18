import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_library_copy.dart';
import 'package:icarus/collab/cloud_strategy_copy_box.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_copy_scope_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_copy_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'collab/strategy_copy_fixtures.dart';

const _deployment = 'https://one.convex.cloud';

/// The scope of [accountId] signing in now: a session of its own.
CloudCopyScope _beginSession(String accountId) =>
    CloudCopyScope.begin(deploymentUrl: _deployment, accountId: accountId);

late CloudCopyScope _scope;

final _offline = StateProvider<bool>((ref) => false);

/// The socket is connecting or reconnecting; the session isn't offline.
final _socketDown = StateProvider<bool>((ref) => false);

/// Runs as web does: no copy on this computer.
var _webLike = false;

void main() {
  late _Transport transport;
  late MemoryCloudStrategyCopyStore store;
  late ProviderContainer container;
  late _RecordingRefresher refresher;

  setUp(() {
    _scope = _beginSession('account-a');
    _webLike = false;
    transport = _Transport();
    store = MemoryCloudStrategyCopyStore();
    container = ProviderContainer(overrides: [
      convexStrategyRepositoryProvider.overrideWithValue(
        ConvexStrategyRepository(IcarusConvexApi(transport)),
      ),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      strategyOpQueueProvider.overrideWith(_IdleOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_IdleMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue(null),
      convexConnectionSnapshotProvider.overrideWith(
        (ref) => !ref.watch(_offline) && !ref.watch(_socketDown),
      ),
      cloudOfflineProvider.overrideWith((ref) => ref.watch(_offline)),
      cloudStrategyCopyStoreProvider.overrideWith(
        (ref) => _webLike ? UnavailableCloudStrategyCopyStore() : store,
      ),
      cloudCopyScopeProvider.overrideWith((ref) {
        final accountId = ref.watch(authProvider.select((a) => a.user?.id));
        return accountId == null ? null : _beginSession(accountId);
      }),
      strategyCopyRefresherProvider.overrideWith(_RecordingRefresher.new),
    ]);
    refresher = container.read(strategyCopyRefresherProvider.notifier)
        as _RecordingRefresher;
  });
  tearDown(() => container.dispose());

  RemoteEditorSnapshotNotifier remote() =>
      container.read(remoteEditorSnapshotProvider.notifier);

  Future<void> openOnline() async {
    await container.read(remoteEditorSnapshotProvider.future);
    await remote().openStrategy('strategy', activePagePublicId: 'a');
    await _settle();
  }

  test(
      'every live answer the editor reads is kept, and a live open reads '
      'the whole strategy', () async {
    await openOnline();
    expect(store.readShell(_scope, 'strategy')?.pages, hasLength(3));
    expect(store.readPage(_scope, 'strategy', 'a'), isNotNull);
    expect(refresher.kept, ['strategy']);

    // A teammate's edit to page a arrives live.
    transport.pushPage('a', [agentRow('agent', 'a', revision: 2, x: 9)]);
    await _settle();
    expect(
      store.readPage(_scope, 'strategy', 'a')!.elements.single.revision,
      2,
    );

    // Switching to page b reads it, and keeps it.
    final b = await remote().fetchPage('b');
    expect(b.fromCopy, isFalse);
    await remote().setActivePage('b', fetched: b);
    expect(store.readPage(_scope, 'strategy', 'b'), isNotNull);
  });

  test('offline, a kept strategy opens from the copy and switches pages',
      () async {
    await openOnline();
    await remote().setActivePage('b');
    await remote().setActivePage('c');
    remote().clear();

    container.read(_offline.notifier).state = true;
    transport.unanswered = true;
    await remote().openStrategy('strategy', activePagePublicId: 'a');

    final opened = container.read(remoteEditorSnapshotProvider).valueOrNull!;
    expect(opened.shell.fromCopy, isTrue);
    expect(opened.activePage!.fromCopy, isTrue);
    expect(opened.activePage!.page.publicId, 'a');
    expect(opened.activePage!.elements.single.publicId, 'agent');
    expect(refresher.kept, ['strategy'], reason: 'no full read offline');

    for (final pageId in ['b', 'c']) {
      final page = await remote().fetchPage(pageId);
      expect(page.fromCopy, isTrue);
      await remote().setActivePage(pageId, fetched: page);
      final shown = container.read(remoteEditorSnapshotProvider).valueOrNull!;
      expect(shown.activePage?.page.publicId, pageId);
    }
  });

  test('offline, a strategy never kept says it needs a connection', () async {
    await container.read(remoteEditorSnapshotProvider.future);
    container.read(_offline.notifier).state = true;
    await remote().openStrategy('strategy', activePagePublicId: 'a');

    expect(
      container.read(remoteEditorSnapshotProvider).error,
      isA<StrategyNotKeptOffline>(),
    );
    expect(transport.reads, isEmpty);
  });

  test('a read the server never answers falls back to the copy', () async {
    await openOnline();
    remote().clear();

    // The socket still says connected, but the read times out.
    transport.unanswered = true;
    await remote().openStrategy('strategy', activePagePublicId: 'a');
    final opened = container.read(remoteEditorSnapshotProvider).valueOrNull!;
    expect(opened.shell.fromCopy, isTrue);
    expect(opened.activePage!.fromCopy, isTrue);
  });

  test('a refusal is not read as offline', () async {
    await openOnline();
    remote().clear();

    transport.refusal = const ConvexTransportError(
      rawCode: 'INTERNAL',
      message: 'boom',
    );
    await remote().openStrategy('strategy', activePagePublicId: 'a');
    expect(container.read(remoteEditorSnapshotProvider).valueOrNull, isNull);
  });

  _ReadyAuthProvider auth() =>
      container.read(authProvider.notifier) as _ReadyAuthProvider;

  /// What AuthProvider does when [accountId]'s session ends: end its
  /// sessions, then delete everything but the account signed in now (none,
  /// when it is signing out).
  Future<void> endAccount(String accountId) async {
    _beginSession(accountId).endSessions();
    final current = container.read(cloudCopyScopeProvider);
    await store.deleteAllExcept(
      current?.accountId == accountId ? null : current,
    );
  }

  test('an answer held across Supabase ending the session is kept for no one',
      () async {
    await container.read(remoteEditorSnapshotProvider.future);
    final held = Completer<void>();
    transport.hold = held;
    final opening = remote().openStrategy('strategy', activePagePublicId: 'a');
    await _settle();

    // A revoked refresh token: Supabase signs the account out by itself.
    auth().signedOutBySupabase();
    await endAccount('account-a');
    held.complete();
    await opening;
    await _settle();

    expect(store.entryKeys, isEmpty);
  });

  test('the same account signing back in keeps its answers again', () async {
    await openOnline();
    auth().startSigningOut();
    await endAccount('account-a');
    remote().clear();

    auth().signBackIn('account-a');
    await openOnline();

    expect(store.keepsStrategy(_scope, 'strategy'), isTrue);
  });

  test(
      'an answer that arrives while signing out does not bring back the '
      'copy sign-out deleted', () async {
    await openOnline();
    auth().startSigningOut();
    await endAccount('account-a');

    transport.pushPage('a', [agentRow('agent', 'a', revision: 5)]);
    await _settle();

    expect(store.keptStrategyIds(_scope), isEmpty);
  });

  test(
      'after an account switch, the old account\'s answers are kept for '
      'neither account', () async {
    await openOnline();
    auth().switchTo('account-b');
    await endAccount('account-a');

    transport.pushPage('a', [agentRow('agent', 'a', revision: 5)]);
    await _settle();

    expect(store.keptStrategyIds(_scope), isEmpty);
    expect(store.entryKeys, isEmpty);
  });

  test('an answer read before an account switch is kept for neither account',
      () async {
    await container.read(remoteEditorSnapshotProvider.future);
    final held = Completer<void>();
    transport.hold = held;
    final opening = remote().openStrategy('strategy', activePagePublicId: 'a');
    await _settle();
    expect(transport.reads, ['strategy:getShell']);

    auth().switchTo('account-b');
    await endAccount('account-a');
    held.complete();
    await opening;
    await _settle();

    expect(store.entryKeys, isEmpty);
  });

  test('offline, a kept page that cannot be drawn is not opened', () async {
    await openOnline();
    remote().clear();
    // Page a kept with an agent hydration can't read.
    final broken = agentRow('agent', 'a', revision: 9);
    final payload = Map.of(broken['payload'] as Map<String, Object?>);
    payload['data'] = <String, Object?>{'id': 'agent'};
    await store.writePage(
      _scope,
      'strategy',
      pageAnswer('a', elements: [
        {...broken, 'payload': payload},
      ]),
      askedAt: DateTime.now(),
      arrivedAt: DateTime.now(),
    );

    container.read(_offline.notifier).state = true;
    await remote().openStrategy('strategy', activePagePublicId: 'a');

    // Pages b and c were never read, so nothing of it can open.
    expect(
      container.read(remoteEditorSnapshotProvider).error,
      isA<StrategyNotKeptOffline>(),
    );
  });

  test('without a copy (web), a socket still connecting reads the server',
      () async {
    _webLike = true;
    container.read(_socketDown.notifier).state = true;
    await container.read(remoteEditorSnapshotProvider.future);

    await remote().openStrategy('strategy', activePagePublicId: 'a');

    expect(transport.reads, contains('strategy:getShell'));
    final opened = container.read(remoteEditorSnapshotProvider).valueOrNull!;
    expect(opened.shell.fromCopy, isFalse);
    expect(store.entryKeys, isEmpty);
  });

  test(
      'without a copy (web), selecting a page reads the server even while '
      'the socket reconnects, and a page read still refuses at once', () async {
    _webLike = true;
    await openOnline();
    transport.reads.clear();
    container.read(_socketDown.notifier).state = true;

    await expectLater(remote().fetchPage('b'), throwsStateError);
    expect(transport.reads, isEmpty);

    final b = await remote().setActivePage('b');
    expect(transport.reads, ['page:getSnapshot']);
    expect(b?.page.publicId, 'b');
    expect(b?.fromCopy, isFalse);
  });

  test('without a copy (web), an unanswered read fails as it always has',
      () async {
    _webLike = true;
    transport.unanswered = true;
    await container.read(remoteEditorSnapshotProvider.future);

    await remote().openStrategy('strategy', activePagePublicId: 'a');

    expect(
      container.read(remoteEditorSnapshotProvider).error,
      isA<TimeoutException>(),
    );
  });

  test('back online, the live answer replaces the copy', () async {
    await openOnline();
    remote().clear();
    container.read(_offline.notifier).state = true;
    transport.unanswered = true;
    await remote().openStrategy('strategy', activePagePublicId: 'a');
    expect(
      container.read(remoteEditorSnapshotProvider).valueOrNull!.shell.fromCopy,
      isTrue,
    );

    transport.unanswered = false;
    transport.pageElements['a'] = [agentRow('agent', 'a', revision: 3)];
    container.read(_offline.notifier).state = false;
    await _settle();

    final live = container.read(remoteEditorSnapshotProvider).valueOrNull!;
    expect(live.shell.fromCopy, isFalse);
    expect(live.activePage!.fromCopy, isFalse);
    expect(live.activePage!.elements.single.revision, 3);
  });
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Answers a three-page strategy; page a holds one agent.
final class _Transport implements ConvexTransport {
  final reads = <String>[];
  final pageElements = <String, List<Map<String, Object?>>>{
    'a': [agentRow('agent', 'a')],
  };
  final _pageStreams = <String, StreamController<ConvexValue>>{};
  bool unanswered = false;
  ConvexTransportError? refusal;

  /// While set, reads wait for it before answering.
  Completer<void>? hold;

  void pushPage(String pageId, List<Map<String, Object?>> elements) {
    pageElements[pageId] = elements;
    _pageStreams[pageId]?.add(_page(pageId));
  }

  ConvexObject _page(String pageId) =>
      pageAnswer(pageId, elements: pageElements[pageId] ?? const []);

  ConvexValue _answer(String name, ConvexObject args) {
    if (name == 'strategy:getShell') return shellAnswer(['a', 'b', 'c']);
    if (name == 'page:getSnapshot') {
      return _page(args.value['pagePublicId']!.toDart() as String);
    }
    throw UnimplementedError(name);
  }

  @override
  Future<ConvexValue> query(String name, ConvexObject args) async {
    reads.add(name);
    await hold?.future;
    if (refusal case final error?) throw error;
    if (unanswered) throw TimeoutException('no answer');
    return _answer(name, args);
  }

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) {
    if (name == 'page:getSnapshot') {
      final pageId = args.value['pagePublicId']!.toDart() as String;
      return (_pageStreams[pageId] ??= StreamController.broadcast()).stream;
    }
    return const Stream.empty();
  }

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();
}

class _RecordingRefresher extends StrategyCopyRefresher {
  final kept = <String>[];

  @override
  void build() {}

  @override
  void keepOpenedStrategy(String strategyId) => kept.add(strategyId);
}

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

  /// Signing out: the status says so at once, and the account stays until
  /// the session is gone (see AuthProvider.signOut).
  void startSigningOut() =>
      state = state.copyWith(convexAuthStatus: ConvexAuthStatus.signedOut);

  void signedOutBySupabase() => state = AppAuthState.fromSession(
        null,
        convexAuthStatus: ConvexAuthStatus.signedOut,
      );

  void signBackIn(String accountId) {
    signedOutBySupabase();
    switchTo(accountId);
    state = state.copyWith(
      isAuthenticated: true,
      convexAuthStatus: ConvexAuthStatus.ready,
      isConvexUserReady: true,
    );
  }

  void switchTo(String accountId) => state = state.copyWith(
        user: User(
          id: accountId,
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
}

class _IdleMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() =>
      const CloudMediaUploadQueueState(jobs: [], isProcessing: false);
}
