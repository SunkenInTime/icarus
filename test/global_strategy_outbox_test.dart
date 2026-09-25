import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() {
    appProviderContainer = ProviderContainer();
  });

  tearDownAll(() {
    appProviderContainer.dispose();
  });

  test('restart drains current-account work across closed strategies',
      () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'strategy-one', opId: 'one'));
    await store.put(_record(
      strategyId: 'strategy-two',
      opId: 'two',
      elementId: 'element-two',
    ));
    final repository = _RecordingRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);

    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');

    await _waitUntil(() => repository.calls.length == 2);
    expect(repository.calls.map((call) => call.strategyId).toSet(), {
      'strategy-one',
      'strategy-two',
    });
    expect(store.values, isEmpty);
    expect(
      container.read(strategyOpQueueProvider).accountOutbox.hasWork,
      isFalse,
    );
  });

  test('background drain never submits another account work', () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'strategy-a', opId: 'a'));
    await store.put(_record(
      accountId: 'account-b',
      strategyId: 'strategy-b',
      opId: 'b',
    ));
    final repository = _RecordingRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);

    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setCurrentAccount('account-a');
    await _waitUntil(() => repository.calls.length == 1);

    expect(repository.calls.single.strategyId, 'strategy-a');
    expect(store.values, hasLength(1));
    expect(
      container.read(strategyOpQueueProvider).accountOutbox.accountId,
      'account-a',
    );
    expect(
      container.read(strategyOpQueueProvider).accountOutbox.hasWork,
      isFalse,
    );

    notifier.setCurrentAccount('account-b');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repository.calls, hasLength(1));

    final accountBContainer = _container(
      store: store,
      repository: repository,
      authAccountId: 'account-b',
    );
    addTearDown(accountBContainer.dispose);
    accountBContainer
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-b');
    await _waitUntil(() => repository.calls.length == 2);
    expect(repository.calls.last.strategyId, 'strategy-b');
    expect(store.values, isEmpty);
  });

  test('active work waits for a background request then runs next', () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'closed-strategy', opId: 'closed'));
    final repository = _HeldFirstRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('active-strategy', accountId: 'account-a');
    await repository.firstStarted.future;

    await notifier.enqueue(
      _op(opId: 'active', elementId: 'active-element'),
      flushImmediately: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(repository.calls, hasLength(1));

    repository.releaseFirst();
    await _waitUntil(() => repository.calls.length == 2);
    expect(repository.calls[0].strategyId, 'closed-strategy');
    expect(repository.calls[1].strategyId, 'active-strategy');
    expect(repository.calls[1].ops.single.opId, 'active');
  });

  test('opening a draining strategy preserves a concurrent final intent',
      () async {
    final store = _BlockingSuccessorStore();
    await store.put(_record(strategyId: 'opening', opId: 'predecessor'));
    final repository = _HeldFirstRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setCurrentAccount('account-a');
    await repository.firstStarted.future;

    notifier.setActiveStrategy('opening', accountId: 'account-a');
    final enqueue = notifier.enqueue(
      _op(
        opId: 'final-intent',
        elementId: 'element-one',
        value: 'final',
      ),
    );
    await store.successorWriteStarted.future;
    repository.releaseFirst();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(repository.calls, hasLength(1));

    store.allowSuccessorWrite.complete();
    await enqueue;
    await _waitUntil(() => repository.calls.length == 2);
    final finalOp = repository.calls.last.ops.single as ElementPatchOp;
    expect(finalOp.payload, {'value': 'final'});
    expect(finalOp.expectedElementRevision, 2);
  });

  test('one failed closed strategy does not block another', () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'fails', opId: 'fails'));
    await store.put(_record(
      strategyId: 'lands',
      opId: 'lands',
      elementId: 'element-lands',
    ));
    final repository = _FailFirstRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);

    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');

    await _waitUntil(() => repository.calls.length >= 2);
    expect(repository.calls.take(2).map((call) => call.strategyId), [
      'fails',
      'lands',
    ]);
    expect(
      store.values.values
          .map((value) => DurableOutboxRecord.fromJson(
                Map<String, dynamic>.from(value as Map),
              ))
          .where((record) => record.strategyPublicId == 'fails'),
      isNotEmpty,
    );
  });

  test('paused and rejected records remain visible and never auto-run',
      () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(
      strategyId: 'paused-strategy',
      opId: 'paused',
      status: DurableOutboxStatus.paused,
      lastError: 'Retry limit reached',
    ));
    await store.put(_record(
      strategyId: 'rejected-strategy',
      opId: 'rejected',
      elementId: 'rejected-element',
      status: DurableOutboxStatus.attention,
      lastError: 'Revision conflict',
    ));
    final repository = _RecordingRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);

    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final summary = container.read(strategyOpQueueProvider).accountOutbox;
    expect(repository.calls, isEmpty);
    expect(summary.strategyCount, 2);
    expect(summary.needsAttention, isTrue);
    expect(
        summary.strategies['paused-strategy']!.reason, 'Retry limit reached');
    expect(
        summary.strategies['rejected-strategy']!.reason, 'Revision conflict');
  });

  test('inactive failed writes remain account-visible and unreliable',
      () async {
    final store = _FailingPutStore();
    final repository = _RecordingRepository();
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('failed-strategy', accountId: 'account-a');

    await notifier.enqueue(
      _op(opId: 'failed-write', elementId: 'failed-element'),
      flushImmediately: false,
    );
    notifier.setActiveStrategy('other-strategy', accountId: 'account-a');

    final queue = container.read(strategyOpQueueProvider);
    final failedSummary = queue.accountOutbox.strategies['failed-strategy'];
    expect(queue.strategyPublicId, 'other-strategy');
    expect(queue.outboxIsReliable, isFalse);
    expect(queue.hasDurabilityFailure, isTrue);
    expect(failedSummary, isNotNull);
    expect(failedSummary!.attentionCount, 1);
    expect(failedSummary.queuedCount, 0);
    expect(failedSummary.reason, contains('could not be verified'));
    expect(repository.calls, isEmpty);
  });

  test(
      'inactive legacy oversized work stays byte-for-byte queued until '
      'explicit cloud adoption', () async {
    final store = MemoryDurableStrategyOutboxStore();
    final oversized = _oversizedOp(
      opId: 'legacy-oversized',
      elementId: 'large-element',
    );
    const key = EntitySyncKey.element('page-one', 'large-element');
    final durable = DurableOutboxRecord(
      accountId: 'account-a',
      strategyPublicId: 'legacy-strategy',
      entityKey: key,
      pending: PendingOp(op: oversized, clientId: 'legacy-client'),
      status: DurableOutboxStatus.queued,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );
    await store.put(durable);
    await store.put(_record(
      strategyId: 'unrelated-strategy',
      opId: 'unrelated-paused',
      status: DurableOutboxStatus.paused,
      lastError: 'Retry limit reached',
    ));
    expect(cloudOperationExceedsPolicy(oversized), isTrue);
    final originalBytes = jsonEncode(store.values[durable.storageKey]);
    final repository = _RecordingRepository();
    var container = _container(store: store, repository: repository);
    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    var summary = container
        .read(strategyOpQueueProvider)
        .accountOutbox
        .strategies['legacy-strategy'];
    expect(summary, isNotNull);
    expect(summary!.queuedCount, 0);
    expect(summary.attentionCount, 1);
    expect(summary.reason, cloudOperationTooLargeMessage);
    expect(repository.calls, isEmpty);
    expect(jsonEncode(store.values[durable.storageKey]), originalBytes);
    expect(
      store
          .load()
          .records
          .singleWhere(
            (record) => record.strategyPublicId == 'legacy-strategy',
          )
          .status,
      DurableOutboxStatus.queued,
    );

    container.dispose();
    container = _container(store: store, repository: repository);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setCurrentAccount('account-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    summary = container
        .read(strategyOpQueueProvider)
        .accountOutbox
        .strategies['legacy-strategy'];
    expect(summary!.attentionCount, 1);
    expect(repository.calls, isEmpty);
    expect(jsonEncode(store.values[durable.storageKey]), originalBytes);
    expect(
      store
          .load()
          .records
          .singleWhere(
            (record) => record.strategyPublicId == 'legacy-strategy',
          )
          .status,
      DurableOutboxStatus.queued,
    );

    notifier.setActiveStrategy('legacy-strategy', accountId: 'account-a');
    final active = container.read(strategyOpQueueProvider);
    expect(active.attentionByEntityKey, contains(key));
    expect(active.queuedByEntityKey, isEmpty);

    expect(await notifier.discardRejected({key}), {key});
    expect(
      store.load().records.map((record) => record.pending.op.opId),
      ['unrelated-paused'],
    );
    expect(repository.calls, isEmpty);
  });

  test(
      'reconnection resumes eligible closed-strategy work, following the '
      'real connection snapshot', () async {
    // The snapshot is not overridden: the queue reads the real one, which
    // must follow the connection. It once cached its first read, so work
    // queued while the socket was opening was never sent.
    final connectionChanges = StreamController<bool>();
    addTearDown(connectionChanges.close);
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'offline-strategy', opId: 'offline'));
    final repository = _RecordingRepository();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => _ReadyAuthProvider('account-a')),
      convexConnectionProvider.overrideWith((ref) => connectionChanges.stream),
    ]);
    addTearDown(container.dispose);
    container.listen(convexConnectionProvider, (_, __) {});
    connectionChanges.add(false);
    await Future<void>.delayed(Duration.zero);

    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(container.read(convexConnectionSnapshotProvider), isFalse);
    expect(repository.calls, isEmpty);
    expect(
      container.read(strategyOpQueueProvider).accountOutbox.hasWork,
      isTrue,
    );

    connectionChanges.add(true);
    await _waitUntil(() => repository.calls.length == 1);
    expect(container.read(convexConnectionSnapshotProvider), isTrue);
    expect(store.values, isEmpty);
  });

  test('a batch that fails to send is reported, redacted, to the debug log',
      () async {
    appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'failing-strategy', opId: 'failing'));
    final repository = _ThrowingRepository(StateError(
      'upload to https://bucket.example.com/a.png'
      '?X-Amz-Signature=secret-signature failed',
    ));
    final container = _container(store: store, repository: repository);
    addTearDown(container.dispose);

    container
        .read(strategyOpQueueProvider.notifier)
        .setCurrentAccount('account-a');
    await _waitUntil(
      () => appProviderContainer
          .read(inAppDebugProvider)
          .any((entry) => entry.source == 'cloud_sync.op_queue'),
    );

    final entry = appProviderContainer
        .read(inAppDebugProvider)
        .firstWhere((entry) => entry.source == 'cloud_sync.op_queue');
    expect(entry.level, DebugLogLevel.warning);
    expect(
      entry.message,
      'Cloud sync could not send 1 change(s) for strategy failing-strategy',
    );
    expect(
      entry.errorText,
      'Bad state: upload to https://bucket.example.com/a.png?<redacted> '
      'failed',
    );
    expect(store.values, isNotEmpty);
  });

  group('a strategy deleted on the server', () {
    test('stops retrying and keeps authored changes for discard', () async {
      final store = MemoryDurableStrategyOutboxStore();
      await store.put(_record(strategyId: 'deleted', opId: 'edit'));
      await store.put(_record(strategyId: 'healthy', opId: 'healthy-edit'));
      final repository = _DeletedStrategyRepository({'deleted'});
      final container = _container(store: store, repository: repository);
      addTearDown(container.dispose);

      container
          .read(strategyOpQueueProvider.notifier)
          .setCurrentAccount('account-a');
      await _waitUntil(
        () => container
            .read(strategyOpQueueProvider)
            .accountOutbox
            .deletedStrategies
            .isNotEmpty,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final outbox = container.read(strategyOpQueueProvider).accountOutbox;
      expect(outbox.deletedStrategies, {'deleted': 1});
      // It holds no attention or work for the strategies that still exist.
      expect(outbox.strategies.keys, isNot(contains('deleted')));
      expect(outbox.needsAttention, isFalse);
      expect(outbox.hasWork, isFalse);
      expect(repository.shellChecks, ['deleted']);
      // One send, confirmed deleted: never retried.
      expect(
        repository.calls.where((call) => call.strategyId == 'deleted'),
        hasLength(1),
      );
      final kept = store.load().records.single;
      expect(kept.status, DurableOutboxStatus.attention);
      expect(kept.lastError, cloudStrategyDeletedMessage);

      await container
          .read(strategyOpQueueProvider.notifier)
          .discardDeletedStrategy('deleted');
      expect(store.values, isEmpty);
      expect(
        container.read(strategyOpQueueProvider).accountOutbox.deletedStrategies,
        isEmpty,
      );
    });

    test('drops changes that only remove things from it', () async {
      final store = MemoryDurableStrategyOutboxStore();
      await store.put(_record(
        strategyId: 'deleted',
        opId: 'remove',
        op: const ElementDeleteOp(
          opId: 'remove',
          elementPublicId: 'element-one',
          pagePublicId: 'page-one',
          expectedElementRevision: 1,
        ),
      ));
      final repository = _DeletedStrategyRepository({'deleted'});
      final container = _container(store: store, repository: repository);
      addTearDown(container.dispose);

      container
          .read(strategyOpQueueProvider.notifier)
          .setCurrentAccount('account-a');
      await _waitUntil(() => repository.shellChecks.isNotEmpty);
      await _waitUntil(() => store.values.isEmpty);

      final outbox = container.read(strategyOpQueueProvider).accountOutbox;
      expect(outbox.deletedStrategies, isEmpty);
      expect(outbox.hasWork, isFalse);
    });

    test('NOT_FOUND the server does not confirm is retried as usual', () async {
      final store = MemoryDurableStrategyOutboxStore();
      await store.put(_record(strategyId: 'present', opId: 'edit'));
      // applyBatch says NOT_FOUND, but the strategy's shell still loads.
      final repository = _DeletedStrategyRepository(
        const <String>{},
        notFoundOnSend: {'present'},
      );
      final container = _container(store: store, repository: repository);
      addTearDown(container.dispose);

      container
          .read(strategyOpQueueProvider.notifier)
          .setCurrentAccount('account-a');
      await _waitUntil(() => repository.shellChecks.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final record = store.load().records.single;
      expect(record.lastError, isNot(cloudStrategyDeletedMessage));
      expect(record.status, isNot(DurableOutboxStatus.attention));
      expect(
        container.read(strategyOpQueueProvider).accountOutbox.deletedStrategies,
        isEmpty,
      );
    });
  });

  test('auth readiness recovery resumes eligible closed-strategy work',
      () async {
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(_record(strategyId: 'auth-waiting', opId: 'auth-op'));
    final repository = _RecordingRepository();
    final auth = _MutableAuthProvider();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      convexStrategyRepositoryProvider.overrideWithValue(repository),
      authProvider.overrideWith(() => auth),
      convexConnectionSnapshotProvider.overrideWithValue(true),
      convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
    ]);
    addTearDown(container.dispose);

    container.read(strategyOpQueueProvider);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repository.calls, isEmpty);

    auth.markReady();
    await _waitUntil(() => repository.calls.length == 1);
    expect(repository.calls.single.strategyId, 'auth-waiting');
  });
}

ProviderContainer _container({
  required DurableStrategyOutboxStore store,
  required ConvexStrategyRepository repository,
  bool Function()? connected,
  Stream<bool>? connectionChanges,
  String authAccountId = 'account-a',
}) {
  return ProviderContainer(overrides: [
    durableStrategyOutboxStoreProvider.overrideWithValue(store),
    convexStrategyRepositoryProvider.overrideWithValue(repository),
    authProvider.overrideWith(() => _ReadyAuthProvider(authAccountId)),
    convexConnectionSnapshotProvider.overrideWith(
      (ref) => connected?.call() ?? true,
    ),
    convexConnectionProvider.overrideWith(
      (ref) => connectionChanges ?? Stream<bool>.value(true),
    ),
  ]);
}

DurableOutboxRecord _record({
  String accountId = 'account-a',
  required String strategyId,
  required String opId,
  String elementId = 'element-one',
  DurableOutboxStatus status = DurableOutboxStatus.queued,
  String? lastError,
  StrategyOp? op,
}) {
  final now = DateTime(2026);
  op ??= _op(opId: opId, elementId: elementId);
  return DurableOutboxRecord(
    accountId: accountId,
    strategyPublicId: strategyId,
    entityKey: EntitySyncKey.element('page-one', elementId),
    pending: PendingOp(op: op, clientId: 'client-$strategyId'),
    status: status,
    createdAt: now,
    updatedAt: now,
    lastError: lastError,
  );
}

ElementPatchOp _op({
  required String opId,
  required String elementId,
  String value = 'safe',
}) {
  return ElementPatchOp(
    opId: opId,
    elementPublicId: elementId,
    pagePublicId: 'page-one',
    payload: {'value': value},
    expectedElementRevision: 1,
  );
}

ElementPatchOp _oversizedOp({
  required String opId,
  required String elementId,
}) {
  return ElementPatchOp(
    opId: opId,
    elementPublicId: elementId,
    pagePublicId: 'page-one',
    payload: {
      'kind': 'drawing',
      'payloadVersion': 1,
      'data': {'encodedPoints': List<String>.filled(310000, '界').join()},
    },
    expectedElementRevision: 1,
  );
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached before timeout.');
}

class _ReadyAuthProvider extends AuthProvider {
  _ReadyAuthProvider(this.accountId);

  final String accountId;

  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: accountId,
          appMetadata: const <String, dynamic>{},
          userMetadata: const <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}

class _MutableAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: false,
        convexAuthStatus: ConvexAuthStatus.configuring,
        user: _user('account-a'),
      );

  void markReady() {
    state = AppAuthState(
      isLoading: false,
      isAuthenticated: true,
      isConvexUserReady: true,
      convexAuthStatus: ConvexAuthStatus.ready,
      user: _user('account-a'),
    );
  }
}

User _user(String accountId) => User(
      id: accountId,
      appMetadata: const <String, dynamic>{},
      userMetadata: const <String, dynamic>{},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00.000Z',
    );

typedef _Call = ({String strategyId, List<StrategyOp> ops});

class _FailingPutStore extends MemoryDurableStrategyOutboxStore {
  @override
  Future<void> put(DurableOutboxRecord record) async {
    throw StateError('disk write failed');
  }
}

class _RecordingRepository extends ConvexStrategyRepository {
  _RecordingRepository() : super(IcarusConvexApi(_UnusedTransport()));

  final List<_Call> calls = [];

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add((strategyId: strategyPublicId, ops: List.of(ops)));
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

class _ThrowingRepository extends _RecordingRepository {
  _ThrowingRepository(this.error);

  final Object error;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add((strategyId: strategyPublicId, ops: List.of(ops)));
    throw error;
  }
}

/// applyBatch fails with NOT_FOUND for [deleted] (and [notFoundOnSend]);
/// the shell check confirms only [deleted].
class _DeletedStrategyRepository extends _RecordingRepository {
  _DeletedStrategyRepository(
    this.deleted, {
    Set<String>? notFoundOnSend,
  }) : notFoundOnSend = notFoundOnSend ?? deleted;

  final Set<String> deleted;
  final Set<String> notFoundOnSend;
  final List<String> shellChecks = [];

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    if (!notFoundOnSend.contains(strategyPublicId)) {
      return super.applyBatch(
        strategyPublicId: strategyPublicId,
        clientId: clientId,
        ops: ops,
      );
    }
    calls.add((strategyId: strategyPublicId, ops: List.of(ops)));
    throw ConvexFunctionException(
      code: ConvexErrorCode.notFound,
      rawCode: 'NOT_FOUND',
      message: 'Strategy not found: $strategyPublicId',
    );
  }

  @override
  Future<bool> strategyIsDeleted(String strategyPublicId) async {
    shellChecks.add(strategyPublicId);
    return deleted.contains(strategyPublicId);
  }
}

class _HeldFirstRepository extends _RecordingRepository {
  final firstStarted = Completer<void>();
  final _release = Completer<void>();

  void releaseFirst() => _release.complete();

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add((strategyId: strategyPublicId, ops: List.of(ops)));
    if (calls.length == 1) {
      firstStarted.complete();
      await _release.future;
    }
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

class _FailFirstRepository extends _RecordingRepository {
  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add((strategyId: strategyPublicId, ops: List.of(ops)));
    if (calls.length == 1) throw StateError('temporary failure');
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

class _BlockingSuccessorStore extends MemoryDurableStrategyOutboxStore {
  final successorWriteStarted = Completer<void>();
  final allowSuccessorWrite = Completer<void>();
  var _blocked = false;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    if (!_blocked && record.successorPending != null) {
      _blocked = true;
      successorWriteStarted.complete();
      await allowSuccessorWrite.future;
    }
    await super.put(record);
  }
}

class _UnusedTransport implements ConvexTransport {
  @override
  Future<ConvexValue> action(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> mutation(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Future<ConvexValue> query(String name, ConvexObject args) =>
      throw UnimplementedError();

  @override
  Stream<ConvexValue> subscribe(String name, ConvexObject args) =>
      throw UnimplementedError();
}
