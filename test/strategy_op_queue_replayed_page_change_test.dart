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

// A change to the strategy's revision (a page added, a rename) is sent, the
// server applies it, and its answer is lost. The user makes another such
// change against the revision they saw. When the first is sent again, the
// server answers it as a replay of a write it applied: the second change
// must move onto the revision that write made and land, not be refused as a
// conflict with the user's own work.
void main() {
  const addPage = PageAddOp(
    opId: 'add-page',
    pagePublicId: 'page-2',
    payload: {'name': 'Retake', 'isAttack': false},
    sortIndex: 1,
    expectedStrategyRevision: 5,
  );
  const rename = StrategyPatchOp(
    opId: 'rename',
    payload: {'name': 'Offline name'},
    expectedStrategyRevision: 5,
  );

  test('a rename made after a lost page add lands once the add is resent',
      () async {
    final server = _Server();
    final (container, queue) = _start(server);

    await queue.enqueuePageChange(addPage);
    server.loseNextAnswer = true;
    await queue.flushNow();
    expect(server.revision, 6, reason: 'the server added the page');

    await queue.enqueue(rename);
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.name, 'Offline name');
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('a rename waits for a lost page add even behind a page rename',
      () async {
    final server = _Server();
    final (container, queue) = _start(server);

    await queue.enqueuePageChange(addPage);
    server.loseNextAnswer = true;
    await queue.flushNow();

    // Offline, the user renames another page and the strategy. The page
    // rename goes before the add is sent again, and the strategy rename
    // must not go with it.
    await queue.enqueuePageChange(const PagePatchOp(
      opId: 'rename-page',
      pagePublicId: 'page-1',
      payload: {'name': 'Defaults'},
      expectedPageRevision: 1,
    ));
    await queue.enqueue(rename);
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.name, 'Offline name');
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('a rename made while a lost page add is paused lands after Retry',
      () async {
    final server = _Server();
    server.appliedEarlier(addPage);
    // Every answer to the add was lost and it paused; the server has it.
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(DurableOutboxRecord(
      accountId: 'account-a',
      strategyPublicId: 'strategy-1',
      entityKey: const EntitySyncKey.pageChange('add'),
      pending: PendingOp(
        op: addPage,
        clientId: 'client-a',
        attempts: 8,
        lastAttemptAt: DateTime(2026),
      ),
      status: DurableOutboxStatus.paused,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      pageChangeSequence: 1,
    ));
    final (container, queue) = _start(server, store: store);

    await queue.enqueue(rename);
    await queue.flushNow();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.refused, isEmpty, reason: 'the rename waits for the add');

    await queue.retryPaused();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.name, 'Offline name');
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('a page rename after a lost rename of that page lands', () async {
    final server = _Server();
    final (container, queue) = _start(server);
    PagePatchOp renamePage(String opId, String name) => PagePatchOp(
          opId: opId,
          pagePublicId: 'page-1',
          payload: {'name': name},
          expectedPageRevision: 1,
        );

    await queue.enqueuePageChange(renamePage('first', 'Defaults'));
    server.loseNextAnswer = true;
    await queue.flushNow();
    expect(server.pageName, 'Defaults', reason: 'the server renamed it');

    await queue.enqueuePageChange(renamePage('second', 'Retakes'));
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.pageName, 'Retakes');
  });

  test('a page added after a lost rename lands once the rename is resent',
      () async {
    final server = _Server();
    final (container, queue) = _start(server);

    await queue.enqueue(rename);
    server.loseNextAnswer = true;
    await queue.flushNow();
    expect(server.name, 'Offline name', reason: 'the server renamed it');

    await queue.enqueuePageChange(addPage);
    await queue.flushNow();
    await _until(() => container.read(strategyOpQueueProvider).pending.isEmpty);

    expect(server.refused, isEmpty);
    expect(server.pages, contains('page-2'));
    expect(container.read(strategyOpQueueProvider).needsAttention, isFalse);
  });

  test('a replay that made no write of its own moves nothing', () async {
    final server = _Server()..appliedReplays = false;
    final (container, queue) = _start(server);

    await queue.enqueuePageChange(addPage);
    server.loseNextAnswer = true;
    await queue.flushNow();
    await queue.enqueue(rename);
    await queue.flushNow();
    await _until(
      () => container.read(strategyOpQueueProvider).needsAttention,
    );

    // The queue can't tell revision 6 is its own, so the rename is checked
    // against the revision the user saw, and the user is asked.
    expect(server.refused, ['rename']);
    expect(server.name, 'Base');
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

/// A strategy at revision 5, answered as convex/ops.ts answers: each change
/// is checked against the strategy's revision, and a known op ID is
/// replayed as a noop at the revision it made, saying it was applied
/// ([appliedReplays], as to a client that sends includeWasApplied).
final class _Server extends ConvexStrategyRepository {
  _Server() : super(IcarusConvexApi(_NoTransport()));

  int revision = 5;
  String name = 'Base';
  final Set<String> pages = {'page-1'};
  bool loseNextAnswer = false;
  bool appliedReplays = true;
  String pageName = 'Page 1';
  int _pageRevision = 1;

  /// [op] reached the server and was applied before the test starts.
  void appliedEarlier(StrategyOp op) => _apply(op);
  final Map<String, int> _landed = {};
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
    if (_landed[op.opId] case final landed?) {
      return NoopOpAck(
        opId: op.opId,
        currentRevision: landed,
        wasApplied: appliedReplays,
      );
    }
    if (op is PagePatchOp) {
      if (op.expectedPageRevision != _pageRevision) {
        refused.add(op.opId);
        return RejectedOpAck(
          opId: op.opId,
          rejectionReason: OpRejectionReason.revisionMismatch,
        );
      }
      pageName = op.payload['name'] as String? ?? pageName;
      _pageRevision += 1;
      _landed[op.opId] = _pageRevision;
      return AppliedOpAck(opId: op.opId, revision: _pageRevision);
    }
    if (op.expectedRevision != revision) {
      refused.add(op.opId);
      return RejectedOpAck(
        opId: op.opId,
        rejectionReason: OpRejectionReason.revisionMismatch,
      );
    }
    switch (op) {
      case PageAddOp(:final pagePublicId):
        pages.add(pagePublicId);
      case StrategyPatchOp(:final payload):
        name = payload['name'] as String;
      default:
        throw UnimplementedError('${op.type}');
    }
    revision += 1;
    _landed[op.opId] = revision;
    return AppliedOpAck(opId: op.opId, revision: revision);
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
