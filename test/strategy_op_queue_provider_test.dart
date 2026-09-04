import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
      return switch (kind) {
        StrategyOpKind.add => ElementAddOp(
            opId: opId,
            elementPublicId: elementId,
            pagePublicId: 'page-1',
            payload: {'value': value},
            sortIndex: 0,
          ),
        StrategyOpKind.patch => ElementPatchOp(
            opId: opId,
            elementPublicId: elementId,
            pagePublicId: 'page-1',
            payload: {'value': value},
            sortIndex: 0,
            expectedElementRevision: 1,
          ),
        StrategyOpKind.delete => ElementDeleteOp(
            opId: opId,
            elementPublicId: elementId,
            pagePublicId: 'page-1',
            expectedElementRevision: 1,
          ),
        StrategyOpKind.reorder => ElementReorderOp(
            opId: opId,
            elementPublicId: elementId,
            pagePublicId: 'page-1',
            sortIndex: 0,
            expectedElementRevision: 1,
          ),
      };
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

    test('page descriptor mutation survives restart in the durable outbox',
        () async {
      final notifier = start();
      await notifier.enqueue(
        const PageAddOp(
          opId: 'add-page',
          pagePublicId: 'page-2',
          payload: {
            'name': 'Execute',
            'isAttack': true,
            'settings': {
              'agentSize': 1.0,
              'abilitySize': 1.0,
              'useNeutralTeamColors': false,
            },
          },
          sortIndex: 1,
          expectedStrategyRevision: 4,
        ),
        flushImmediately: false,
      );
      expect(store.values, hasLength(1));

      start();

      final restored = container!.read(strategyOpQueueProvider);
      expect(restored.pending, hasLength(1));
      final intent = restored.queuedByEntityKey.entries.single;
      expect(intent.key, const EntitySyncKey.pageDescriptor('page-2'));
      expect(intent.value.pending.op.opId, 'add-page');
      expect(intent.value.pending.op.kind, StrategyOpKind.add);
      expect(intent.value.pending.op.expectedRevision, 4);
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

    test('protocol-v2 outbox records fail closed instead of converting', () {
      final legacy = record(status: DurableOutboxStatus.queued).toJson()
        ..['outboxVersion'] = 1;

      expect(
        () => DurableOutboxRecord.fromJson(legacy),
        throwsA(isA<FormatException>()),
      );
    });

    test('reconciliation retains rejected work and updates its successor',
        () async {
      final saved = record(status: DurableOutboxStatus.attention).copyWith(
        latestServerRevision: 7,
        lastError: 'revision_mismatch',
      );
      await store.put(saved);
      var notifier = start();
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          const EntitySyncKey.element('page-1', 'element-1'):
              elementOp(opId: 'replacement', value: 'new'),
        },
        flushImmediately: false,
      );
      var current = container!.read(strategyOpQueueProvider);
      expect(
          current.attentionByEntityKey.values.single.pending.op.opId, 'op-1');
      expect(current.queuedByEntityKey, isEmpty);
      expect(
        current.successorByEntityKey.values.single.pending.op.payload,
        {'value': 'new'},
      );

      notifier = start();
      current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, hasLength(1));
      expect(current.successorByEntityKey, hasLength(1));
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          const EntitySyncKey.element('page-1', 'element-1'):
              elementOp(opId: 'newer-replacement', value: 'newest'),
        },
        flushImmediately: false,
      );

      current = container!.read(strategyOpQueueProvider);
      expect(
          current.attentionByEntityKey.values.single.pending.op.opId, 'op-1');
      expect(current.queuedByEntityKey, isEmpty);
      expect(
        current.successorByEntityKey.values.single.pending.op.payload,
        {'value': 'newest'},
      );
      var durable = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.opId, 'op-1');
      expect(durable.successorPending!.op.payload, {'value': 'newest'});
      expect(durable.latestServerRevision, 7);
      expect(durable.lastError, 'revision_mismatch');

      await notifier.retryRejected(flushImmediately: false);
      current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.successorByEntityKey, isEmpty);
      final retry = current.queuedByEntityKey.values.single.pending.op;
      expect(retry.opId, isNot(anyOf('op-1', 'newer-replacement')));
      expect(retry.payload, {'value': 'newest'});
      expect(retry.expectedRevision, 7);
      durable = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durable.status, DurableOutboxStatus.queued);
      expect(durable.successorPending, isNull);
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

    test(
        'cloud adoption discards only selected rejected work and survives restart',
        () async {
      const selectedKey = EntitySyncKey.element('page-1', 'element-1');
      const otherAttentionKey =
          EntitySyncKey.element('page-1', 'element-2');
      const queuedKey = EntitySyncKey.element('page-1', 'element-3');
      final selected = record(status: DurableOutboxStatus.attention).copyWith(
        successorPending: PendingOp(
          op: elementOp(
            opId: 'selected-successor',
            value: 'newer local intent',
          ),
          clientId: 'stable-client',
        ),
        latestServerRevision: 7,
      );
      final otherAttention = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: otherAttentionKey,
        pending: PendingOp(
          op: elementOp(opId: 'other-rejected', elementId: 'element-2'),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        latestServerRevision: 4,
      );
      final queued = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: queuedKey,
        pending: PendingOp(
          op: elementOp(opId: 'unrelated-queued', elementId: 'element-3'),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      final otherStrategy = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-2',
        entityKey: selectedKey,
        pending: PendingOp(
          op: elementOp(opId: 'other-strategy'),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await store.put(selected);
      await store.put(otherAttention);
      await store.put(queued);
      await store.put(otherStrategy);
      var notifier = start();

      final discarded = await notifier.discardRejected({selectedKey});

      expect(discarded, {selectedKey});
      var current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(otherAttentionKey));
      expect(current.attentionByEntityKey, isNot(contains(selectedKey)));
      expect(current.successorByEntityKey, isEmpty);
      expect(current.queuedByEntityKey, contains(queuedKey));
      expect(
        store.load().records.map((record) => record.pending.op.opId),
        containsAll(<String>[
          'other-rejected',
          'unrelated-queued',
          'other-strategy',
        ]),
      );
      expect(
        store.load().records.map((record) => record.pending.op.opId),
        isNot(contains('op-1')),
      );
      expect(
        store.load().records
            .expand((record) => <String>[
                  record.pending.op.opId,
                  if (record.successorPending != null)
                    record.successorPending!.op.opId,
                ]),
        isNot(contains('selected-successor')),
      );

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          selectedKey: elementOp(opId: 'stale-reconciliation'),
        },
        clearMissing: false,
        flushImmediately: false,
      );
      expect(
        container!.read(strategyOpQueueProvider).queuedByEntityKey,
        isNot(contains(selectedKey)),
      );

      notifier = start();
      current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(otherAttentionKey));
      expect(current.attentionByEntityKey, isNot(contains(selectedKey)));
      expect(current.queuedByEntityKey, contains(queuedKey));
      expect(current.pending.map((pending) => pending.op.opId),
          isNot(contains('selected-successor')));

      notifier.setActiveStrategy('strategy-2', accountId: 'account-a');
      expect(
        container!
            .read(strategyOpQueueProvider)
            .attentionByEntityKey[selectedKey]!
            .pending
            .op
            .opId,
        'other-strategy',
      );
    });

    test('partial cloud adoption leaves a failed durable delete in attention',
        () async {
      const firstKey = EntitySyncKey.element('page-1', 'element-1');
      const secondKey = EntitySyncKey.element('page-1', 'element-2');
      final failingStore = _FailingSelectedRemovalStore();
      store = failingStore;
      await store.put(record(status: DurableOutboxStatus.attention));
      final second = DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: secondKey,
        pending: PendingOp(
          op: elementOp(opId: 'second', elementId: 'element-2'),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );
      await store.put(second);
      failingStore.failStorageKey = second.storageKey;
      final notifier = start();

      final discarded = await notifier.discardRejected({firstKey, secondKey});

      expect(discarded, {firstKey});
      final current = container!.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(secondKey));
      expect(current.attentionByEntityKey, isNot(contains(firstKey)));
      expect(current.lastError, contains('could not be removed'));
      expect(
        store.load().records.map((record) => record.entityKey),
        unorderedEquals([secondKey]),
      );
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

    test('explicit rejected retry preserves a tombstone restore add', () async {
      const key = EntitySyncKey.element('page-1', 'element-1');
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: key,
        pending: const PendingOp(
          op: ElementAddOp(
            opId: 'restore-op',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {'value': 'restore me'},
            sortIndex: 0,
            expectedElementRevision: 2,
          ),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastError: 'revision_mismatch',
        latestServerRevision: 3,
      ));
      final notifier = start();
      await notifier.retryRejected(flushImmediately: false);

      final retried = container!
          .read(strategyOpQueueProvider)
          .queuedByEntityKey[key]!
          .pending
          .op;
      expect(retried.opId, isNot('restore-op'));
      expect(retried.kind, StrategyOpKind.add);
      expect(retried.expectedRevision, 3);
    });

    test('explicit rejected retry converts an active add collision to patch',
        () async {
      const key = EntitySyncKey.element('page-1', 'element-1');
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: key,
        pending: PendingOp(
          op: elementOp(kind: StrategyOpKind.add),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.attention,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastError: 'already_exists',
        latestServerRevision: 2,
      ));
      final notifier = start();
      await notifier.retryRejected(flushImmediately: false);

      final retried = container!
          .read(strategyOpQueueProvider)
          .queuedByEntityKey[key]!
          .pending
          .op;
      expect(retried.kind, StrategyOpKind.patch);
      expect(retried.expectedRevision, 2);
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
      expect(pending.op.opId, isNot(anyOf('op-1', 'patch')));
      expect(pending.op.payload, {'value': 'b'});
      expect(store.values, hasLength(1));
      expect((store.values.values.single as Map)['opId'], pending.op.opId);
    });

    test('byte-for-byte equivalent work keeps its durable op ID', () async {
      final notifier = start();
      await notifier.enqueue(elementOp(), flushImmediately: false);
      await notifier.enqueue(
        elementOp(opId: 'unused-equivalent-id'),
        flushImmediately: false,
      );

      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, 'op-1');
      expect((store.values.values.single as Map)['opId'], 'op-1');
    });

    test('patch replacement gets a new durable op ID', () async {
      final notifier = start();
      await notifier.enqueue(elementOp(), flushImmediately: false);
      await notifier.enqueue(
        elementOp(opId: 'desired-patch', value: 'b'),
        flushImmediately: false,
      );

      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, isNot(anyOf('op-1', 'desired-patch')));
      expect(pending.op.payload, {'value': 'b'});
      expect((store.values.values.single as Map)['opId'], pending.op.opId);
    });

    test('reorder replacement gets a new durable op ID', () async {
      final notifier = start();
      const first = PageReorderOp(
        opId: 'reorder-a',
        pagePublicId: 'page-1',
        sortIndex: 1,
        expectedStrategyRevision: 2,
      );
      const second = PageReorderOp(
        opId: 'reorder-b',
        pagePublicId: 'page-1',
        sortIndex: 3,
        expectedStrategyRevision: 2,
      );
      await notifier.enqueue(first, flushImmediately: false);
      await notifier.enqueue(second, flushImmediately: false);

      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, isNot(anyOf('reorder-a', 'reorder-b')));
      expect(pending.op.sortIndex, 3);
    });

    test('delete cancels a queued add and removes its durable record',
        () async {
      final notifier = start();
      await notifier.enqueue(
        elementOp(kind: StrategyOpKind.add),
        flushImmediately: false,
      );
      await notifier.enqueue(
        elementOp(opId: 'delete', kind: StrategyOpKind.delete),
        flushImmediately: false,
      );

      expect(container!.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, isEmpty);
    });

    test('restoring after a queued delete creates new immutable work',
        () async {
      final notifier = start();
      await notifier.enqueue(
        elementOp(opId: 'delete', kind: StrategyOpKind.delete),
        flushImmediately: false,
      );
      await notifier.enqueue(
        elementOp(opId: 'restore', kind: StrategyOpKind.add, value: 'restored'),
        flushImmediately: false,
      );

      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, isNot(anyOf('delete', 'restore')));
      expect(pending.op.kind, StrategyOpKind.add);
      expect(pending.op.payload, {'value': 'restored'});
    });

    test('lost response then new work cannot replay the applied op ID',
        () async {
      await store.put(
        record(status: DurableOutboxStatus.inFlight, opId: 'applied-a'),
      );
      final notifier = start();

      await notifier.enqueue(
        elementOp(opId: 'work-b', value: 'b'),
        flushImmediately: false,
      );

      final pending = container!.read(strategyOpQueueProvider).pending.single;
      expect(pending.op.opId, isNot(anyOf('applied-a', 'work-b')));
      expect(pending.op.payload, {'value': 'b'});
      final durable = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durable.pending.op.opId, pending.op.opId);
      expect(durable.pending.op.payload, {'value': 'b'});
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
    final enqueue = notifier.enqueue(const ElementPatchOp(
      opId: 'op-1',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: {'value': 'safe'},
      expectedElementRevision: 1,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    store.allowWrite.complete();
    await enqueue;
    expect(container.read(strategyOpQueueProvider).pending, hasLength(1));
  });

  test('replacement stays hidden until the durable record is written',
      () async {
    final store = _BlockingReplacementStore();
    final container = ProviderContainer(overrides: [
      durableStrategyOutboxStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-1', accountId: 'account-a');
    container
        .read(cloudCollabModeProvider.notifier)
        .setForceLocalFallback(true);
    const first = ElementPatchOp(
      opId: 'first',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: {'value': 'a'},
      expectedElementRevision: 1,
    );
    const desired = ElementPatchOp(
      opId: 'desired',
      elementPublicId: 'element-1',
      pagePublicId: 'page-1',
      payload: {'value': 'b'},
      expectedElementRevision: 1,
    );
    await notifier.enqueue(first, flushImmediately: false);

    final replacement = notifier.enqueue(desired, flushImmediately: false);
    await Future<void>.delayed(Duration.zero);
    final beforeWrite = container.read(strategyOpQueueProvider).pending.single;
    expect(beforeWrite.op.opId, 'first');
    expect(beforeWrite.op.payload, {'value': 'a'});

    store.allowReplacement.complete();
    await replacement;
    final afterWrite = container.read(strategyOpQueueProvider).pending.single;
    expect(afterWrite.op.opId, isNot(anyOf('first', 'desired')));
    expect(afterWrite.op.payload, {'value': 'b'});
  });

  test('cloud adoption leaves unrelated in-flight work untouched', () async {
    const rejectedKey = EntitySyncKey.element('page-1', 'element-1');
    final store = MemoryDurableStrategyOutboxStore();
    await store.put(DurableOutboxRecord(
      accountId: 'account-a',
      strategyPublicId: 'strategy-1',
      entityKey: rejectedKey,
      pending: const PendingOp(
        op: ElementPatchOp(
          opId: 'rejected',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {'value': 'mine'},
          expectedElementRevision: 1,
        ),
        clientId: 'stable-client',
      ),
      status: DurableOutboxStatus.attention,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ));
    final repository = _SequencedAckRepository();
    final container = _cloudQueueContainer(
      store: store,
      repository: repository,
    );
    addTearDown(container.dispose);
    final notifier = container.read(strategyOpQueueProvider.notifier)
      ..setActiveStrategy('strategy-1', accountId: 'account-a');
    const inFlightKey = EntitySyncKey.element('page-1', 'element-2');
    await notifier.enqueue(const ElementPatchOp(
      opId: 'unrelated-in-flight',
      elementPublicId: 'element-2',
      pagePublicId: 'page-1',
      payload: {'value': 'other'},
      expectedElementRevision: 1,
    ));
    final flush = notifier.flushNow();
    await repository.firstStarted.future;

    final discarded = await notifier.discardRejected({rejectedKey});

    expect(discarded, {rejectedKey});
    expect(
      container.read(strategyOpQueueProvider).inFlightByEntityKey,
      contains(inFlightKey),
    );
    repository.completeFirst(const AppliedOpAck(
      opId: 'unrelated-in-flight',
      revision: 2,
    ));
    await flush;
  });

  group('cloud payload policy', () {
    test('serialized operation size counts Unicode UTF-8 bytes', () {
      final op = _largeElementPatch(
        opId: 'unicode-size',
        elementId: 'element-unicode',
        value: _repeat('界', 3),
      );
      final serialized = jsonEncode(op.toConvexJson());

      expect(
        serializedCloudOperationUtf8Bytes(op),
        utf8.encode(serialized).length,
      );
      expect(utf8.encode(serialized).length, greaterThan(serialized.length));
    });

    test(
        'an initial durable enqueue failure stays unreliable until the exact '
        'record is rewritten', () async {
      final store = _FirstPutFailureStore();
      final container = _cloudQueueContainer(
        store: store,
        repository: _RecordingAckRepository(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const op = ElementPatchOp(
        opId: 'initial-write-failure',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'unsaved'},
        expectedElementRevision: 1,
      );
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(op, flushImmediately: false);

      var current = container.read(strategyOpQueueProvider);
      expect(current.pending, isEmpty);
      expect(current.hasDurabilityFailure, isTrue);
      expect(current.needsAttention, isTrue);
      expect(current.outboxIsReliable, isFalse);
      expect(current.lastError, contains('could not be saved'));
      expect(store.values, isEmpty);

      await notifier.enqueue(op, flushImmediately: false);

      current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, contains(key));
      expect(current.hasDurabilityFailure, isFalse);
      expect(current.outboxIsReliable, isTrue);
      expect(current.lastError, isNull);
      expect(store.load().records.single.pending.op.opId, op.opId);
    });

    test('an oversized op is durably parked while independent work lands',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _RecordingAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      container
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(true);
      final oversized = _largeElementPatch(
        opId: 'oversized',
        elementId: 'element-large',
      );
      const valid = ElementPatchOp(
        opId: 'independent',
        elementPublicId: 'element-small',
        pagePublicId: 'page-1',
        payload: {'value': 'safe'},
        expectedElementRevision: 1,
      );
      expect(
        serializedCloudOperationUtf8Bytes(oversized),
        greaterThan(maxCloudOperationBytes),
      );
      await notifier.enqueue(oversized, flushImmediately: false);
      await notifier.enqueue(valid, flushImmediately: false);
      container
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(false);

      await notifier.flushNow();

      expect(repository.calls, hasLength(1));
      expect(repository.calls.single.map((op) => op.opId), ['independent']);
      var current = container.read(strategyOpQueueProvider);
      const oversizedKey =
          EntitySyncKey.element('page-1', 'element-large');
      expect(current.attentionByEntityKey, contains(oversizedKey));
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.lastError, cloudOperationTooLargeMessage);
      var durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.opId, 'oversized');
      expect(durable.lastError, cloudOperationTooLargeMessage);

      container.dispose();
      repository.calls.clear();
      container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.flushNow();

      current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(oversizedKey));
      expect(current.lastError, cloudOperationTooLargeMessage);
      expect(repository.calls, isEmpty);
      durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.opId, 'oversized');
    });

    test('an over-wide array is parked before independent transport',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      final wide = ElementPatchOp(
        opId: 'wide-array',
        elementPublicId: 'element-wide',
        pagePublicId: 'page-1',
        payload: {
          'kind': 'drawing',
          'payloadVersion': 1,
          'data': {'points': List<int>.filled(maxCloudArrayEntries + 1, 0)},
        },
        expectedElementRevision: 1,
      );
      expect(
        serializedCloudOperationUtf8Bytes(wide),
        lessThan(maxCloudOperationBytes),
      );
      expect(cloudOperationExceedsPolicy(wide), isTrue);
      await notifier.enqueue(wide, flushImmediately: false);
      await notifier.enqueue(
        const ElementPatchOp(
          opId: 'wide-array-sibling',
          elementPublicId: 'element-small',
          pagePublicId: 'page-1',
          payload: {'value': 'safe'},
          expectedElementRevision: 1,
        ),
        flushImmediately: false,
      );

      await notifier.flushNow();

      expect(repository.calls, hasLength(1));
      expect(repository.calls.single.map((op) => op.opId), [
        'wide-array-sibling',
      ]);
      expect(
        container.read(strategyOpQueueProvider).attentionByEntityKey,
        contains(const EntitySyncKey.element('page-1', 'element-wide')),
      );
      expect(store.load().records.single.lastError,
          cloudOperationTooLargeMessage);
    });

    test('a failed oversized parking write blocks all transport and retries',
        () async {
      final store = _OversizedParkingFailureStore();
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(
        _largeElementPatch(
          opId: 'oversized-write-failure',
          elementId: 'element-large',
        ),
        flushImmediately: false,
      );
      await notifier.enqueue(
        const ElementPatchOp(
          opId: 'independent-after-write-failure',
          elementPublicId: 'element-small',
          pagePublicId: 'page-1',
          payload: {'value': 'safe'},
          expectedElementRevision: 1,
        ),
        flushImmediately: false,
      );

      await notifier.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final current = container.read(strategyOpQueueProvider);
      expect(repository.calls, isEmpty);
      expect(current.outboxIsReliable, isFalse);
      expect(current.hasDurabilityFailure, isTrue);
      expect(
        current.attentionByEntityKey,
        contains(const EntitySyncKey.element('page-1', 'element-large')),
      );
      expect(
        current.queuedByEntityKey,
        contains(const EntitySyncKey.element('page-1', 'element-small')),
      );
      expect(current.lastError, contains('Nothing was sent'));
      expect(store.attentionWrites, 1);
    });

    test('a missing durable oversized record blocks all transport', () async {
      final store = _OversizedParkingFailureStore(dropBeforeThrow: true);
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(
        _largeElementPatch(
          opId: 'oversized-missing-record',
          elementId: 'element-large',
        ),
        flushImmediately: false,
      );
      await notifier.enqueue(
        const ElementPatchOp(
          opId: 'independent-after-missing-record',
          elementPublicId: 'element-small',
          pagePublicId: 'page-1',
          payload: {'value': 'safe'},
          expectedElementRevision: 1,
        ),
        flushImmediately: false,
      );

      await notifier.flushNow();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final current = container.read(strategyOpQueueProvider);
      expect(repository.calls, isEmpty);
      expect(current.outboxIsReliable, isFalse);
      expect(current.hasDurabilityFailure, isTrue);
      expect(
        current.attentionByEntityKey,
        contains(const EntitySyncKey.element('page-1', 'element-large')),
      );
      expect(
        current.queuedByEntityKey,
        contains(const EntitySyncKey.element('page-1', 'element-small')),
      );
      expect(current.lastError, contains('Nothing was sent'));
      expect(
        store.load().records.map((record) => record.pending.op.opId),
        isNot(contains('oversized-missing-record')),
      );
      expect(store.attentionWrites, 1);
    });

    for (final dropBeforeThrow in <bool>[false, true]) {
      test(
          'Use cloud clears uncertain oversized work when the parking '
          '${dropBeforeThrow ? 'record is missing' : 'write failed'}',
          () async {
        final store = _OversizedParkingFailureStore(
          dropBeforeThrow: dropBeforeThrow,
        );
        final container = _cloudQueueContainer(
          store: store,
          repository: _RecordingAckRepository(),
        );
        addTearDown(container.dispose);
        final notifier = container.read(strategyOpQueueProvider.notifier)
          ..setActiveStrategy('strategy-1', accountId: 'account-a');
        const key = EntitySyncKey.element('page-1', 'element-large');
        await notifier.enqueue(
          _largeElementPatch(
            opId: 'oversized-explicit-discard',
            elementId: 'element-large',
          ),
          flushImmediately: false,
        );
        await notifier.flushNow();

        var current = container.read(strategyOpQueueProvider);
        expect(current.attentionByEntityKey, contains(key));
        expect(current.hasDurabilityFailure, isTrue);
        expect(current.outboxIsReliable, isFalse);
        expect(
          store.load().records.isEmpty,
          dropBeforeThrow,
        );

        final discarded = await notifier.discardRejected({key});

        expect(discarded, {key});
        current = container.read(strategyOpQueueProvider);
        expect(current.attentionByEntityKey, isEmpty);
        expect(current.hasDurabilityFailure, isFalse);
        expect(current.outboxIsReliable, isTrue);
        expect(current.lastError, isNull);
        expect(store.load().records, isEmpty);
        expect(store.removalAttempts, 1);
      });
    }

    test('Use cloud remains fail-closed when uncertain removal fails',
        () async {
      final store = _OversizedParkingFailureStore(failRemove: true);
      final container = _cloudQueueContainer(
        store: store,
        repository: _RecordingAckRepository(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-large');
      await notifier.enqueue(
        _largeElementPatch(
          opId: 'oversized-failed-discard',
          elementId: 'element-large',
        ),
        flushImmediately: false,
      );
      await notifier.flushNow();

      final discarded = await notifier.discardRejected({key});

      expect(discarded, isEmpty);
      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(key));
      expect(current.hasDurabilityFailure, isTrue);
      expect(current.outboxIsReliable, isFalse);
      expect(current.lastError, contains('could not be removed'));
      expect(store.load().records.single.status, DurableOutboxStatus.queued);
      expect(store.removalAttempts, 1);
    });

    test('batches split below the conservative argument byte cap', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      container
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(true);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      for (var index = 0; index < 20; index += 1) {
        await notifier.enqueue(
          _largeElementPatch(
            opId: 'batch-$index',
            elementId: 'element-$index',
            value: _repeat('x', 820 * 1024),
          ),
          flushImmediately: false,
        );
      }
      final allOps = container
          .read(strategyOpQueueProvider)
          .queuedByEntityKey
          .values
          .map((intent) => intent.pending.op)
          .toList(growable: false);
      expect(
        serializedCloudBatchUtf8Bytes(
          strategyPublicId: 'strategy-1',
          clientId: container.read(strategyOpQueueProvider).clientId!,
          ops: allOps,
        ),
        greaterThan(maxCloudBatchBytes),
      );
      container
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(false);

      await notifier.flushNow();
      await repository.secondCall.future;
      for (var index = 0;
          index < 10 &&
              container.read(strategyOpQueueProvider).pending.isNotEmpty;
          index += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(repository.calls, hasLength(2));
      expect(repository.calls.expand((batch) => batch), hasLength(20));
      for (final batch in repository.calls) {
        expect(
          serializedCloudBatchUtf8Bytes(
            strategyPublicId: 'strategy-1',
            clientId: container.read(strategyOpQueueProvider).clientId!,
            ops: batch,
          ),
          lessThanOrEqualTo(maxCloudBatchBytes),
        );
      }
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, isEmpty);
    });

    test('an oversized same-entity successor is retained in attention',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');
      await notifier.enqueue(_elementPatch(
        opId: 'safe-predecessor',
        value: 'safe',
        expectedRevision: 1,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      final oversizedSuccessor = _largeElementPatch(
        opId: 'oversized-successor',
        elementId: 'element-1',
      );
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {key: oversizedSuccessor},
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'safe-predecessor',
        revision: 2,
      ));
      await firstFlush;
      for (var index = 0;
          index < 10 &&
              container
                  .read(strategyOpQueueProvider)
                  .attentionByEntityKey
                  .isEmpty;
          index += 1) {
        await Future<void>.delayed(Duration.zero);
      }

      var current = container.read(strategyOpQueueProvider);
      expect(repository.calls, hasLength(1));
      expect(current.attentionByEntityKey, contains(key));
      expect(current.successorByEntityKey, isEmpty);
      expect(current.lastError, cloudOperationTooLargeMessage);
      var durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.payload, oversizedSuccessor.payload);
      expect(durable.lastError, cloudOperationTooLargeMessage);

      container.dispose();
      container = _cloudQueueContainer(
        store: store,
        repository: _RecordingAckRepository(),
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.flushNow();

      current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(key));
      durable = store.load().records.single;
      expect(durable.pending.op.payload, oversizedSuccessor.payload);
    });

    test('a valid successor behind an oversized predecessor can land',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _RecordingAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      container
          .read(cloudCollabModeProvider.notifier)
          .setForceLocalFallback(true);
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');
      await notifier.enqueue(
        ElementAddOp(
          opId: 'oversized-predecessor',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'drawing',
            'payloadVersion': 1,
            'data': {'encodedPoints': _repeat('界', 310000)},
          },
          sortIndex: 0,
        ),
        flushImmediately: false,
      );
      await notifier.flushNow();
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementAddOp(
            opId: 'valid-successor',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {
              'kind': 'drawing',
              'payloadVersion': 1,
              'data': {'encodedPoints': 'reduced drawing'},
            },
            sortIndex: 0,
          ),
        },
      );

      var durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.opId, 'oversized-predecessor');
      expect(durable.successorPending?.op.opId, 'valid-successor');

      container.dispose();
      container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      await notifier.retryRejected(flushImmediately: false);
      await notifier.flushNow();

      expect(repository.calls, hasLength(1));
      expect(repository.calls.single, hasLength(1));
      expect(repository.calls.single.single, isA<ElementAddOp>());
      expect(repository.calls.single.single.payload, {
        'kind': 'drawing',
        'payloadVersion': 1,
        'data': {'encodedPoints': 'reduced drawing'},
      });
      expect(
        serializedCloudOperationUtf8Bytes(repository.calls.single.single),
        lessThanOrEqualTo(maxCloudOperationBytes),
      );
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, isEmpty);
    });
  });

  group('acknowledgement persistence recovery', () {
    test('accepted ack remove failure restores the batch for retry', () async {
      final store = _OneShotAckFailureStore(failRemove: true);
      final container = _cloudQueueContainer(
        store: store,
        repository: _AckRepository(reject: false),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      await notifier.enqueue(_cloudElementOp(), flushImmediately: false);
      await notifier.flushNow();

      _expectBatchRestored(container, store);
    });

    test('rejected ack put failure restores the batch for retry', () async {
      final store = _OneShotAckFailureStore(failAttentionPut: true);
      final container = _cloudQueueContainer(
        store: store,
        repository: _AckRepository(reject: true),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      await notifier.enqueue(_cloudElementOp(), flushImmediately: false);
      await notifier.flushNow();

      _expectBatchRestored(container, store);
    });
  });

  group('page descriptor final intent', () {
    test('rebases and sends the final side after an in-flight side patch',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.pageDescriptor('page-1');

      await notifier.enqueue(_pageSideOp(
        opId: 'defense',
        isAttack: false,
        expectedRevision: 1,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _pageSideOp(
            opId: 'attack',
            isAttack: true,
            expectedRevision: 1,
          ),
        },
      );

      final duringFirst = container.read(strategyOpQueueProvider);
      expect(duringFirst.inFlightByEntityKey[key]!.pending.op.opId, 'defense');
      expect(
        duringFirst.successorByEntityKey[key]!.pending.op.payload,
        {'isAttack': true},
      );
      final durableDuringFirst = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durableDuringFirst.pending.op.opId, 'defense');
      expect(durableDuringFirst.successorPending!.op.payload, {
        'isAttack': true,
      });

      repository.completeFirst(const AppliedOpAck(
        opId: 'defense',
        revision: 2,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final promoted = repository.calls[1].single as PagePatchOp;
      expect(promoted.payload, {'isAttack': true});
      expect(promoted.expectedPageRevision, 2);
      expect(promoted.opId, isNot('attack'));

      repository.completeSecond(AppliedOpAck(
        opId: promoted.opId,
        revision: 3,
      ));
      await repository.secondCompleted.future;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, isEmpty);
    });

    test('restart replays the predecessor before its durable final side',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final firstRepository = _SequencedAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: firstRepository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.pageDescriptor('page-1');

      await notifier.enqueue(_pageSideOp(
        opId: 'defense-before-restart',
        isAttack: false,
        expectedRevision: 4,
      ));
      unawaited(notifier.flushNow());
      await firstRepository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _pageSideOp(
            opId: 'attack-after-restart',
            isAttack: true,
            expectedRevision: 4,
          ),
        },
      );
      container.dispose();

      final replayRepository = _SequencedAckRepository();
      container = _cloudQueueContainer(
        store: store,
        repository: replayRepository,
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await replayRepository.firstStarted.future;

      final replayed = replayRepository.calls.first.single as PagePatchOp;
      expect(replayed.opId, 'defense-before-restart');
      expect(replayed.payload, {'isAttack': false});
      expect(
        container
            .read(strategyOpQueueProvider)
            .successorByEntityKey[key]!
            .pending
            .op
            .payload,
        {'isAttack': true},
      );

      replayRepository.completeFirst(const AppliedOpAck(
        opId: 'defense-before-restart',
        revision: 5,
      ));
      await replayRepository.secondStarted.future;
      final finalSide = replayRepository.calls[1].single as PagePatchOp;
      expect(finalSide.payload, {'isAttack': true});
      expect(finalSide.expectedPageRevision, 5);
      replayRepository.completeSecond(AppliedOpAck(
        opId: finalSide.opId,
        revision: 6,
      ));
      await replayRepository.secondCompleted.future;
    });
  });

  group('same-entity final intent', () {
    test('keeps an element successor behind its in-flight predecessor',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(_elementPatch(
        opId: 'first-edit',
        value: 'first',
        expectedRevision: 1,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _elementPatch(
            opId: 'second-edit',
            value: 'second',
            expectedRevision: 1,
          ),
        },
      );

      final duringFirst = container.read(strategyOpQueueProvider);
      expect(
        duringFirst.inFlightByEntityKey[key]!.pending.op.opId,
        'first-edit',
      );
      expect(
        duringFirst.successorByEntityKey[key]!.pending.op.payload,
        {'value': 'second'},
      );
      final durableDuringFirst = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durableDuringFirst.pending.op.opId, 'first-edit');
      expect(
        durableDuringFirst.successorPending!.op.payload,
        {'value': 'second'},
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'first-edit',
        revision: 2,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final promoted = repository.calls[1].single as ElementPatchOp;
      expect(promoted.payload, {'value': 'second'});
      expect(promoted.expectedElementRevision, 2);
      expect(promoted.opId, isNot('second-edit'));

      repository.completeSecond(AppliedOpAck(
        opId: promoted.opId,
        revision: 3,
      ));
      await repository.secondCompleted.future;
      await Future<void>.delayed(Duration.zero);
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
      expect(store.values, isEmpty);
    });

    test('restart replays an element predecessor before its successor',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final firstRepository = _SequencedAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: firstRepository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(_elementPatch(
        opId: 'first-before-restart',
        value: 'first',
        expectedRevision: 4,
      ));
      unawaited(notifier.flushNow());
      await firstRepository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _elementPatch(
            opId: 'second-after-restart',
            value: 'second',
            expectedRevision: 4,
          ),
        },
      );
      container.dispose();

      final replayRepository = _SequencedAckRepository();
      container = _cloudQueueContainer(
        store: store,
        repository: replayRepository,
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await replayRepository.firstStarted.future;

      final replayed = replayRepository.calls.first.single as ElementPatchOp;
      expect(replayed.opId, 'first-before-restart');
      expect(replayed.payload, {'value': 'first'});
      expect(
        container
            .read(strategyOpQueueProvider)
            .successorByEntityKey[key]!
            .pending
            .op
            .payload,
        {'value': 'second'},
      );

      replayRepository.completeFirst(const AppliedOpAck(
        opId: 'first-before-restart',
        revision: 5,
      ));
      await replayRepository.secondStarted.future;
      final finalEdit = replayRepository.calls[1].single as ElementPatchOp;
      expect(finalEdit.payload, {'value': 'second'});
      expect(finalEdit.expectedElementRevision, 5);
      replayRepository.completeSecond(AppliedOpAck(
        opId: finalEdit.opId,
        revision: 6,
      ));
      await replayRepository.secondCompleted.future;
    });

    test('rejected predecessor leaves its element successor in attention',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(_elementPatch(
        opId: 'conflicting-first',
        value: 'first',
        expectedRevision: 1,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _elementPatch(
            opId: 'retained-second',
            value: 'second',
            expectedRevision: 1,
          ),
        },
      );

      repository.completeFirst(const RejectedOpAck(
        opId: 'conflicting-first',
        rejectionReason: OpRejectionReason.revisionMismatch,
        current: ElementCurrentSnapshot(revision: 2, value: {'value': 'peer'}),
      ));
      await firstFlush;
      await Future<void>.delayed(Duration.zero);

      final conflicted = container.read(strategyOpQueueProvider);
      expect(repository.calls, hasLength(1));
      expect(conflicted.attentionByEntityKey, contains(key));
      expect(
        conflicted.successorByEntityKey[key]!.pending.op.payload,
        {'value': 'second'},
      );
      final durable = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.pending.op.opId, 'conflicting-first');
      expect(durable.successorPending!.op.payload, {'value': 'second'});
      expect(durable.latestServerRevision, 2);

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _elementPatch(
            opId: 'retained-second-again',
            value: 'second',
            expectedRevision: 1,
          ),
        },
        flushImmediately: true,
      );
      await Future<void>.delayed(Duration.zero);

      final reconciled = container.read(strategyOpQueueProvider);
      expect(repository.calls, hasLength(1));
      expect(reconciled.attentionByEntityKey, contains(key));
      expect(reconciled.queuedByEntityKey, isEmpty);
      expect(
        reconciled.successorByEntityKey[key]!.pending.op.payload,
        {'value': 'second'},
      );
      final durableAfterReconcile = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durableAfterReconcile.status, DurableOutboxStatus.attention);
      expect(durableAfterReconcile.pending.op.opId, 'conflicting-first');
      expect(
        durableAfterReconcile.successorPending!.op.payload,
        {'value': 'second'},
      );
      expect(durableAfterReconcile.latestServerRevision, 2);

      await notifier.retryRejected(flushImmediately: true);
      await repository.secondStarted.future;
      final retried = repository.calls[1].single as ElementPatchOp;
      expect(retried.opId, isNot('retained-second'));
      expect(retried.payload, {'value': 'second'});
      expect(retried.expectedElementRevision, 2);
      repository.completeSecond(AppliedOpAck(
        opId: retried.opId,
        revision: 3,
      ));
      await repository.secondCompleted.future;
    });

    test('promotes an edit after an element add as a patch', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(const ElementAddOp(
        opId: 'element-add-in-flight',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'first'},
        sortIndex: 0,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementAddOp(
            opId: 'element-add-successor',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {'value': 'second'},
            sortIndex: 0,
          ),
        },
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'element-add-in-flight',
        revision: 1,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final finalEdit = repository.calls[1].single as ElementPatchOp;
      expect(finalEdit.payload, {'value': 'second'});
      expect(finalEdit.expectedElementRevision, 1);
      repository.completeSecond(AppliedOpAck(
        opId: finalEdit.opId,
        revision: 2,
      ));
      await repository.secondCompleted.future;
    });

    test('promotes an edit after a lineup add as a patch', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.lineup('page-1', 'lineup-1');

      await notifier.enqueue(const LineupAddOp(
        opId: 'lineup-add-in-flight',
        lineupPublicId: 'lineup-1',
        pagePublicId: 'page-1',
        payload: {'value': 'first'},
        sortIndex: 0,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const LineupAddOp(
            opId: 'lineup-add-successor',
            lineupPublicId: 'lineup-1',
            pagePublicId: 'page-1',
            payload: {'value': 'second'},
            sortIndex: 0,
          ),
        },
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'lineup-add-in-flight',
        revision: 1,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final finalEdit = repository.calls[1].single as LineupPatchOp;
      expect(finalEdit.payload, {'value': 'second'});
      expect(finalEdit.expectedLineupRevision, 1);
      repository.completeSecond(AppliedOpAck(
        opId: finalEdit.opId,
        revision: 2,
      ));
      await repository.secondCompleted.future;
    });

    test('keeps a restore add after an accepted element delete', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(const ElementDeleteOp(
        opId: 'element-delete-in-flight',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        expectedElementRevision: 1,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementAddOp(
            opId: 'element-restore-successor',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {'value': 'restored'},
            sortIndex: 0,
            expectedElementRevision: 1,
          ),
        },
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'element-delete-in-flight',
        revision: 2,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final restore = repository.calls[1].single as ElementAddOp;
      expect(restore.payload, {'value': 'restored'});
      expect(restore.expectedElementRevision, 2);
      repository.completeSecond(AppliedOpAck(
        opId: restore.opId,
        revision: 3,
      ));
      await repository.secondCompleted.future;
    });

    test('keeps a final element delete behind an in-flight add', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.element('page-1', 'element-1');

      await notifier.enqueue(const ElementAddOp(
        opId: 'element-add-in-flight',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'first'},
        sortIndex: 0,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementAddOp(
            opId: 'element-add-successor',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {'value': 'second'},
            sortIndex: 0,
          ),
        },
      );
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementDeleteOp(
            opId: 'element-delete-successor',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            expectedElementRevision: 0,
          ),
        },
      );

      final durableBeforeAck = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durableBeforeAck.pending.op.opId, 'element-add-in-flight');
      expect(durableBeforeAck.successorPending!.op, isA<ElementDeleteOp>());

      repository.completeFirst(const AppliedOpAck(
        opId: 'element-add-in-flight',
        revision: 1,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final finalDelete = repository.calls[1].single as ElementDeleteOp;
      expect(finalDelete.expectedElementRevision, 1);
      repository.completeSecond(AppliedOpAck(
        opId: finalDelete.opId,
        revision: 2,
      ));
      await repository.secondCompleted.future;
    });

    test('keeps a final lineup delete behind an in-flight add', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      const key = EntitySyncKey.lineup('page-1', 'lineup-1');

      await notifier.enqueue(const LineupAddOp(
        opId: 'lineup-add-in-flight',
        lineupPublicId: 'lineup-1',
        pagePublicId: 'page-1',
        payload: {'value': 'first'},
        sortIndex: 0,
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const LineupAddOp(
            opId: 'lineup-add-successor',
            lineupPublicId: 'lineup-1',
            pagePublicId: 'page-1',
            payload: {'value': 'second'},
            sortIndex: 0,
          ),
        },
      );
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const LineupDeleteOp(
            opId: 'lineup-delete-successor',
            lineupPublicId: 'lineup-1',
            pagePublicId: 'page-1',
            expectedLineupRevision: 0,
          ),
        },
      );

      final durableBeforeAck = DurableOutboxRecord.fromJson(
        Map<String, dynamic>.from(store.values.values.single as Map),
      );
      expect(durableBeforeAck.pending.op.opId, 'lineup-add-in-flight');
      expect(durableBeforeAck.successorPending!.op, isA<LineupDeleteOp>());

      repository.completeFirst(const AppliedOpAck(
        opId: 'lineup-add-in-flight',
        revision: 1,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final finalDelete = repository.calls[1].single as LineupDeleteOp;
      expect(finalDelete.expectedLineupRevision, 1);
      repository.completeSecond(AppliedOpAck(
        opId: finalDelete.opId,
        revision: 2,
      ));
      await repository.secondCompleted.future;
    });
  });
}

ProviderContainer _cloudQueueContainer({
  required DurableStrategyOutboxStore store,
  required ConvexStrategyRepository repository,
}) {
  return ProviderContainer(overrides: [
    durableStrategyOutboxStoreProvider.overrideWithValue(store),
    convexStrategyRepositoryProvider.overrideWithValue(repository),
    authProvider.overrideWith(_CloudReadyAuthProvider.new),
    convexConnectionSnapshotProvider.overrideWithValue(true),
  ]);
}

ElementPatchOp _cloudElementOp() {
  return const ElementPatchOp(
    opId: 'op-1',
    elementPublicId: 'element-1',
    pagePublicId: 'page-1',
    payload: {'value': 'safe'},
    expectedElementRevision: 1,
  );
}

PagePatchOp _pageSideOp({
  required String opId,
  required bool isAttack,
  required int expectedRevision,
}) {
  return PagePatchOp(
    opId: opId,
    pagePublicId: 'page-1',
    payload: {'isAttack': isAttack},
    expectedPageRevision: expectedRevision,
  );
}

ElementPatchOp _elementPatch({
  required String opId,
  required String value,
  required int expectedRevision,
}) {
  return ElementPatchOp(
    opId: opId,
    elementPublicId: 'element-1',
    pagePublicId: 'page-1',
    payload: {'value': value},
    expectedElementRevision: expectedRevision,
  );
}

ElementPatchOp _largeElementPatch({
  required String opId,
  required String elementId,
  String? value,
}) {
  return ElementPatchOp(
    opId: opId,
    elementPublicId: elementId,
    pagePublicId: 'page-1',
    payload: {'value': value ?? _repeat('界', 310000)},
    expectedElementRevision: 1,
  );
}

String _repeat(String value, int count) => List.filled(count, value).join();

void _expectBatchRestored(
  ProviderContainer container,
  MemoryDurableStrategyOutboxStore store,
) {
  final current = container.read(strategyOpQueueProvider);
  expect(current.isFlushing, isFalse);
  expect(current.inFlightByEntityKey, isEmpty);
  expect(current.queuedByEntityKey, hasLength(1));
  expect(current.queuedByEntityKey.values.single.pending.attempts, 1);
  final durable = DurableOutboxRecord.fromJson(
    Map<String, dynamic>.from(store.values.values.single as Map),
  );
  expect(durable.status, DurableOutboxStatus.queued);
  expect(durable.pending.attempts, 1);
}

class _CloudReadyAuthProvider extends AuthProvider {
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

class _AckRepository extends ConvexStrategyRepository {
  _AckRepository({required this.reject})
      : super(IcarusConvexApi(_UnusedTransport()));

  final bool reject;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    return [
      for (final op in ops)
        if (reject)
          RejectedOpAck(
            opId: op.opId,
            rejectionReason: OpRejectionReason.revisionMismatch,
          )
        else
          AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

class _RecordingAckRepository extends ConvexStrategyRepository {
  _RecordingAckRepository() : super(IcarusConvexApi(_UnusedTransport()));

  final List<List<StrategyOp>> calls = [];
  final secondCall = Completer<void>();

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add(List<StrategyOp>.from(ops));
    if (calls.length == 2 && !secondCall.isCompleted) secondCall.complete();
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

class _SequencedAckRepository extends ConvexStrategyRepository {
  _SequencedAckRepository() : super(IcarusConvexApi(_UnusedTransport()));

  final firstStarted = Completer<void>();
  final secondStarted = Completer<void>();
  final secondCompleted = Completer<void>();
  final _firstResponse = Completer<List<OpAck>>();
  final _secondResponse = Completer<List<OpAck>>();
  final List<List<StrategyOp>> calls = [];

  void completeFirst(OpAck ack) => _firstResponse.complete([ack]);

  void completeSecond(OpAck ack) => _secondResponse.complete([ack]);

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
  }) async {
    calls.add(List<StrategyOp>.from(ops));
    if (calls.length == 1) {
      firstStarted.complete();
      return _firstResponse.future;
    }
    secondStarted.complete();
    final result = await _secondResponse.future;
    secondCompleted.complete();
    return result;
  }
}

class _OneShotAckFailureStore extends MemoryDurableStrategyOutboxStore {
  _OneShotAckFailureStore({
    this.failRemove = false,
    this.failAttentionPut = false,
  });

  bool failRemove;
  bool failAttentionPut;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    if (failAttentionPut && record.status == DurableOutboxStatus.attention) {
      failAttentionPut = false;
      throw StateError('attention write failed');
    }
    await super.put(record);
  }

  @override
  Future<void> remove(String storageKey) async {
    if (failRemove) {
      failRemove = false;
      throw StateError('accepted ack removal failed');
    }
    await super.remove(storageKey);
  }
}

class _FirstPutFailureStore extends MemoryDurableStrategyOutboxStore {
  var failNextPut = true;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    if (failNextPut) {
      failNextPut = false;
      throw StateError('initial write failed');
    }
    await super.put(record);
  }
}

class _OversizedParkingFailureStore
    extends MemoryDurableStrategyOutboxStore {
  _OversizedParkingFailureStore({
    this.dropBeforeThrow = false,
    this.failRemove = false,
  });

  final bool dropBeforeThrow;
  final bool failRemove;
  var attentionWrites = 0;
  var removalAttempts = 0;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    if (record.status == DurableOutboxStatus.attention &&
        cloudOperationExceedsPolicy(record.pending.op)) {
      attentionWrites += 1;
      if (dropBeforeThrow) values.remove(record.storageKey);
      throw StateError('oversized attention write failed');
    }
    await super.put(record);
  }

  @override
  Future<void> remove(String storageKey) async {
    removalAttempts += 1;
    if (failRemove) throw StateError('uncertain removal failed');
    await super.remove(storageKey);
  }
}

class _FailingSelectedRemovalStore extends MemoryDurableStrategyOutboxStore {
  String? failStorageKey;

  @override
  Future<void> remove(String storageKey) async {
    if (storageKey == failStorageKey) {
      throw StateError('selected removal failed');
    }
    await super.remove(storageKey);
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

class _BlockingStore extends MemoryDurableStrategyOutboxStore {
  final allowWrite = Completer<void>();

  @override
  Future<void> put(DurableOutboxRecord record) async {
    await allowWrite.future;
    await super.put(record);
  }
}

class _BlockingReplacementStore extends MemoryDurableStrategyOutboxStore {
  final allowReplacement = Completer<void>();
  var _writes = 0;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    _writes += 1;
    if (_writes == 2) {
      await allowReplacement.future;
    }
    await super.put(record);
  }
}
