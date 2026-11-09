import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Live sync diffs an edit against the version of the item it last heard
// the server held, and the queue takes it in turn behind whatever it is
// writing. An edit made while the queue stores the answer to this device's
// own earlier edit is diffed against the version before that edit, so it
// leaves out a field the earlier edit changed and the user has since set
// back. Taken as it is, it replaced the change queued behind the earlier
// edit and dropped that field: the server kept the earlier value while the
// chip said synced.
void main() {
  Map<String, dynamic> agent(String position, String weapon) => {
        'kind': 'agent',
        'payloadVersion': 1,
        'data': {'id': 'agent-1', 'position': position, 'weapon': weapon},
      };

  /// An edit as live sync makes it: merged by the [fields] that differ from
  /// [base], the version at [revision].
  ElementPatchOp edit(
    String opId,
    Map<String, dynamic> payload, {
    required Map<String, Object?> base,
    required int revision,
  }) =>
      ElementPatchOp(
        opId: opId,
        elementPublicId: 'agent-1',
        pagePublicId: 'page-1',
        payload: payload,
        sortIndex: 0,
        expectedElementRevision: revision,
        merge: FieldMerge(fields: base.keys.toList(), base: base),
      );

  test('a delete made against what the user saw is checked against it',
      () async {
    final server = _Server(row: agent('A', 'none'));
    // Saved before a restart, never drawn by this canvas: a whole write.
    final (container, queue) = _startRecovered(
      server,
      ElementPatchOp(
        opId: 'recovered',
        elementPublicId: 'agent-1',
        pagePublicId: 'page-1',
        payload: agent('C', 'none'),
        sortIndex: 0,
        expectedElementRevision: 1,
      ),
    );
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);
    expect(server.row, agent('C', 'none'));

    // The canvas still shows revision 1, and the user deletes the agent.
    await queue.enqueue(const ElementDeleteOp(
      opId: 'delete',
      elementPublicId: 'agent-1',
      pagePublicId: 'page-1',
      expectedElementRevision: 1,
    ));
    await queue.flushNow();
    await _until(
      () => container.read(strategyOpQueueProvider).needsAttention,
    );

    // The server holds work the user never saw: they are asked, and the
    // agent stays.
    expect(server.refused, ['delete']);
    expect(server.deleted, isFalse);
  });

  test('an edit made while an answer is stored keeps the queued field',
      () async {
    final store = _HoldPromotion();
    final server = _Server(row: agent('A', 'none'));
    final (container, queue) = _start(store, server);

    // The user moves the agent to B; the move is sent and held there.
    await queue.enqueue(
      edit('move', agent('B', 'none'), base: {'position': 'A'}, revision: 1),
    );
    server.holdAnswers = true;
    unawaited(queue.flushNow());
    await server.reached.future;
    // While it is sent, the user moves it back to A and changes the weapon.
    // Against revision 1 (position A), only the weapon changed.
    await queue.enqueue(edit(
      'back',
      agent('A', 'ghost'),
      base: {'weapon': 'none'},
      revision: 1,
    ));
    // The move lands. While the queue stores that answer, the user changes
    // the weapon again; the canvas still knows only revision 1.
    server.release();
    await store.promotionStarted.future;
    final again = queue.enqueue(edit(
      'again',
      agent('A', 'vandal'),
      base: {'weapon': 'none'},
      revision: 1,
    ));
    store.releasePromotion.complete();
    await again;
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.row, agent('A', 'vandal'));
    expect(server.refused, isEmpty);
  });
}

(ProviderContainer, StrategyOpQueueNotifier) _startRecovered(
  _Server server,
  StrategyOp recovered,
) {
  final store = MemoryDurableStrategyOutboxStore();
  unawaited(store.put(DurableOutboxRecord(
    accountId: 'account-a',
    strategyPublicId: 'strategy-1',
    entityKey: const EntitySyncKey.element('page-1', 'agent-1'),
    pending: PendingOp(op: recovered, clientId: 'client-a'),
    status: DurableOutboxStatus.queued,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  )));
  return _start(store, server);
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

/// Holds the write that promotes the change waiting behind an answered op
/// (its record's op changes and the successor goes) until
/// [releasePromotion].
final class _HoldPromotion extends MemoryDurableStrategyOutboxStore {
  final promotionStarted = Completer<void>();
  final releasePromotion = Completer<void>();

  @override
  Future<void> put(DurableOutboxRecord record) async {
    final promotes = record.successorPending == null &&
        record.status == DurableOutboxStatus.queued &&
        values.isNotEmpty &&
        !promotionStarted.isCompleted &&
        record.pending.op.opId != 'move' &&
        record.pending.op.opId != 'back';
    if (promotes) {
      promotionStarted.complete();
      await releasePromotion.future;
    }
    await super.put(record);
  }
}

/// One element row, answered as convex/ops.ts answers a merge: only the
/// merge's fields are written, each checked against its base.
final class _Server extends ConvexStrategyRepository {
  _Server({required this.row}) : super(IcarusConvexApi(_NoTransport()));

  Map<String, dynamic> row;
  bool deleted = false;
  int _revision = 1;
  bool holdAnswers = false;
  final reached = Completer<void>();
  final _release = Completer<void>();
  final List<String> refused = [];

  void release() => _release.complete();

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    final acks = [for (final op in ops) _apply(op)];
    if (holdAnswers) {
      holdAnswers = false;
      reached.complete();
      await _release.future;
    }
    return acks;
  }

  OpAck _apply(StrategyOp op) {
    OpAck refuse(OpRejectionReason reason) {
      refused.add(op.opId);
      return RejectedOpAck(opId: op.opId, rejectionReason: reason);
    }

    if (op is ElementDeleteOp) {
      if (op.expectedElementRevision != _revision) {
        return refuse(OpRejectionReason.revisionMismatch);
      }
      deleted = true;
      _revision += 1;
      return AppliedOpAck(opId: op.opId, revision: _revision);
    }
    op as ElementPatchOp;
    final merge = op.merge;
    if (merge == null) {
      if (op.expectedElementRevision != _revision) {
        return refuse(OpRejectionReason.revisionMismatch);
      }
      row = Map<String, dynamic>.from(op.payload!);
      _revision += 1;
      return AppliedOpAck(opId: op.opId, revision: _revision);
    }
    final data = Map<String, dynamic>.from(row['data'] as Map);
    final wanted = op.payload!['data'] as Map;
    for (final field in merge.fields) {
      final base = merge.base;
      if (base != null &&
          data[field] != base[field] &&
          data[field] != wanted[field]) {
        refused.add(op.opId);
        return RejectedOpAck(
          opId: op.opId,
          rejectionReason: OpRejectionReason.fieldConflict,
        );
      }
    }
    for (final field in merge.fields) {
      data[field] = wanted[field];
    }
    row = {...row, 'data': data};
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
