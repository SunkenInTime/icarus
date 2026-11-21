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
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Map<String, dynamic> agent(String position) => {
        'kind': 'agent',
        'payloadVersion': 1,
        'data': {'id': 'agent-1', 'position': position},
      };

  const delete = ElementDeleteOp(
    opId: 'delete',
    elementPublicId: 'agent-1',
    pagePublicId: 'page-1',
    expectedElementRevision: 1,
  );

  ElementPatchOp putBack(String position) => ElementPatchOp(
        opId: 'put-back',
        elementPublicId: 'agent-1',
        pagePublicId: 'page-1',
        payload: agent(position),
        sortIndex: 0,
        expectedElementRevision: 1,
        merge: const FieldMerge(fields: ['position'], base: {'position': 'A'}),
      );

  test(
      'an item put back after its delete landed, before the canvas heard, '
      'comes back', () async {
    final server = _Server(row: agent('A'));
    final (container, queue) = _start(server);

    await queue.enqueue(delete);
    await queue.flushNow();
    expect(server.deleted, isTrue);

    await queue.enqueue(putBack('B'));
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.deleted, isFalse);
    expect(server.row, agent('B'));
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('an item put back while its delete is being sent comes back', () async {
    final server = _Server(row: agent('A'));
    final (container, queue) = _start(server);

    await queue.enqueue(delete);
    server.holdAnswers = true;
    unawaited(queue.flushNow());
    await server.reached.future;
    await queue.enqueue(putBack('B'));
    server.release();
    await _until(() => server.received.length == 2);
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.deleted, isFalse);
    expect(server.row, agent('B'));
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });
}

(ProviderContainer, StrategyOpQueueNotifier) _start(_Server server) {
  final container = ProviderContainer(overrides: [
    durableStrategyOutboxStoreProvider
        .overrideWithValue(MemoryDurableStrategyOutboxStore()),
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

final class _Server extends ConvexStrategyRepository {
  _Server({required this.row}) : super(IcarusConvexApi(_NoTransport()));

  Map<String, dynamic> row;
  bool deleted = false;
  int _revision = 1;
  bool holdAnswers = false;
  final reached = Completer<void>();
  final _release = Completer<void>();
  final List<StrategyOp> received = [];
  final List<String> refused = [];

  void release() => _release.complete();

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    received.addAll(ops);
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

    OpAck write(Map<String, dynamic> next, {required bool isDeleted}) {
      row = next;
      deleted = isDeleted;
      _revision += 1;
      return AppliedOpAck(opId: op.opId, revision: _revision);
    }

    switch (op) {
      case ElementDeleteOp(:final expectedElementRevision):
        if (deleted)
          return NoopOpAck(opId: op.opId, currentRevision: _revision);
        if (expectedElementRevision != _revision) {
          return refuse(OpRejectionReason.revisionMismatch);
        }
        return write(row, isDeleted: true);
      case ElementAddOp(:final payload, :final expectedElementRevision):
        if (!deleted) return refuse(OpRejectionReason.alreadyExists);
        if (expectedElementRevision != _revision) {
          return refuse(OpRejectionReason.revisionMismatch);
        }
        return write(payload, isDeleted: false);
      case ElementPatchOp(:final payload?, :final merge):
        if (deleted) return refuse(OpRejectionReason.deleted);
        final data = Map<String, dynamic>.from(row['data'] as Map);
        final wanted = payload['data'] as Map;
        for (final field in merge?.fields ?? const <String>[]) {
          data[field] = wanted[field];
        }
        return write({...row, 'data': data}, isDeleted: false);
      default:
        throw UnsupportedError('${op.runtimeType}');
    }
  }
}

final class _NoTransport implements ConvexTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: User(
          id: 'account-a',
          appMetadata: <String, dynamic>{},
          userMetadata: <String, dynamic>{},
          aud: 'authenticated',
          createdAt: '2026-01-01T00:00:00.000Z',
        ),
      );
}
