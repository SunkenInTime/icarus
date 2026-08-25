import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

void main() {
  group('Entity sync revision domains', () {
    test('page descriptor and page content cannot coalesce together', () {
      const descriptor = EntitySyncKey.pageDescriptor('page:1');
      const content = EntitySyncKey.pageContent('page:1');
      expect(descriptor, isNot(content));
      expect(descriptor.kind, EntitySyncKeyKind.pageDescriptor);
      expect(content.kind, EntitySyncKeyKind.pageContent);
      expect(
        descriptor.overlayType,
        ActivePageOverlayEntityType.pageDescriptor,
      );
      expect(content.overlayType, ActivePageOverlayEntityType.pageContent);
      expect(descriptor.toString(), 'page:page%3A1:descriptor');
    });
  });

  group('durable strategy outbox', () {
    late MemoryDurableStrategyOutboxStore store;
    ProviderContainer? container;

    StrategyOpQueueNotifier start({
      String? accountId = 'account-a',
      String? strategyId = 'strategy-1',
    }) {
      container?.dispose();
      container = ProviderContainer(overrides: [
        durableStrategyOutboxStoreProvider.overrideWithValue(store),
      ]);
      container!
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(true);
      final notifier = container!.read(strategyOpQueueProvider.notifier);
      notifier.setActiveStrategy(strategyId, accountId: accountId);
      return notifier;
    }

    StrategyOp elementOp({
      String opId = 'op-1',
      String elementId = 'element-1',
      String value = 'a',
      StrategyOpKind kind = StrategyOpKind.patch,
    }) {
      return StrategyOp(
        opId: opId,
        kind: kind,
        entityType: StrategyOpEntityType.element,
        entityPublicId: elementId,
        pagePublicId: 'page-1',
        payload: {'value': value},
        sortIndex: 0,
        expectedRevision: kind == StrategyOpKind.add ? null : 1,
      );
    }

    DurableOutboxRecord record({
      required DurableOutboxStatus status,
      String accountId = 'account-a',
      String strategyId = 'strategy-1',
      String opId = 'op-1',
      int attempts = 0,
    }) {
      final op = elementOp(opId: opId);
      return DurableOutboxRecord(
        accountId: accountId,
        strategyPublicId: strategyId,
        entityKey: const EntitySyncKey.element('page-1', 'element-1'),
        pending: PendingOp(
          op: op,
          clientId: 'stable-client',
          attempts: attempts,
        ),
        status: status,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
    }

    setUp(() => store = MemoryDurableStrategyOutboxStore());
    tearDown(() => container?.dispose());

    test('restart after enqueue and before send restores the intent', () async {
      final notifier = start();
      await notifier.enqueue(elementOp(), flushImmediately: false);
      expect(store.values, hasLength(1));

      start();
      final restored = container!.read(strategyOpQueueProvider);
      expect(restored.pending, hasLength(1));
      expect(restored.pending.single.op.opId, 'op-1');
      expect(restored.pending.single.clientId, isNotEmpty);
    });

    test('restart while in flight replays the same event key', () async {
      final saved = record(status: DurableOutboxStatus.inFlight);
      await store.put(saved);
      start();

      final restored = container!.read(strategyOpQueueProvider);
      expect(restored.queuedByEntityKey, hasLength(1));
      expect(restored.inFlightByEntityKey, isEmpty);
      expect(restored.pending.single.op.opId, 'op-1');
      expect(restored.pending.single.clientId, 'stable-client');
    });

    test('server-accepted crash window retains the exact op for replay',
        () async {
      final saved =
          record(status: DurableOutboxStatus.inFlight, opId: 'accepted');
      await store.put(saved);
      start();
      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, 'accepted');
      expect(pending.clientId, 'stable-client');
    });

    test('strategy switch retains another page pending op', () async {
      final notifier = start();
      await notifier.enqueue(elementOp());
      notifier.setActiveStrategy('strategy-2', accountId: 'account-a');
      expect(container!.read(strategyOpQueueProvider).pending, isEmpty);
      notifier.setActiveStrategy('strategy-1', accountId: 'account-a');
      expect(container!.read(strategyOpQueueProvider).pending, hasLength(1));
    });

    test('sign-out and same-account recovery restores work', () async {
      final notifier = start();
      await notifier.enqueue(elementOp());
      notifier.setActiveStrategy(null, accountId: null);
      expect(container!.read(strategyOpQueueProvider).pending, isEmpty);
      notifier.setActiveStrategy('strategy-1', accountId: 'account-a');
      expect(container!.read(strategyOpQueueProvider).pending, hasLength(1));
    });

    test('different account cannot see or submit saved work', () async {
      final notifier = start();
      await notifier.enqueue(elementOp());
      notifier.setActiveStrategy('strategy-1', accountId: 'account-b');
      expect(container!.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, hasLength(1));
    });

    test('retry exhaustion is paused and manual retry keeps identity',
        () async {
      final saved = record(
        status: DurableOutboxStatus.paused,
        attempts: 8,
      );
      await store.put(saved);
      final notifier = start();
      expect(container!.read(strategyOpQueueProvider).needsAttention, isTrue);
      expect(container!.read(strategyOpQueueProvider).pausedByEntityKey,
          hasLength(1));

      await notifier.retryPaused(flushImmediately: false);
      final retried = container!.read(strategyOpQueueProvider);
      expect(retried.pausedByEntityKey, isEmpty);
      expect(retried.queuedByEntityKey, hasLength(1));
      expect(retried.pending.single.op.opId, 'op-1');
      expect(retried.pending.single.clientId, 'stable-client');
    });

    test('corrupt persisted record produces attention and remains present', () {
      store.values['broken'] = {'outboxVersion': 999};
      start();
      final loaded = container!.read(strategyOpQueueProvider);
      expect(loaded.durableLoaded, isTrue);
      expect(loaded.needsAttention, isTrue);
      expect(loaded.loadIssues.single.storageKey, 'broken');
      expect(store.values, contains('broken'));
    });

    test('reconciliation replaces rejected immutable opId before removal',
        () async {
      final saved = record(status: DurableOutboxStatus.attention);
      await store.put(saved);
      final notifier = start();
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          const EntitySyncKey.element('page-1', 'element-1'):
              elementOp(opId: 'replacement', value: 'new'),
        },
        flushImmediately: false,
      );
      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.queuedByEntityKey.values.single.pending.op.opId,
          'replacement');
      expect(
        (store.values.values.single as Map)['opId'],
        'replacement',
      );
    });

    test('ordinary reconciliation does not discard attention work', () async {
      final saved = record(status: DurableOutboxStatus.attention);
      await store.put(saved);
      final notifier = start();
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: const {},
        flushImmediately: false,
      );
      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, hasLength(1));
      expect(store.values, hasLength(1));
    });

    test('explicit rejected retry uses durable latest server revision',
        () async {
      final saved = record(status: DurableOutboxStatus.attention).copyWith(
        latestServerRevision: 7,
      );
      await store.put(saved);
      final notifier = start();
      await notifier.retryRejected(flushImmediately: false);

      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.queuedByEntityKey, hasLength(1));
      final retried = current.queuedByEntityKey.values.single.pending;
      expect(retried.op.opId, isNot('op-1'));
      expect(retried.op.expectedRevision, 7);
      expect(retried.attempts, 0);
      final durable = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durable.status, DurableOutboxStatus.queued);
      expect(durable.latestServerRevision, isNull);
      expect(durable.pending.op.opId, retried.op.opId);
    });

    test('explicit rejected retry falls back to the original revision',
        () async {
      await store.put(record(status: DurableOutboxStatus.attention));
      final notifier = start();
      await notifier.retryRejected(flushImmediately: false);

      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      final retried = current.queuedByEntityKey.values.single.pending;
      expect(retried.op.opId, isNot('op-1'));
      expect(retried.op.expectedRevision, 1);
    });

    test('explicit rejected retry explains when no revision is available',
        () async {
      final saved = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: const EntitySyncKey.element('page-1', 'element-1'),
        pending: PendingOp(
          op: elementOp(kind: StrategyOpKind.add),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await store.put(saved);
      final notifier = start();
      await notifier.retryRejected(flushImmediately: false);

      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, hasLength(1));
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.lastError, contains('cannot be retried automatically'));
    });

    test('coalesces add and patch only after durable replacement', () async {
      final notifier = start();
      await notifier.enqueue(elementOp(kind: StrategyOpKind.add));
      await notifier.enqueue(elementOp(opId: 'patch', value: 'b'));
      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.kind, StrategyOpKind.add);
      expect(pending.op.opId, 'op-1');
      expect(pending.op.payload, {'value': 'b'});
      expect(store.values, hasLength(1));
    });
  });

  test('provider state waits for durable persistence before showing Syncing',
      () async {
    final store = _BlockingStore();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-1', accountId: 'account-a');
    container
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    final enqueue = notifier.enqueue(const StrategyOp(
      opId: 'op-1',
      kind: StrategyOpKind.patch,
      entityType: StrategyOpEntityType.element,
      entityPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: {'value': 'safe'},
      expectedRevision: 1,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    store.allowWrite.complete();
    await enqueue;
    expect(container.read(strategyOpQueueProvider).pending, hasLength(1));
  });
}

class _BlockingStore extends MemoryDurableStrategyOutboxStore {
  final allowWrite = Completer<void>();

  @override
  Future<void> put(DurableOutboxRecord record) async {
    await allowWrite.future;
    await super.put(record);
  }
}
