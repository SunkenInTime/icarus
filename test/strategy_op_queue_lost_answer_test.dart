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

// The network drops while a batch is being sent: the server applied it, but
// its answer never reached the app. The user keeps editing the same item
// before the batch is sent again. The edit must land, and nothing may ask
// the user about a conflict with their own earlier change.
void main() {
  const key = EntitySyncKey.element('page-1', 'element-1');

  Map<String, dynamic> text(String value) => {
        'kind': 'text',
        'payloadVersion': 1,
        'data': {'id': 'element-1', 'text': value},
      };

  /// A patch of the text from [from] to [to], merged by field, as live sync
  /// makes it against the version it last saw ([revision]).
  ElementPatchOp patch(String opId, String from, String to, int revision) =>
      ElementPatchOp(
        opId: opId,
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: text(to),
        sortIndex: 0,
        expectedElementRevision: revision,
        merge: FieldMerge(fields: const ['text'], base: {'text': from}),
      );

  test('an edit after a lost accept lands behind the resent op', () async {
    final server = _Server(row: text('a'));
    final (container, queue) = _start(server);

    await queue.enqueue(patch('first', 'a', 'b', 1));
    server.loseNextAnswer = true;
    await queue.flushNow();
    expect(server.row, text('b'), reason: 'the server applied it');

    // Offline, the canvas still knows the element at revision 1, holding a.
    await queue.syncDesiredOpsForPage(
      pageId: 'page-1',
      desiredOpsByEntityKey: {key: patch('second', 'a', 'c', 1)},
    );
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    final queueState = container.read(strategyOpQueueProvider);
    expect(queueState.attentionByEntityKey, isEmpty);
    expect(queueState.needsAttention, isFalse);
    expect(server.row, text('c'));
    expect(server.refused, isEmpty);
    // The op whose answer was lost went again as it was.
    expect(server.received.where((op) => op == 'first'), hasLength(2));
  });

  test('an edit after a restart with a send in flight lands behind it',
      () async {
    final server = _Server(row: text('a'));
    // The app closed while patch first was being sent; the server had
    // applied it.
    final first = patch('first', 'a', 'b', 1);
    server.appliedEarlier(first);
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(DurableOutboxRecord(
      accountId: 'account-a',
      strategyPublicId: 'strategy-1',
      entityKey: key,
      pending: PendingOp(op: first, clientId: 'client-a'),
      status: DurableOutboxStatus.inFlight,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ));
    final (container, queue) = _start(server, store: store);

    // Reopened, the canvas still shows the element as the user left it at
    // revision 1 holding a (the live read has not come), and the user
    // edits it before the queue sends first again.
    await queue.syncDesiredOpsForPage(
      pageId: 'page-1',
      desiredOpsByEntityKey: {key: patch('second', 'a', 'c', 1)},
    );
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.row, text('c'));
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('a delete after Retry on a lost add that paused is not dropped',
      () async {
    final server = _Server();
    final add = ElementAddOp(
      opId: 'add',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: text('a'),
      sortIndex: 0,
    );
    // Every answer to the add was lost and it paused; the server has it.
    server.appliedEarlier(add);
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(DurableOutboxRecord(
      accountId: 'account-a',
      strategyPublicId: 'strategy-1',
      entityKey: key,
      pending: PendingOp(
        op: add,
        clientId: 'client-a',
        attempts: 8,
        lastAttemptAt: DateTime(2026),
      ),
      status: DurableOutboxStatus.paused,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ));
    final (container, queue) = _start(server, store: store);

    await queue.retryPaused(flushImmediately: false);
    await queue.syncDesiredOpsForPage(
      pageId: 'page-1',
      desiredOpsByEntityKey: {
        key: const ElementDeleteOp(
          opId: 'delete',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          expectedElementRevision: 0,
        ),
      },
    );
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.deleted, isTrue);
    expect(server.refused, isEmpty);
  });

  test('a delete after a lost add is not dropped with the add', () async {
    final server = _Server();
    final (container, queue) = _start(server);

    await queue.enqueue(ElementAddOp(
      opId: 'add',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: text('a'),
      sortIndex: 0,
    ));
    server.loseNextAnswer = true;
    await queue.flushNow();
    expect(server.row, text('a'), reason: 'the server added it');

    await queue.syncDesiredOpsForPage(
      pageId: 'page-1',
      desiredOpsByEntityKey: {
        key: const ElementDeleteOp(
          opId: 'delete',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          expectedElementRevision: 0,
        ),
      },
    );
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
    expect(server.deleted, isTrue);
    expect(server.refused, isEmpty);
  });
}

(ProviderContainer, StrategyOpQueueNotifier) _start(
  _Server server, {
  DurableStrategyOutboxStore? store,
}) {
  final container = ProviderContainer(overrides: [
    durableStrategyOutboxStoreProvider.overrideWithValue(
      store ?? MemoryDurableStrategyOutboxStore(),
    ),
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

/// One element row, answered as convex/ops.ts answers: a known op id is
/// replayed as a noop at the revision it landed at, a whole write is checked
/// against the row's revision, and a merge against its base.
final class _Server extends ConvexStrategyRepository {
  _Server({Map<String, dynamic>? row})
      : row = row,
        _revision = row == null ? 0 : 1,
        super(IcarusConvexApi(_NoTransport()));

  Map<String, dynamic>? row;
  bool deleted = false;

  /// [op] reached the server and was applied before the test starts.
  void appliedEarlier(StrategyOp op) => _apply(op);

  int _revision;
  bool loseNextAnswer = false;
  final Map<String, int> _landed = {};
  final List<String> received = [];
  final List<String> refused = [];

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    final acks = [for (final op in ops) _apply(op)];
    if (loseNextAnswer) {
      loseNextAnswer = false;
      throw StateError('The connection dropped before the answer came');
    }
    return acks;
  }

  OpAck _apply(StrategyOp op) {
    received.add(op.opId);
    if (_landed[op.opId] case final revision?) {
      return NoopOpAck(opId: op.opId, currentRevision: revision);
    }
    OpAck refuse(OpRejectionReason reason) {
      refused.add(op.opId);
      return RejectedOpAck(opId: op.opId, rejectionReason: reason);
    }

    switch (op) {
      case ElementAddOp(:final payload):
        if (row != null && !deleted) {
          return refuse(OpRejectionReason.alreadyExists);
        }
        row = Map<String, dynamic>.from(payload);
        deleted = false;
      case ElementPatchOp(:final payload, :final merge):
        if (row == null || deleted) return refuse(OpRejectionReason.deleted);
        if (merge == null) {
          if (op.expectedElementRevision != _revision) {
            return refuse(OpRejectionReason.revisionMismatch);
          }
          row = Map<String, dynamic>.from(payload!);
        } else {
          final data = Map<String, dynamic>.from(row!['data'] as Map);
          final wanted = payload!['data'] as Map;
          for (final field in merge.fields) {
            final base = merge.base;
            if (base != null &&
                data[field] != base[field] &&
                data[field] != wanted[field]) {
              return refuse(OpRejectionReason.fieldConflict);
            }
          }
          for (final field in merge.fields) {
            data[field] = wanted[field];
          }
          row = {...row!, 'data': data};
        }
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
    _landed[op.opId] = _revision;
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
