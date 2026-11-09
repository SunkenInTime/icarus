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

// Live sync makes an op from what it knows the server holds, and the queue
// takes it in turn behind whatever it is writing. An edit made while the
// queue stores the answer to an item's add is still made as an add: the
// canvas has not heard that the add landed. Taken as new work after the add,
// the server refuses it (already_exists) and the user's edit sits in Sync
// needs attention. It must land as an edit of the added item.
void main() {
  ElementAddOp add(String opId, String value, {int? expectedRevision}) =>
      ElementAddOp(
        opId: opId,
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': value},
        sortIndex: 0,
        expectedElementRevision: expectedRevision,
      );

  test('an edit made while the answer to its add is stored lands as an edit',
      () async {
    final store = _HoldFirstRemove();
    final server = _Server();
    final (container, queue) = _start(store, server);

    await queue.enqueue(add('add', 'a'));
    final flushing = queue.flushNow();
    await store.removeStarted.future;
    // The server answered the add, and the queue is storing that answer.
    // The user moves the item; the canvas still knows no row for it.
    final editing = queue.enqueue(add('edit', 'b'));
    store.releaseRemove.complete();
    await flushing;
    await editing;
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
    expect(server.row, {'value': 'b'});
    expect(server.received, ['element.add', 'element.patch']);
  });

  test('an item a teammate deleted and the user brings back is added again',
      () async {
    final server = _Server();
    final (container, queue) =
        _start(MemoryDurableStrategyOutboxStore(), server);

    await queue.enqueue(add('add', 'a'));
    await queue.flushNow();
    // A teammate deletes it (revision 2); this device's queue still
    // remembers its own add at 1. The canvas reads the delete and the user
    // brings the item back over it.
    server.teammateDeletes();
    await queue.enqueue(add('again', 'c', expectedRevision: 2));
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.row, {'value': 'c'});
    expect(server.deleted, isFalse);
  });

  test('an item deleted and drawn again is added again', () async {
    final server = _Server();
    final (container, queue) =
        _start(MemoryDurableStrategyOutboxStore(), server);

    await queue.enqueue(add('add', 'a'));
    await queue.flushNow();
    await queue.enqueue(const ElementDeleteOp(
      opId: 'delete',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      expectedElementRevision: 1,
    ));
    await queue.flushNow();
    // The canvas knows the delete landed at 2, and the user brings it back.
    await queue.enqueue(add('again', 'c', expectedRevision: 2));
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.row, {'value': 'c'});
    expect(server.deleted, isFalse);
    expect(server.received, ['element.add', 'element.delete', 'element.add']);
  });
}

(ProviderContainer, StrategyOpQueueNotifier) _start(
  DurableStrategyOutboxStore store,
  _Server server,
) {
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
  return (container, queue);
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i += 1) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'still waiting after 3 s');
}

/// Holds the first record removal (an answered op leaving the outbox) until
/// [releaseRemove].
final class _HoldFirstRemove extends MemoryDurableStrategyOutboxStore {
  final removeStarted = Completer<void>();
  final releaseRemove = Completer<void>();

  @override
  Future<void> remove(String storageKey) async {
    if (!removeStarted.isCompleted) {
      removeStarted.complete();
      await releaseRemove.future;
    }
    await super.remove(storageKey);
  }
}

/// One element row, answered as convex/ops.ts answers whole writes: an add
/// of a row that exists is refused, a patch or delete is checked against
/// the row's revision, and an add over a deleted row against its tombstone.
final class _Server extends ConvexStrategyRepository {
  _Server() : super(IcarusConvexApi(_NoTransport()));

  Map<String, dynamic>? row;
  bool deleted = false;
  int _revision = 0;
  final List<String> received = [];

  void teammateDeletes() {
    deleted = true;
    _revision += 1;
  }

  final List<String> refused = [];

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async =>
      [for (final op in ops) _apply(op)];

  OpAck _apply(StrategyOp op) {
    received.add(op.type.wireName);
    OpAck refuse(OpRejectionReason reason) {
      refused.add('${op.type.wireName} ${reason.wireName}');
      return RejectedOpAck(opId: op.opId, rejectionReason: reason);
    }

    switch (op) {
      case ElementAddOp(:final payload):
        if (row != null && !deleted) {
          return refuse(OpRejectionReason.alreadyExists);
        }
        if (row != null && op.expectedElementRevision != _revision) {
          return refuse(OpRejectionReason.revisionMismatch);
        }
        row = Map<String, dynamic>.from(payload);
        deleted = false;
      case ElementPatchOp(:final payload):
        if (row == null || deleted) return refuse(OpRejectionReason.deleted);
        if (op.expectedElementRevision != _revision) {
          return refuse(OpRejectionReason.revisionMismatch);
        }
        row = Map<String, dynamic>.from(payload!);
      case ElementDeleteOp():
        if (row == null || deleted) return refuse(OpRejectionReason.deleted);
        if (op.expectedElementRevision != _revision) {
          return refuse(OpRejectionReason.revisionMismatch);
        }
        deleted = true;
      default:
        throw UnimplementedError('${op.type}');
    }
    _revision += 1;
    return AppliedOpAck(opId: op.opId, revision: _revision);
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
