import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late _GatedStore store;
  late StrategyOpQueueNotifier queue;

  setUp(() {
    store = _GatedStore();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      convexStrategyRepositoryProvider.overrideWithValue(_Offline()),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      convexConnectionSnapshotProvider.overrideWithValue(false),
      convexConnectionProvider.overrideWith((ref) => Stream.value(false)),
    ]);
    addTearDown(container.dispose);
    queue = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-a', accountId: 'account-a');
  });

  Map<String, List<String>> storedByStrategy() {
    final stored = <String, List<String>>{};
    for (final record in store.load().records) {
      (stored[record.strategyPublicId] ??= []).add(record.pending.op.opId);
    }
    return stored;
  }

  Future<void> earlierWriteHeldWhile(Future<void> Function() edit) async {
    final held = store.holdNextPut();
    final earlier = queue.enqueue(
        const ElementAddOp(
          opId: 'earlier',
          elementPublicId: 'element-earlier',
          pagePublicId: 'page-a',
          payload: {'value': 'a'},
          sortIndex: 0,
        ),
        strategyPublicId: 'strategy-a');
    await held.reached;
    final editing = edit();
    queue.setActiveStrategy('strategy-b', accountId: 'account-a');
    held.release();
    await earlier;
    await editing;
  }

  test(
      'a map change made in one strategy while another write waits its turn '
      'is stored under that strategy, not the one opened next', () async {
    await earlierWriteHeldWhile(() => queue.syncDesiredGenericOp(
          strategyPublicId: 'strategy-a',
          entityKey: const EntitySyncKey.strategy(),
          desiredOp: const StrategyPatchOp(
            opId: 'map-to-lotus',
            expectedStrategyRevision: 1,
            payload: {'mapData': 'lotus'},
          ),
        ));

    expect(storedByStrategy(), {
      'strategy-a': unorderedEquals(['earlier', 'map-to-lotus']),
    });
  });

  test(
      'a page edit made in one strategy while another write waits its turn '
      'is stored under that strategy, not the one opened next', () async {
    await earlierWriteHeldWhile(() => queue.syncDesiredOpsForPage(
          strategyPublicId: 'strategy-a',
          pageId: 'page-a',
          clearMissing: false,
          desiredOpsByEntityKey: {
            const EntitySyncKey.element('page-a', 'element-edited'):
                const ElementAddOp(
              opId: 'page-edit',
              elementPublicId: 'element-edited',
              pagePublicId: 'page-a',
              payload: {'value': 'b'},
              sortIndex: 1,
            ),
          },
        ));

    expect(storedByStrategy(), {
      'strategy-a': unorderedEquals(['earlier', 'page-edit']),
    });
  });
  test(
      'a change stored under a strategy that is no longer active is the '
      'record a released build writes and reads', () async {
    await earlierWriteHeldWhile(() => queue.syncDesiredGenericOp(
          strategyPublicId: 'strategy-a',
          entityKey: const EntitySyncKey.strategy(),
          desiredOp: const StrategyPatchOp(
            opId: 'map-to-lotus',
            expectedStrategyRevision: 1,
            payload: {'mapData': 'lotus'},
          ),
        ));

    final stored = Map<String, dynamic>.from(store.values.values
        .map((value) => Map<String, dynamic>.from(value as Map))
        .firstWhere((json) => json['opId'] == 'map-to-lotus'));
    expect(stored.keys.toSet(), {
      'outboxVersion',
      'accountId',
      'strategyPublicId',
      'entityKey',
      'clientId',
      'opId',
      'op',
      'attempts',
      'status',
      'createdAt',
      'updatedAt',
    });
    expect(stored['outboxVersion'], 2);
    expect(stored['accountId'], 'account-a');
    expect(stored['strategyPublicId'], 'strategy-a');
    expect(stored['entityKey'], const EntitySyncKey.strategy().toString());
    expect(stored['status'], 'queued');
    expect(
      stored['op'],
      const StrategyPatchOp(
        opId: 'map-to-lotus',
        expectedStrategyRevision: 1,
        payload: {'mapData': 'lotus'},
      ).toConvexJson(),
    );
    expect(DurableOutboxRecord.fromJson(stored).strategyPublicId, 'strategy-a');
  });

  test(
      'a record a released build wrote for a strategy that is not active '
      'loads under that strategy', () async {
    final released = <String, Object?>{
      'outboxVersion': 2,
      'accountId': 'account-a',
      'strategyPublicId': 'strategy-a',
      'entityKey': const EntitySyncKey.strategy().toString(),
      'clientId': 'released-client',
      'opId': 'released-patch',
      'op': const StrategyPatchOp(
        opId: 'released-patch',
        expectedStrategyRevision: 3,
        payload: {'mapData': 'bind'},
      ).toConvexJson(),
      'attempts': 0,
      'status': 'queued',
      'createdAt': '2026-11-01T10:00:00.000Z',
      'updatedAt': '2026-11-01T10:00:00.000Z',
    };
    final storageKey = DurableOutboxRecord.fromJson(
      Map<String, dynamic>.from(released),
    ).storageKey;
    final reopened = _GatedStore()..values[storageKey] = released;
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(reopened),
      convexStrategyRepositoryProvider.overrideWithValue(_Offline()),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      convexConnectionSnapshotProvider.overrideWithValue(false),
      convexConnectionProvider.overrideWith((ref) => Stream.value(false)),
    ]);
    addTearDown(container.dispose);
    final reopenedQueue = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-b', accountId: 'account-a');
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    expect(
      container.read(strategyOpQueueProvider).accountOutbox.strategies.keys,
      contains('strategy-a'),
    );

    reopenedQueue.setActiveStrategy('strategy-a', accountId: 'account-a');
    expect(
      [
        for (final pending in container.read(strategyOpQueueProvider).pending)
          pending.op.opId,
      ],
      ['released-patch'],
    );
  });
}

final class _GatedStore extends MemoryDurableStrategyOutboxStore {
  _HeldPut? _held;

  _HeldPut holdNextPut() => _held = _HeldPut();

  @override
  Future<void> put(DurableOutboxRecord record) async {
    final held = _held;
    if (held != null) {
      _held = null;
      held._reached.complete();
      await held._release.future;
    }
    return super.put(record);
  }
}

final class _HeldPut {
  final _reached = Completer<void>();
  final _release = Completer<void>();

  Future<void> get reached => _reached.future;
  void release() => _release.complete();
}

final class _Offline extends ConvexStrategyRepository {
  _Offline() : super(IcarusConvexApi(_NoTransport()));
}

final class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
}
