import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // The queue claims a batch (marks its records in flight, one Hive write
  // each) before it shows them as being sent. An edit made during those
  // writes waits for them, then runs before the queue shows the claim: it
  // must still see its item's op as sent, and wait behind it.
  test('an edit made while a batch is being claimed waits behind the sent op',
      () async {
    final store = _GatedStore();
    final server = _Server();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
      convexStrategyRepositoryProvider.overrideWithValue(server),
      authProvider.overrideWith(_ReadyAuthProvider.new),
      convexConnectionSnapshotProvider.overrideWithValue(true),
      convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
    ]);
    addTearDown(container.dispose);
    final queue = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-1', accountId: 'account-a');

    await queue.enqueue(const ElementAddOp(
      opId: 'add',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: {'value': 'a'},
      sortIndex: 0,
    ));
    final claimWrite = store.holdNextPut();
    final flushing = queue.flushNow();
    await claimWrite.reached;
    // The user deletes the element while the add is being claimed.
    final deleting = queue.enqueue(const ElementDeleteOp(
      opId: 'delete',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      expectedElementRevision: 0,
    ));
    claimWrite.release();
    await flushing;
    await deleting;

    for (var i = 0; i < 100 && server.sent.length < 2; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(server.sent, ['element.add', 'element.delete']);
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    expect(store.values, isEmpty);
  });
}

/// Holds one put until released, to stop the queue in the middle of a
/// claim.
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

/// Accepts every op.
final class _Server extends ConvexStrategyRepository {
  _Server() : super(IcarusConvexApi(_NoTransport()));

  final List<String> sent = [];
  int _revision = 0;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    sent.addAll(ops.map((op) => op.type.wireName));
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: ++_revision),
    ];
  }
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
