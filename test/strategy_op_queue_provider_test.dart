import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/collab/durable_strategy_outbox.dart';
import 'package:icarus/collab/field_merge.dart';
import 'package:icarus/collab/generated/generated.dart';
import 'package:icarus/collab/transport/convex_transport.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
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
        strategyOutboxSessionProvider.overrideWithValue(
          const StrategyOutboxSession(
            accountId: null,
            isReady: false,
            hasAuthIncident: false,
          ),
        ),
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

    test('unknown future outbox records fail closed instead of converting', () {
      final future = record(status: DurableOutboxStatus.queued).toJson()
        ..['outboxVersion'] = fieldMergeOutboxRecordVersion + 1;

      expect(
        () => DurableOutboxRecord.fromJson(future),
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
      const otherAttentionKey = EntitySyncKey.element('page-1', 'element-2');
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
        store.load().records.expand((record) => <String>[
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
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
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
      strategyOutboxSessionProvider.overrideWithValue(
        const StrategyOutboxSession(
          accountId: null,
          isReady: false,
          hasAuthIncident: false,
        ),
      ),
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
      expect(current.attentionByEntityKey[key]!.pending.op, op);
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

    test('a lineup refused for another page stays saved and keeps that reason',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final container = _cloudQueueContainer(
        store: store,
        repository: _FailingLineupRepository(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      final lineup = _lineupAdd(opId: 'add-lineup', pageId: 'page-2');
      final key = EntitySyncKey.forStrategyOp(lineup)!;

      await notifier.enqueue(lineup, flushImmediately: false);
      await notifier.flushNow();

      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey[key]!.pending.op.opId, 'add-lineup');
      expect(current.needsAttention, isTrue);
      // The sync button explains the refusal, not a generic conflict.
      expect(current.lastError, lineupPageMismatchMessage);
      expect(isSpecificAttentionReason(current.lastError!), isTrue);
      final durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(
        friendlyCloudSyncError(durable.lastError!),
        contains('clashes with one on another page'),
      );
    });

    test(
        'a lineup group refused for overlapping another stays saved and keeps '
        'that reason', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final container = _cloudQueueContainer(
        store: store,
        repository: _FailingLineupRepository(
          code: 'INVALID_LINEUP_PAYLOAD_DATA',
          message: lineupOverlapMessage,
        ),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      final lineup = _lineupAdd(opId: 'add-group');
      final key = EntitySyncKey.forStrategyOp(lineup)!;

      await notifier.enqueue(lineup, flushImmediately: false);
      await notifier.flushNow();

      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey[key]!.pending.op.opId, 'add-group');
      expect(current.lastError, lineupOverlapMessage);
      expect(isSpecificAttentionReason(current.lastError!), isTrue);
      final durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.attention);
      expect(durable.lastError, lineupOverlapMessage);
      expect(friendlyCloudSyncError(durable.lastError!),
          contains('shares a spot'));
    });

    test('opening a strategy shows its saved lineup refusal', () async {
      final store = MemoryDurableStrategyOutboxStore();
      await store.put(_savedRecord(
        _lineupAdd(opId: 'refused-lineup'),
        status: DurableOutboxStatus.attention,
        lastError: lineupPageMismatchMessage,
      ));
      final container = _cloudQueueContainer(
        store: store,
        repository: _RecordingAckRepository(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier);

      // Straight after a restart, and after switching from another strategy.
      notifier.setActiveStrategy('strategy-1', accountId: 'account-a');
      expect(
        container.read(strategyOpQueueProvider).lastError,
        lineupPageMismatchMessage,
      );
      notifier.setActiveStrategy('strategy-2', accountId: 'account-a');
      notifier.setActiveStrategy('strategy-1', accountId: 'account-a');
      expect(
        container.read(strategyOpQueueProvider).lastError,
        lineupPageMismatchMessage,
      );
    });

    test('undoing an edit to a refused lineup keeps why it was refused',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final container = _cloudQueueContainer(
        store: store,
        repository: _FailingLineupRepository(),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      LineupAddOp lineup(String name) =>
          _lineupAdd(opId: 'add-$name', name: name);
      final key = EntitySyncKey.forStrategyOp(lineup('first'))!;

      await notifier.enqueue(lineup('first'), flushImmediately: false);
      await notifier.flushNow();
      await notifier.syncDesiredGenericOp(
        entityKey: key,
        desiredOp: lineup('edited'),
      );
      expect(container.read(strategyOpQueueProvider).successorByEntityKey,
          contains(key));
      await notifier.syncDesiredGenericOp(
        entityKey: key,
        desiredOp: lineup('first'),
      );

      final current = container.read(strategyOpQueueProvider);
      expect(current.successorByEntityKey, isEmpty);
      expect(current.lastError, lineupPageMismatchMessage);
      expect(store.load().records.single.lastError, lineupPageMismatchMessage);
    });

    // A conflict, and a failed validation that is not one.
    for (final otherReason in [
      'revision_mismatch',
      'Lineup key does not match its payload',
    ]) {
      test('a lineup refusal beside other refused work notes it ($otherReason)',
          () async {
        final store = MemoryDurableStrategyOutboxStore();
        const element = ElementPatchOp(
          opId: 'stale-element',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {'value': 'mine'},
          expectedElementRevision: 1,
        );
        for (final (StrategyOp op, reason) in [
          (_lineupAdd(opId: 'refused-lineup'), lineupPageMismatchMessage),
          (element, otherReason),
        ]) {
          await store.put(_savedRecord(
            op,
            status: DurableOutboxStatus.attention,
            lastError: reason,
            latestServerRevision: 2,
          ));
        }
        final container = _cloudQueueContainer(
          store: store,
          repository: _RecordingAckRepository(),
        );
        addTearDown(container.dispose);

        container
            .read(strategyOpQueueProvider.notifier)
            .setActiveStrategy('strategy-1', accountId: 'account-a');

        final error = container.read(strategyOpQueueProvider).lastError!;
        expect(error, contains(lineupPageMismatchMessage));
        expect(error, contains(otherWorkNeedsAttentionNote));
      });
    }

    test('an old-format lineup add is shown, never sent, and kept on restart',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final retired = _retiredLinkAdd();
      final retiredKey = EntitySyncKey.forStrategyOp(retired)!;
      await store.put(_savedRecord(_cloudElementOp()));
      await store.put(_savedRecord(retired));
      var repository = _RecordingAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      // Shown from the moment the strategy opens, before anything is sent.
      var current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey.keys, [
        EntitySyncKey.forStrategyOp(_cloudElementOp()),
      ]);
      expect(current.attentionByEntityKey.keys, [retiredKey]);
      expect(current.lastError, retiredLineupOpMessage);

      await notifier.flushNow();
      await _settle();

      // The rest of the strategy's work lands; the old change never leaves
      // the device.
      expect(
        repository.calls.map((ops) => ops.map((op) => op.opId).toList()),
        [
          ['op-1'],
        ],
      );
      current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.attentionByEntityKey.keys, [retiredKey]);
      expect(current.needsAttention, isTrue);
      expect(current.lastError, retiredLineupOpMessage);
      expect(isSpecificAttentionReason(current.lastError!), isTrue);
      expect(
        friendlyCloudSyncError(current.lastError!),
        contains('older version of Icarus'),
      );
      // Only the copy in memory changed: the saved record is as the older
      // build left it.
      final durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.queued);
      expect(durable.pending.op.opId, retired.opId);
      expect(durable.pending.op.payload, retired.payload);

      // After a restart it is still there, still explained, still unsent.
      container.dispose();
      repository = _RecordingAckRepository();
      container = _cloudQueueContainer(store: store, repository: repository);
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.flushNow();
      await _settle();

      current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey.keys, [retiredKey]);
      expect(current.lastError, retiredLineupOpMessage);
      expect(repository.calls, isEmpty);
      expect(store.load().records.single.pending.op.opId, retired.opId);
    });

    // B4: whatever state an older build left an old-format record in, it
    // waits in attention from the moment the outbox loads, where the
    // canvas's reconciliation never reaches it. Left queued, paused or in
    // flight it would otherwise be reconciled away (or sent) by the first
    // sync of its page.
    for (final (status, attempts, lastError) in [
      (DurableOutboxStatus.queued, 0, null),
      // Paused after transport failures, with no successor.
      (DurableOutboxStatus.paused, 8, 'Connection lost while sending'),
      (DurableOutboxStatus.inFlight, 1, null),
      // Refused by an older build for a reason of its own.
      (
        DurableOutboxStatus.attention,
        1,
        "This lineup's origin or landing spot is no longer on the page",
      ),
    ]) {
      test(
          'an old-format lineup add left ${status.name} waits in attention '
          'from load, through a sync of its page', () async {
        final store = MemoryDurableStrategyOutboxStore();
        final retired = _retiredLinkAdd();
        final retiredKey = EntitySyncKey.forStrategyOp(retired)!;
        await store.put(DurableOutboxRecord(
          accountId: 'account-a',
          strategyPublicId: 'strategy-1',
          entityKey: retiredKey,
          pending: PendingOp(
            op: retired,
            clientId: 'client-a',
            attempts: attempts,
            lastAttemptAt: attempts == 0 ? null : DateTime(2026),
          ),
          status: status,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          lastError: lastError,
        ));
        final repository = _RecordingAckRepository();
        final container = _cloudQueueContainer(
          store: store,
          repository: repository,
        );
        addTearDown(container.dispose);
        final notifier = container.read(strategyOpQueueProvider.notifier)
          ..setActiveStrategy('strategy-1', accountId: 'account-a');

        var current = container.read(strategyOpQueueProvider);
        expect(current.attentionByEntityKey.keys, [retiredKey]);
        expect(current.queuedByEntityKey, isEmpty);
        expect(current.pausedByEntityKey, isEmpty);
        expect(current.inFlightByEntityKey, isEmpty);
        expect(current.lastError, retiredLineupOpMessage);

        // The canvas syncs the page with other work, clearing what it no
        // longer has.
        const element = ElementAddOp(
          opId: 'element-add',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {'value': 'new'},
          sortIndex: 0,
        );
        await notifier.syncDesiredOpsForPage(
          pageId: 'page-1',
          desiredOpsByEntityKey: {
            EntitySyncKey.forStrategyOp(element)!: element,
          },
          clearMissing: true,
        );
        await notifier.flushNow();
        await _settle();

        current = container.read(strategyOpQueueProvider);
        expect(current.attentionByEntityKey.keys, [retiredKey]);
        expect(
          current.attentionByEntityKey[retiredKey]!.pending.op.opId,
          retired.opId,
        );
        expect(current.lastError, retiredLineupOpMessage);
        expect(
          repository.calls.expand((ops) => ops).map((op) => op.opId),
          ['element-add'],
        );
        // The element landed and left the outbox; the old change is still
        // saved, exactly as the older build saved it.
        final durable = store.load().records.single;
        expect(durable.entityKey, retiredKey);
        expect(durable.pending.op.opId, retired.opId);
        expect(durable.pending.op.payload, retired.payload);
        expect(durable.status, status);
      });
    }

    test('an old-format lineup delete is shown, and alone sends nothing',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      const retired = LineupDeleteOp(
        opId: 'old-origin-delete',
        lineupPublicId: 'lineupOrigin:o',
        pagePublicId: 'page-1',
        expectedLineupRevision: 1,
      );
      final retiredKey = EntitySyncKey.forStrategyOp(retired)!;
      await store.put(_savedRecord(retired));
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      await notifier.flushNow();
      await _settle();

      expect(repository.calls, isEmpty);
      final current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.attentionByEntityKey.keys, [retiredKey]);
      expect(current.lastError, retiredLineupOpMessage);
      final durable = store.load().records.single;
      expect(durable.pending.op.opId, retired.opId);
    });

    test('keep mine leaves an old-format lineup change waiting; discard drops',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final retired = _retiredLinkAdd();
      final retiredKey = EntitySyncKey.forStrategyOp(retired)!;
      const element = ElementPatchOp(
        opId: 'stale-element',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'mine'},
        expectedElementRevision: 1,
      );
      final elementKey = EntitySyncKey.forStrategyOp(element)!;
      await store.put(_savedRecord(
        element,
        status: DurableOutboxStatus.attention,
        lastError: 'revision_mismatch',
        latestServerRevision: 2,
      ));
      await store.put(_savedRecord(retired));
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.flushNow();
      await _settle();
      expect(repository.calls, isEmpty);
      expect(
        container.read(strategyOpQueueProvider).lastError,
        '$retiredLineupOpMessage. $otherWorkNeedsAttentionNote',
      );

      // Keep mine re-sends the conflict and leaves the old change, however
      // often it is chosen.
      await notifier.retryRejected(flushImmediately: false);
      var current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey.keys, [elementKey]);
      expect(current.attentionByEntityKey.keys, [retiredKey]);
      expect(current.lastError, retiredLineupOpMessage);
      await notifier.retryRejected(flushImmediately: false);
      current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, isNot(contains(retiredKey)));
      // Alone in attention it still says why, not that no revision matched.
      expect(current.lastError, retiredLineupOpMessage);
      expect(
        current.attentionByEntityKey[retiredKey]!.pending.op.opId,
        retired.opId,
      );
      final durable = store.load().records.singleWhere(
            (record) => record.entityKey == retiredKey,
          );
      expect(durable.pending.op.opId, retired.opId);
      expect(durable.pending.op.payload, retired.payload);
      expect(
        repository.calls.expand((ops) => ops).map((op) => op.opId),
        isNot(contains(retired.opId)),
      );

      final discarded = await notifier.discardRejected({retiredKey});

      expect(discarded, {retiredKey});
      current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.lastError, isNull);
      expect(
        store.load().records.map((record) => record.entityKey),
        isNot(contains(retiredKey)),
      );
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
      const oversizedKey = EntitySyncKey.element('page-1', 'element-large');
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

    test('an over-wide array is parked before independent transport', () async {
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
      expect(
          store.load().records.single.lastError, cloudOperationTooLargeMessage);
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

    test(
        'a legacy queued oversized record parks without overwrite and survives '
        'restart', () async {
      final store = _OversizedParkingFailureStore(dropBeforeThrow: true);
      final oversized = _largeElementPatch(
        opId: 'legacy-oversized',
        elementId: 'element-large',
      );
      const key = EntitySyncKey.element('page-1', 'element-large');
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: key,
        pending: PendingOp(op: oversized, clientId: 'stable-client'),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ));
      final repository = _RecordingAckRepository();
      var container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      var notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      await notifier.flushNow();

      var current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(key));
      expect(current.queuedByEntityKey, isEmpty);
      expect(repository.calls, isEmpty);
      expect(store.attentionWrites, 0);
      expect(store.load().records.single.status, DurableOutboxStatus.queued);

      container.dispose();
      container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.flushNow();

      current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, contains(key));
      expect(current.lastError, cloudOperationTooLargeMessage);
      expect(repository.calls, isEmpty);
      expect(store.attentionWrites, 0);
      expect(store.load().records.single.pending.op.opId, oversized.opId);

      final discarded = await notifier.discardRejected({key});
      expect(discarded, {key});
      expect(store.load().records, isEmpty);
    });

    test('Use cloud clears an uncertain oversized first-write failure',
        () async {
      final store = _OversizedParkingFailureStore(dropBeforeThrow: true);
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
      expect(store.load().records, isEmpty);

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
      expect(store.load().records, isEmpty);
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

    test('a replayed predecessor rebases its successor where it was applied',
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

      // The server applied first-edit at 2, its ack was lost, and a
      // teammate's edit took the row to 3 before first-edit was sent again.
      // The replay is answered as a noop at the revision first-edit was
      // applied at, not the row's revision now.
      repository.completeFirst(const NoopOpAck(
        opId: 'first-edit',
        currentRevision: 2,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final promoted = repository.calls[1].single as ElementPatchOp;
      expect(promoted.payload, {'value': 'second'});
      expect(promoted.expectedElementRevision, 2);

      // So the server, its row at 3, refuses it rather than letting it
      // overwrite the teammate's edit unseen.
      repository.completeSecond(
        promoted.expectedElementRevision == 3
            ? AppliedOpAck(opId: promoted.opId, revision: 4)
            : RejectedOpAck(
                opId: promoted.opId,
                rejectionReason: OpRejectionReason.revisionMismatch,
                current: const ElementCurrentSnapshot(
                  revision: 3,
                  value: {'value': 'teammate'},
                ),
              ),
      );
      await repository.secondCompleted.future;
      await _settle();

      final current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.successorByEntityKey, isEmpty);
      expect(
        current.attentionByEntityKey[key]!.pending.op.payload,
        {'value': 'second'},
      );
      final record = store.load().records.single;
      expect(record.status, DurableOutboxStatus.attention);
      expect(record.pending.op.opId, promoted.opId);
      expect(record.lastError, OpRejectionReason.revisionMismatch.wireName);
      expect(record.latestServerRevision, 3);
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

    for (final editedAfterRestart in [false, true]) {
      test(
          'acks say which work was in the outbox before the restart '
          '(final edit made ${editedAfterRestart ? 'after' : 'before'} it)',
          () async {
        final store = MemoryDurableStrategyOutboxStore();
        const key = EntitySyncKey.element('page-1', 'element-1');
        final firstRepository = _SequencedAckRepository();
        var container = _cloudQueueContainer(
          store: store,
          repository: firstRepository,
        );
        var notifier = container.read(strategyOpQueueProvider.notifier)
          ..setActiveStrategy('strategy-1', accountId: 'account-a');
        await notifier.enqueue(_elementPatch(
          opId: 'first',
          value: 'first',
          expectedRevision: 4,
        ));
        Future<void> editAgain() => notifier.syncDesiredOpsForPage(
              pageId: 'page-1',
              desiredOpsByEntityKey: {
                key: _elementPatch(
                  opId: 'second',
                  value: 'second',
                  expectedRevision: 4,
                ),
              },
            );
        if (!editedAfterRestart) {
          unawaited(notifier.flushNow());
          await firstRepository.firstStarted.future;
          await editAgain();
        }
        container.dispose();

        final repository = _SequencedAckRepository();
        container = _cloudQueueContainer(store: store, repository: repository);
        addTearDown(container.dispose);
        notifier = container.read(strategyOpQueueProvider.notifier)
          ..setActiveStrategy('strategy-1', accountId: 'account-a');
        await repository.firstStarted.future;
        if (editedAfterRestart) await editAgain();
        List<AckedEntityIntent> acked() =>
            container.read(strategyOpQueueProvider).lastAckBatch;

        repository
            .completeFirst(const AppliedOpAck(opId: 'first', revision: 5));
        await repository.secondStarted.future;
        expect(acked().single.op.opId, 'first');
        expect(acked().single.restored, isTrue);

        final finalEdit = repository.calls[1].single;
        expect(finalEdit.payload, {'value': 'second'});
        repository.completeSecond(
          AppliedOpAck(opId: finalEdit.opId, revision: 6),
        );
        await repository.secondCompleted.future;
        await Future<void>.delayed(Duration.zero);
        expect(acked().single.op.opId, finalEdit.opId);
        expect(acked().single.restored, !editedAfterRestart);
      });
    }

    test('a final edit promoted while its strategy opens lands restored',
        () async {
      final store = _GatedPromotionStore();
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: const EntitySyncKey.element('page-1', 'element-1'),
        pending: PendingOp(
          op: _elementPatch(opId: 'first', value: 'first', expectedRevision: 4),
          clientId: 'stable-client',
        ),
        successorPending: PendingOp(
          op: _elementPatch(
              opId: 'second', value: 'second', expectedRevision: 4),
          clientId: 'stable-client',
        ),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ));
      final repository = _SequencedAckRepository();
      final container =
          _cloudQueueContainer(store: store, repository: repository);
      addTearDown(container.dispose);
      // Another strategy is open; this one's work replays in the background.
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-2', accountId: 'account-a');
      await repository.firstStarted.future;
      repository.completeFirst(const AppliedOpAck(opId: 'first', revision: 5));
      // The user opens it while the promoted final edit is being stored.
      await store.promotionStarted.future;
      notifier.setActiveStrategy('strategy-1', accountId: 'account-a');
      store.releasePromotion.complete();

      await repository.secondStarted.future;
      final finalEdit = repository.calls[1].single;
      expect(finalEdit.payload, {'value': 'second'});
      repository.completeSecond(
        AppliedOpAck(opId: finalEdit.opId, revision: 6),
      );
      await repository.secondCompleted.future;
      await Future<void>.delayed(Duration.zero);
      final acked = container.read(strategyOpQueueProvider).lastAckBatch;
      expect(acked.single.op.opId, finalEdit.opId);
      expect(acked.single.restored, isTrue);
    });

    test('work sent before the canvas was drawn fresh lands restored',
        () async {
      final repository = _SequencedAckRepository();
      final container = _cloudQueueContainer(
        store: MemoryDurableStrategyOutboxStore(),
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(
        _elementPatch(opId: 'first', value: 'first', expectedRevision: 4),
      );
      unawaited(notifier.flushNow());
      await repository.firstStarted.future;
      // The user leaves for a local strategy and comes back: the queue
      // stays on this one while the canvas is drawn again from the server.
      notifier.forgetCanvasWork();
      expect(notifier.canvasWorkCount, 0);
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          const EntitySyncKey.element('page-1', 'element-1'): _elementPatch(
              opId: 'second', value: 'second', expectedRevision: 4),
        },
      );
      expect(notifier.canvasWorkCount, 1);
      List<AckedEntityIntent> acked() =>
          container.read(strategyOpQueueProvider).lastAckBatch;

      repository.completeFirst(const AppliedOpAck(opId: 'first', revision: 5));
      await repository.secondStarted.future;
      expect(acked().single.op.opId, 'first');
      expect(acked().single.restored, isTrue);
      // The edit made since follows it onto the new revision, still the
      // canvas's work.
      expect(notifier.canvasWorkCount, 1);

      final finalEdit = repository.calls[1].single;
      repository.completeSecond(
        AppliedOpAck(opId: finalEdit.opId, revision: 6),
      );
      await repository.secondCompleted.future;
      await Future<void>.delayed(Duration.zero);
      expect(acked().single.op.opId, finalEdit.opId);
      expect(acked().single.restored, isFalse);
      // Nothing is remembered for work that has landed.
      expect(notifier.canvasWorkCount, 0);
    });

    test('recovered work kept while its ack is being stored is not resent',
        () async {
      final store = _GatedRemoveStore();
      final recovered =
          _elementPatch(opId: 'recovered', value: 'new', expectedRevision: 1);
      const key = EntitySyncKey.element('page-1', 'element-1');
      await store.put(DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: key,
        pending: PendingOp(op: recovered, clientId: 'stable-client'),
        status: DurableOutboxStatus.queued,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ));
      final repository = _SequencedAckRepository();
      final container =
          _cloudQueueContainer(store: store, repository: repository);
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await repository.firstStarted.future;
      repository
          .completeFirst(const AppliedOpAck(opId: 'recovered', revision: 2));
      await store.removeStarted.future;
      // Still shown in flight: the page keeps it, unchanged, as its intent.
      expect(
        container
            .read(strategyOpQueueProvider)
            .inFlightByEntityKey[key]!
            .pending
            .op
            .opId,
        'recovered',
      );
      final kept = notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {key: recovered},
      );
      store.releaseRemove.complete();
      await kept;
      final queue = container.read(strategyOpQueueProvider);
      expect(queue.lastAckBatch.single.restored, isTrue);
      expect(queue.pending, isEmpty);
      expect(store.values, isEmpty);
      expect(notifier.canvasWorkCount, 0);
      // Past the send debounce: nothing replays it.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(repository.calls, hasLength(1));
    });

    test('an ack stored after the canvas is drawn fresh lands restored',
        () async {
      final store = _GatedRemoveStore();
      final repository = _SequencedAckRepository();
      final container =
          _cloudQueueContainer(store: store, repository: repository);
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(
        _elementPatch(opId: 'edit', value: 'edit', expectedRevision: 1),
      );
      unawaited(notifier.flushNow());
      await repository.firstStarted.future;
      repository.completeFirst(const AppliedOpAck(opId: 'edit', revision: 2));
      await store.removeStarted.future;
      // The canvas is reset and drawn again from the server while the ack
      // is being stored.
      notifier.forgetCanvasWork();
      store.releaseRemove.complete();
      await Future<void>.delayed(Duration.zero);
      await notifier.flushNow();
      final acked = container.read(strategyOpQueueProvider).lastAckBatch;
      expect(acked.single.op.opId, 'edit');
      expect(acked.single.restored, isTrue);
    });

    test('discarding refused work forgets it as the canvas\'s', () async {
      final container = _cloudQueueContainer(
        store: MemoryDurableStrategyOutboxStore(),
        repository: _AckRepository(reject: true),
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(
        _elementPatch(opId: 'edit', value: 'edit', expectedRevision: 1),
      );
      await notifier.flushNow();
      const key = EntitySyncKey.element('page-1', 'element-1');
      expect(
        container.read(strategyOpQueueProvider).attentionByEntityKey,
        contains(key),
      );
      expect(notifier.canvasWorkCount, 1);
      await notifier.discardRejected({key});
      expect(notifier.canvasWorkCount, 0);
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

      final successor = _lineupAdd(
        opId: 'lineup-add-successor',
        id: 'lineup-1',
        name: 'second',
      );

      await notifier.enqueue(_lineupAdd(
        opId: 'lineup-add-in-flight',
        id: 'lineup-1',
        name: 'first',
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {key: successor},
      );

      repository.completeFirst(const AppliedOpAck(
        opId: 'lineup-add-in-flight',
        revision: 1,
      ));
      await firstFlush;
      await repository.secondStarted.future;

      final finalEdit = repository.calls[1].single as LineupPatchOp;
      expect(finalEdit.lineupPublicId, 'lineup-1');
      expect(finalEdit.payload, successor.payload);
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

      await notifier.enqueue(_lineupAdd(
        opId: 'lineup-add-in-flight',
        id: 'lineup-1',
        name: 'first',
      ));
      final firstFlush = notifier.flushNow();
      await repository.firstStarted.future;

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: _lineupAdd(
            opId: 'lineup-add-successor',
            id: 'lineup-1',
            name: 'second',
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

  group('keep mine after a teammate deleted the row', () {
    Future<(ProviderContainer, StrategyOpQueueNotifier)> refused(
      _TombstoneRepository repository,
      MemoryDurableStrategyOutboxStore store,
      List<StrategyOp> ops,
    ) async {
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      for (final op in ops) {
        await notifier.enqueue(op, flushImmediately: false);
      }
      await notifier.flushNow();
      await _settle();

      final current = container.read(strategyOpQueueProvider);
      expect(
        current.attentionByEntityKey.keys,
        unorderedEquals(
            [for (final op in ops) EntitySyncKey.forStrategyOp(op)]),
      );
      for (final record in store.load().records) {
        expect(record.status, DurableOutboxStatus.attention);
        expect(record.lastError, OpRejectionReason.deleted.wireName);
        expect(record.latestServerRevision, 2);
      }
      return (container, notifier);
    }

    test('an element edit comes back as an add over the tombstone', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      const patch = ElementPatchOp(
        opId: 'move-element',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 4,
        expectedElementRevision: 1,
      );
      final key = EntitySyncKey.forStrategyOp(patch)!;
      final (container, notifier) = await refused(repository, store, [patch]);

      await notifier.retryRejected(flushImmediately: false);

      final restore =
          container.read(strategyOpQueueProvider).queuedByEntityKey[key]!;
      expect(
        restore.pending.op,
        isA<ElementAddOp>()
            .having((op) => op.elementPublicId, 'elementPublicId', 'element-1')
            .having((op) => op.pagePublicId, 'pagePublicId', 'page-1')
            .having((op) => op.payload, 'payload', {'value': 'moved'})
            .having((op) => op.sortIndex, 'sortIndex', 4)
            .having(
              (op) => op.expectedElementRevision,
              'expectedElementRevision',
              2,
            ),
      );
      expect(restore.pending.op.opId, isNot(patch.opId));
      expect(
        store.load().records.single.pending.op.opId,
        restore.pending.op.opId,
      );

      await notifier.flushNow();
      await _settle();

      expect(repository.restored.keys, ['element-1']);
      expect(repository.restored['element-1']!.opId, restore.pending.op.opId);
      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.queuedByEntityKey, isEmpty);
      expect(current.lastError, isNull);
      expect(store.load().records, isEmpty);
    });

    test('a lineup edit comes back as an add over the tombstone', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      final payload = _lineupAdd(opId: 'unused', name: 'moved').payload;
      final patch = LineupPatchOp(
        opId: 'move-lineup',
        lineupPublicId: 'k',
        pagePublicId: 'page-1',
        payload: payload,
        sortIndex: 3,
        expectedLineupRevision: 1,
      );
      final key = EntitySyncKey.forStrategyOp(patch)!;
      final (container, notifier) = await refused(repository, store, [patch]);

      await notifier.retryRejected(flushImmediately: false);

      final restore =
          container.read(strategyOpQueueProvider).queuedByEntityKey[key]!;
      expect(
        restore.pending.op,
        isA<LineupAddOp>()
            .having((op) => op.lineupPublicId, 'lineupPublicId', 'k')
            .having((op) => op.pagePublicId, 'pagePublicId', 'page-1')
            .having((op) => op.payload, 'payload', payload)
            .having((op) => op.sortIndex, 'sortIndex', 3)
            .having(
              (op) => op.expectedLineupRevision,
              'expectedLineupRevision',
              2,
            ),
      );
      expect(restore.pending.op.opId, isNot(patch.opId));

      await notifier.flushNow();
      await _settle();

      expect(repository.restored.keys, ['k']);
      expect(repository.restored['k']!.opId, restore.pending.op.opId);
      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.queuedByEntityKey, isEmpty);
      expect(store.load().records, isEmpty);
    });

    test('a reorder, or an edit without its place, cannot come back', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      final ops = <StrategyOp>[
        const ElementReorderOp(
          opId: 'reorder-element',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          sortIndex: 2,
          expectedElementRevision: 1,
        ),
        const LineupReorderOp(
          opId: 'reorder-lineup',
          lineupPublicId: 'k',
          pagePublicId: 'page-1',
          sortIndex: 2,
          expectedLineupRevision: 1,
        ),
        // A patch that does not say where the element sits.
        const ElementPatchOp(
          opId: 'patch-no-sort',
          elementPublicId: 'element-2',
          pagePublicId: 'page-1',
          payload: {'value': 'moved'},
          expectedElementRevision: 1,
        ),
      ];
      final (container, notifier) = await refused(repository, store, ops);

      await notifier.retryRejected(flushImmediately: false);
      // Keep mine says why it could not help, not that a revision is missing.
      expect(
        container.read(strategyOpQueueProvider).lastError,
        teammateDeletedCannotRestoreMessage,
      );
      await notifier.flushNow();
      await _settle();

      final current = container.read(strategyOpQueueProvider);
      expect(current.queuedByEntityKey, isEmpty);
      expect(
        {
          for (final intent in current.attentionByEntityKey.values)
            intent.pending.op.opId,
        },
        {for (final op in ops) op.opId},
      );
      expect(current.lastError, isNotNull);
      expect(repository.calls, hasLength(1));
      expect(repository.restored, isEmpty);
      final durable = store.load().records;
      expect(
        {for (final record in durable) record.pending.op.opId},
        {for (final op in ops) op.opId},
      );
      for (final record in durable) {
        expect(record.status, DurableOutboxStatus.attention);
        expect(record.lastError, OpRejectionReason.deleted.wireName);
      }
    });

    test(
        'work deleted on both sides is settled, and keep mine cannot revive it',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      const elementPatch = ElementPatchOp(
        opId: 'move-element',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 4,
        expectedElementRevision: 1,
      );
      final lineupPatch = LineupPatchOp(
        opId: 'move-lineup',
        lineupPublicId: 'k',
        pagePublicId: 'page-1',
        payload: _lineupAdd(opId: 'unused', name: 'moved').payload,
        sortIndex: 3,
        expectedLineupRevision: 1,
      );
      // Refused alongside them, and not deleted on the canvas.
      const unrelatedPatch = ElementPatchOp(
        opId: 'move-other',
        elementPublicId: 'element-2',
        pagePublicId: 'page-1',
        payload: {'value': 'other'},
        sortIndex: 5,
        expectedElementRevision: 1,
      );
      final elementKey = EntitySyncKey.forStrategyOp(elementPatch)!;
      final lineupKey = EntitySyncKey.forStrategyOp(lineupPatch)!;
      final unrelatedKey = EntitySyncKey.forStrategyOp(unrelatedPatch)!;
      final (container, notifier) = await refused(
        repository,
        store,
        [elementPatch, lineupPatch, unrelatedPatch],
      );

      // The user deleted element-1 and lineup k on the canvas.
      final settled = await notifier.settleAttention({elementKey, lineupKey});

      expect(settled, {elementKey, lineupKey});
      expect(
        container.read(strategyOpQueueProvider).attentionByEntityKey.keys,
        [unrelatedKey],
      );
      expect(
        [for (final record in store.load().records) record.entityKey],
        [unrelatedKey],
      );

      // Keep mine brings back only the work still in attention.
      await notifier.retryRejected(flushImmediately: false);
      expect(
        container.read(strategyOpQueueProvider).queuedByEntityKey.keys,
        [unrelatedKey],
      );
      await notifier.flushNow();
      await _settle();
      expect(repository.restored.keys, ['element-2']);
      expect(repository.calls, hasLength(2));
      expect(
        [for (final op in repository.calls.last) op.entityPublicId],
        ['element-2'],
      );

      // Settling adopts nothing from the server: a later edit to a settled
      // entity is queued and sent as any other.
      const restore = ElementAddOp(
        opId: 'add-again',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'again'},
        sortIndex: 4,
        expectedElementRevision: 2,
      );
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {elementKey: restore},
        clearMissing: false,
      );
      expect(
        container
            .read(strategyOpQueueProvider)
            .queuedByEntityKey[elementKey]!
            .pending
            .op
            .payload,
        {'value': 'again'},
      );
      await notifier.flushNow();
      await _settle();
      expect(repository.restored.keys, ['element-2', 'element-1']);
      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey, isEmpty);
      expect(current.queuedByEntityKey, isEmpty);
      expect(store.load().records, isEmpty);
    });

    test(
        'work deleted on both sides stays in attention when its refusal was '
        'not a deletion', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      // Refused as deleted: a teammate deleted element-1.
      const elementPatch = ElementPatchOp(
        opId: 'move-element',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 4,
        expectedElementRevision: 1,
      );
      // Refused as a revision mismatch: an add of lineup group k against a
      // revision it no longer has. That says nothing about whether the
      // server deleted k, never had it, or holds it elsewhere.
      final staleAdd = LineupAddOp(
        opId: 'stale-add',
        lineupPublicId: 'k',
        pagePublicId: 'page-1',
        payload: _lineupAdd(opId: 'unused').payload,
        sortIndex: 0,
        expectedLineupRevision: 1,
      );
      final elementKey = EntitySyncKey.forStrategyOp(elementPatch)!;
      final lineupKey = EntitySyncKey.forStrategyOp(staleAdd)!;
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(elementPatch, flushImmediately: false);
      await notifier.enqueue(staleAdd, flushImmediately: false);
      await notifier.flushNow();
      await _settle();
      expect(
        container.read(strategyOpQueueProvider).attentionByEntityKey.keys,
        unorderedEquals([elementKey, lineupKey]),
      );
      expect(notifier.refusedAsDeleted(elementKey), isTrue);
      expect(notifier.refusedAsDeleted(lineupKey), isFalse);

      // The user deleted both on the canvas.
      final settled = await notifier.settleAttention({elementKey, lineupKey});

      // Only the work refused as deleted is dropped; the other still waits,
      // in memory and on disk, for the user to choose.
      expect(settled, {elementKey});
      expect(
        container.read(strategyOpQueueProvider).attentionByEntityKey.keys,
        [lineupKey],
      );
      expect(container.read(strategyOpQueueProvider).needsAttention, isTrue);
      final records = store.load().records;
      expect([for (final record in records) record.entityKey], [lineupKey]);
      expect(records.single.status, DurableOutboxStatus.attention);
      expect(records.single.lastError,
          OpRejectionReason.revisionMismatch.wireName);
    });

    test('a conditional discard drops only the work still as the user saw it',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      const first = ElementPatchOp(
        opId: 'move-1',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 4,
        expectedElementRevision: 1,
      );
      const second = ElementPatchOp(
        opId: 'move-2',
        elementPublicId: 'element-2',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 5,
        expectedElementRevision: 1,
      );
      final firstKey = EntitySyncKey.forStrategyOp(first)!;
      final secondKey = EntitySyncKey.forStrategyOp(second)!;
      final (container, notifier) =
          await refused(repository, store, [first, second]);
      // What the user chose to discard: both refused edits, nothing behind.
      final seen = {
        firstKey: ('move-1', null),
        secondKey: ('move-2', null),
      };

      // Then the user edits element-2 again; it waits behind the refusal.
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          secondKey: const ElementPatchOp(
            opId: 'newer',
            elementPublicId: 'element-2',
            pagePublicId: 'page-1',
            payload: {'value': 'newer'},
            sortIndex: 5,
            expectedElementRevision: 1,
          ),
        },
        clearMissing: false,
      );
      expect(
        container
            .read(strategyOpQueueProvider)
            .successorByEntityKey[secondKey]!
            .pending
            .op
            .opId,
        'newer',
      );

      final discarded =
          await notifier.discardRejected({firstKey, secondKey}, onlyIf: seen);

      // element-1's work is as seen, so it goes; element-2's changed, so it
      // stays, the newer edit with it, in memory and on disk.
      expect(discarded, {firstKey});
      final current = container.read(strategyOpQueueProvider);
      expect(current.attentionByEntityKey.keys, [secondKey]);
      expect(current.successorByEntityKey[secondKey]!.pending.op.opId, 'newer');
      final records = store.load().records;
      expect([for (final record in records) record.entityKey], [secondKey]);
      expect(records.single.pending.op.opId, 'move-2');
      expect(records.single.successorPending!.op.opId, 'newer');
    });

    test('discarding instead waits for the server copy to be adopted',
        () async {
      // The contrast that makes settling distinct: after Use cloud the
      // canvas is about to be redrawn from the server, so desired work for
      // the entity is ignored until adoption completes.
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _TombstoneRepository();
      const elementPatch = ElementPatchOp(
        opId: 'move-element',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'moved'},
        sortIndex: 4,
        expectedElementRevision: 1,
      );
      final key = EntitySyncKey.forStrategyOp(elementPatch)!;
      final (container, notifier) =
          await refused(repository, store, [elementPatch]);

      await notifier.discardRejected({key});
      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {
          key: const ElementAddOp(
            opId: 'add-again',
            elementPublicId: 'element-1',
            pagePublicId: 'page-1',
            payload: {'value': 'again'},
            sortIndex: 4,
            expectedElementRevision: 2,
          ),
        },
        clearMissing: false,
      );

      expect(
        container.read(strategyOpQueueProvider).queuedByEntityKey,
        isEmpty,
      );
    });
  });

  group('a server that needs a newer Icarus', () {
    const key = EntitySyncKey.element('page-1', 'element-1');

    DurableOutboxRecord saved(
      ElementPatchOp op, {
      required DurableOutboxStatus status,
      required int attempts,
      required String lastError,
    }) {
      return DurableOutboxRecord(
        accountId: 'account-a',
        strategyPublicId: 'strategy-1',
        entityKey: EntitySyncKey.forStrategyOp(op)!,
        pending: PendingOp(
          op: op,
          clientId: 'old-client',
          attempts: attempts,
          lastAttemptAt: DateTime(2026),
        ),
        status: status,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        lastError: lastError,
      );
    }

    test('holds the work, uncounted, however often it is refused', () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _UpgradeRequiredRepository();
      // Each start is a reload into a build the server still refuses; more
      // starts than the pause limit allows failures.
      for (var start = 0; start < 10; start++) {
        final container = _cloudQueueContainer(
          store: store,
          repository: repository,
        );
        final notifier = container.read(strategyOpQueueProvider.notifier)
          ..setActiveStrategy('strategy-1', accountId: 'account-a');
        if (start == 0) await notifier.enqueue(_cloudElementOp());
        await notifier.flushNow();
        await _settle();
        // Held after the refusal: no second send in this process.
        await notifier.flushNow();
        await _settle();

        expect(container.read(clientUpgradeRequiredProvider), isTrue);
        final current = container.read(strategyOpQueueProvider);
        expect(current.pausedByEntityKey, isEmpty);
        expect(current.attentionByEntityKey, isEmpty);
        expect(current.needsAttention, isFalse);
        expect(current.queuedByEntityKey[key]!.pending.op.opId, 'op-1');
        expect(current.queuedByEntityKey[key]!.pending.attempts, 0);
        expect(current.lastError, clientUpgradeRequiredQueueError);
        container.dispose();
      }

      expect(repository.calls, 10);
      final durable = store.load().records.single;
      expect(durable.status, DurableOutboxStatus.queued);
      expect(durable.pending.attempts, 0);
      expect(
        durable.pending.op.toConvexJson(),
        _cloudElementOp().toConvexJson(),
      );
      expect(durable.pending.clientId, isNotEmpty);
    });

    test('resumes work an older build paused for it, and only that', () async {
      final store = MemoryDurableStrategyOutboxStore();
      const refused = ElementPatchOp(
        opId: 'refused',
        elementPublicId: 'element-1',
        pagePublicId: 'page-1',
        payload: {'value': 'kept'},
        expectedElementRevision: 1,
      );
      const failing = ElementPatchOp(
        opId: 'failing',
        elementPublicId: 'element-2',
        pagePublicId: 'page-1',
        payload: {'value': 'other'},
        expectedElementRevision: 1,
      );
      // As the protocol 3 web build kept them after eight refusals, and one
      // paused for an ordinary failure.
      await store.put(saved(
        refused,
        status: DurableOutboxStatus.paused,
        attempts: 8,
        lastError: 'ConvexFunctionException(CLIENT_UPGRADE_REQUIRED, '
            'Client upgrade required)',
      ));
      await store.put(saved(
        failing,
        status: DurableOutboxStatus.paused,
        attempts: 8,
        // A different refusal whose text merely mentions the code.
        lastError: 'ConvexFunctionException(INVALID_PAYLOAD, name was '
            'CLIENT_UPGRADE_REQUIRED)',
      ));
      final repository = _RecordingAckRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');

      final loaded = container.read(strategyOpQueueProvider);
      expect(
        loaded.queuedByEntityKey[key]!.pending.op.toConvexJson(),
        refused.toConvexJson(),
      );
      expect(loaded.queuedByEntityKey[key]!.pending.clientId, 'old-client');
      expect(loaded.queuedByEntityKey[key]!.pending.attempts, 0);
      expect(
        loaded.pausedByEntityKey.values.single.pending.op.opId,
        'failing',
      );

      await notifier.flushNow();
      await _settle();

      expect(
        repository.calls.map((ops) => ops.map((op) => op.opId).toList()),
        [
          ['refused'],
        ],
      );
      final left = store.load().records.single;
      expect(left.pending.op.toConvexJson(), failing.toConvexJson());
      expect(left.status, DurableOutboxStatus.paused);
      expect(left.pending.attempts, 8);
    });

    test('sends the held work once the server accepts this build again',
        () async {
      final store = MemoryDurableStrategyOutboxStore();
      final repository = _UpgradeRequiredRepository();
      final container = _cloudQueueContainer(
        store: store,
        repository: repository,
      );
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      await notifier.enqueue(_cloudElementOp());
      await notifier.flushNow();
      await _settle();
      expect(container.read(clientUpgradeRequiredProvider), isTrue);
      expect(repository.calls, 1);

      // A rolled-back deploy: the server accepts this protocol again.
      repository.refusing = false;
      await container.read(clientUpgradeRequiredProvider.notifier).recheck();
      await _settle();

      expect(container.read(clientUpgradeRequiredProvider), isFalse);
      expect(repository.calls, 2);
      expect(store.load().records, isEmpty);
      expect(container.read(strategyOpQueueProvider).pending, isEmpty);
    });
  });

  group('field merge sending', () {
    const key = EntitySyncKey.element('page-1', 'element-1');
    const merge = FieldMerge(fields: ['isAlly'], base: {'isAlly': true});

    ElementPatchOp patch(String opId, {bool isAlly = false}) => ElementPatchOp(
          opId: opId,
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'agent',
            'payloadVersion': 1,
            'data': {'id': 'element-1', 'isAlly': isAlly},
          },
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: merge,
        );

    const delete = ElementDeleteOp(
      opId: 'delete-1',
      elementPublicId: 'element-2',
      pagePublicId: 'page-1',
      expectedElementRevision: 1,
    );

    /// A queue sending to [repository], connected while [online] holds.
    (ProviderContainer, StrategyOpQueueNotifier) open(
      DurableStrategyOutboxStore store,
      ConvexStrategyRepository repository,
      StateProvider<bool> online,
    ) {
      final container = ProviderContainer(overrides: [
        durableStrategyOutboxStoreProvider.overrideWithValue(store),
        convexStrategyRepositoryProvider.overrideWithValue(repository),
        authProvider.overrideWith(_CloudReadyAuthProvider.new),
        convexConnectionSnapshotProvider
            .overrideWith((ref) => ref.watch(online)),
      ]);
      addTearDown(container.dispose);
      final notifier = container.read(strategyOpQueueProvider.notifier)
        ..setActiveStrategy('strategy-1', accountId: 'account-a');
      return (container, notifier);
    }

    test('work made and sent while connected wins as the last write', () async {
      final online = StateProvider<bool>((ref) => true);
      final repository = _ScriptedRepository();
      final (_, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);

      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      await notifier.enqueue(delete, flushImmediately: false);
      await notifier.flushNow();

      final sent = repository.calls.expand((batch) => batch).toList();
      expect(sent.whereType<ElementPatchOp>().single.merge?.base, isNull);
      expect(sent.whereType<ElementDeleteOp>().single.lastWriterWins, isTrue);
    });

    test('work queued while disconnected carries its base', () async {
      final online = StateProvider<bool>((ref) => false);
      final repository = _ScriptedRepository();
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);

      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      await notifier.enqueue(delete, flushImmediately: false);
      container.read(online.notifier).state = true;
      await notifier.flushNow();

      final sent = repository.calls.expand((batch) => batch).toList();
      expect(sent.whereType<ElementPatchOp>().single.merge?.base,
          {'isAlly': true});
      expect(sent.whereType<ElementDeleteOp>().single.lastWriterWins, isFalse);
    });

    test('a disconnect before sending turns live work into checked work',
        () async {
      final online = StateProvider<bool>((ref) => true);
      final repository = _ScriptedRepository();
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);

      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = false;
      await Future<void>.delayed(Duration.zero);
      container.read(online.notifier).state = true;
      await notifier.flushNow();

      expect(
        repository.calls.single.single.merge?.base,
        {'isAlly': true},
      );
    });

    test('an edit folded into work that waited offline stays checked',
        () async {
      final online = StateProvider<bool>((ref) => false);
      final repository = _ScriptedRepository();
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);

      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      await notifier.enqueue(patch('op-2', isAlly: true),
          flushImmediately: false);
      await notifier.flushNow();

      expect(repository.calls.single.single.merge?.base, isNotNull);
    });

    test('work recovered after a restart carries its base', () async {
      final online = StateProvider<bool>((ref) => true);
      final store = MemoryDurableStrategyOutboxStore();
      final (first, firstQueue) = open(store, _ScriptedRepository(), online);
      await firstQueue.enqueue(patch('op-1'), flushImmediately: false);
      first.dispose();

      final repository = _ScriptedRepository();
      final (_, notifier) = open(store, repository, online);
      await notifier.flushNow();
      // The restored queue drains in the background.
      for (var i = 0; i < 20 && repository.calls.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(
        repository.calls.single.single.merge?.base,
        {'isAlly': true},
      );
    });

    test(
        "Keep mine after a field collision checks against the server's "
        'value, not the old base', () async {
      final online = StateProvider<bool>((ref) => false);
      final repository =
          _ScriptedRepository(refusals: [OpRejectionReason.fieldConflict]);
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      await notifier.flushNow();
      expect(container.read(strategyOpQueueProvider).attentionByEntityKey,
          contains(key));

      await notifier.retryRejected(flushImmediately: false);
      await notifier.flushNow();

      // A teammate changing it again after the refusal would still ask.
      final kept = repository.calls.last.single;
      expect(kept.merge?.fields, ['isAlly']);
      expect(kept.merge?.base, {'isAlly': 'theirs'});
      expect(container.read(strategyOpQueueProvider).attentionByEntityKey,
          isEmpty);
    });

    test('Keep mine after a merge that could not stand sends the whole item',
        () async {
      final online = StateProvider<bool>((ref) => true);
      final repository =
          _ScriptedRepository(refusals: [OpRejectionReason.mergeInvalid]);
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      await notifier.flushNow();

      await notifier.retryRejected(flushImmediately: false);
      await notifier.flushNow();

      final kept = repository.calls.last.single as ElementPatchOp;
      expect(kept.merge, isNull);
      expect(kept.expectedElementRevision, 5);
      expect(container.read(strategyOpQueueProvider).attentionByEntityKey,
          isEmpty);
    });

    test("a successor's base becomes what its predecessor wrote", () async {
      final online = StateProvider<bool>((ref) => false);
      final store = MemoryDurableStrategyOutboxStore();
      final gate = Completer<void>();
      final repository = _ScriptedRepository(hold: gate);
      final (container, notifier) = open(store, repository, online);
      // Queued offline, so both stay checked.
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      final sending = notifier.flushNow();
      await repository.started.future;
      // A later edit sets the field back, and waits behind the first.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: patch('op-2', isAlly: true).payload,
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: merge,
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;

      final promoted = store.load().records.single.pending.op;
      expect(promoted.merge?.base, {'isAlly': false});
      expect(promoted.expectedRevision, 2);
    });

    test('a change set back while the first send is on its way is sent back',
        () async {
      final online = StateProvider<bool>((ref) => true);
      final gate = Completer<void>();
      final repository = _ScriptedRepository(hold: gate);
      final store = MemoryDurableStrategyOutboxStore();
      final (_, notifier) = open(store, repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      final sending = notifier.flushNow();
      await repository.started.future;
      // Set back to what the user first saw: against that, nothing changed.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: patch('op-2', isAlly: true).payload,
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: const FieldMerge(fields: [], base: {}),
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;
      await notifier.flushNow();
      for (var i = 0; i < 50 && repository.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // The server holds the first send's value now, so it is named again.
      final setBack = repository.calls.last.single;
      expect(setBack.merge?.fields, ['isAlly']);
      expect(((setBack.payload as Map)['data'] as Map)['isAlly'], isTrue);
    });

    test(
        'work made offline stays checked though it is queued after reconnecting',
        () async {
      final online = StateProvider<bool>((ref) => false);
      final gate = Completer<void>();
      final store = _GatedPutStore(gate);
      final repository = _ScriptedRepository();
      final (container, notifier) = open(store, repository, online);

      // Made offline; its write waits behind the store.
      final queued = notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await queued;
      await notifier.flushNow();

      expect(repository.calls.single.single.merge?.base, {'isAlly': true});
    });

    test(
        "a promoted successor's base comes only from what its predecessor wrote",
        () async {
      final online = StateProvider<bool>((ref) => false);
      final store = MemoryDurableStrategyOutboxStore();
      final gate = Completer<void>();
      final repository = _ScriptedRepository(hold: gate);
      final (container, notifier) = open(store, repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      final sending = notifier.flushNow();
      await repository.started.future;
      // The successor also restacks the item and changes a field the
      // predecessor did not write, whose base was absent.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'agent',
            'payloadVersion': 1,
            'data': {
              'id': 'element-1',
              'isAlly': false,
              'weapon': 'vandal',
            },
          },
          sortIndex: 4,
          expectedElementRevision: 1,
          merge: const FieldMerge(
            fields: ['isAlly', 'weapon', placeMergeField],
            base: {'isAlly': true, placeMergeField: 0},
          ),
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;

      final promoted = store.load().records.single.pending.op;
      // It also names the field its predecessor wrote, based on what that
      // wrote; its own fields keep the base they had (the place's, and the
      // weapon absent, as the server has it).
      expect(promoted.merge?.fields, [placeMergeField, 'isAlly', 'weapon']);
      expect(promoted.merge?.base, {placeMergeField: 0, 'isAlly': false});
    });

    test(
        'Keep mine after the first send is refused keeps both its change '
        'and the one made behind it', () async {
      final online = StateProvider<bool>((ref) => false);
      final gate = Completer<void>();
      final repository = _ScriptedRepository(
          hold: gate, refusals: [OpRejectionReason.fieldConflict]);
      final (container, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);
      // Made offline: the side changes.
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      container.read(online.notifier).state = true;
      final sending = notifier.flushNow();
      await repository.started.future;
      // While it is on its way, the user also equips a weapon.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'agent',
            'payloadVersion': 1,
            'data': {'id': 'element-1', 'isAlly': false, 'weapon': 'vandal'},
          },
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: const FieldMerge(
            fields: ['isAlly', 'weapon'],
            base: {'isAlly': true},
          ),
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;
      expect(container.read(strategyOpQueueProvider).attentionByEntityKey,
          contains(key));

      await notifier.retryRejected(flushImmediately: false);
      await notifier.flushNow();

      final kept = repository.calls.last.single;
      expect(kept.merge?.fields, ['isAlly', 'weapon']);
      expect(((kept.payload as Map)['data'] as Map)['isAlly'], isFalse);
    });

    test('a whole successor after a merge keeps the revision it was made from',
        () async {
      final online = StateProvider<bool>((ref) => true);
      final store = MemoryDurableStrategyOutboxStore();
      final gate = Completer<void>();
      final repository = _ScriptedRepository(hold: gate);
      final (_, notifier) = open(store, repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      final sending = notifier.flushNow();
      await repository.started.future;
      // The element is turned into something else: a whole write.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'agent',
            'payloadVersion': 1,
            'data': {'id': 'element-1', 'kind': 'viewCone'},
          },
          sortIndex: 0,
          expectedElementRevision: 1,
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;

      final promoted = store.load().records.single.pending.op;
      expect(promoted.merge, isNull);
      // Not the merge's revision (2), which also holds fields never drawn.
      expect(promoted.expectedRevision, 1);
    });

    test('a successor behind recovered work keeps the fields the user changed',
        () async {
      final online = StateProvider<bool>((ref) => true);
      final store = MemoryDurableStrategyOutboxStore();
      final (first, firstQueue) = open(store, _ScriptedRepository(), online);
      // Saved before a restart: it changed the side.
      await firstQueue.enqueue(patch('op-1'), flushImmediately: false);
      first.dispose();

      final gate = Completer<void>();
      final repository = _ScriptedRepository(hold: gate);
      final (_, notifier) = open(store, repository, online);
      final sending = notifier.flushNow();
      await repository.started.future;
      // The canvas, drawn without the recovered side, moves the element.
      await notifier.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: {
            'kind': 'agent',
            'payloadVersion': 1,
            'data': {
              'id': 'element-1',
              'isAlly': true,
              'position': {'dx': 5.0, 'dy': 5.0},
            },
          },
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: const FieldMerge(fields: ['position'], base: {}),
        ),
        flushImmediately: false,
      );
      gate.complete();
      await sending;
      await notifier.flushNow();
      for (var i = 0; i < 50 && repository.calls.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      // The move does not undo the recovered side it never showed.
      final promoted = repository.calls[1].single;
      expect(promoted.merge?.fields, ['position']);
    });

    test('work a caller judged made offline stays checked', () async {
      final online = StateProvider<bool>((ref) => true);
      final repository = _ScriptedRepository();
      final (_, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);

      await notifier.syncDesiredOpsForPage(
        pageId: 'page-1',
        desiredOpsByEntityKey: {key: patch('op-1')},
        clearMissing: false,
        madeLive: null,
      );
      await notifier.flushNow();

      expect(repository.calls.single.single.merge?.base, {'isAlly': true});
    });

    test('a retry of live work is sent checked', () async {
      final online = StateProvider<bool>((ref) => true);
      final repository =
          _ScriptedRepository(refusals: [OpRejectionReason.fieldConflict]);
      final (_, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      await notifier.flushNow();
      expect(repository.calls.single.single.merge?.base, isNull);

      await notifier.retryRejected(flushImmediately: false);
      await notifier.flushNow();

      expect(repository.calls.last.single.merge?.base, {'isAlly': 'theirs'});
    });

    test('a change set back in flight is still sent after a restart', () async {
      final online = StateProvider<bool>((ref) => true);
      final store = MemoryDurableStrategyOutboxStore();
      final gate = Completer<void>();
      final (first, firstQueue) =
          open(store, _ScriptedRepository(hold: gate), online);
      await firstQueue.enqueue(patch('op-1'), flushImmediately: false);
      unawaited(firstQueue.flushNow());
      for (var i = 0;
          i < 50 &&
              store.load().records.single.status !=
                  DurableOutboxStatus.inFlight;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Set back while the first send is on its way; then the app closes
      // before its answer arrives.
      await firstQueue.enqueue(
        ElementPatchOp(
          opId: 'op-2',
          elementPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: patch('op-2', isAlly: true).payload,
          sortIndex: 0,
          expectedElementRevision: 1,
          merge: const FieldMerge(fields: [], base: {}),
        ),
        flushImmediately: false,
      );
      first.dispose();

      final repository = _ScriptedRepository();
      final (_, notifier) = open(store, repository, online);
      await notifier.flushNow();
      for (var i = 0; i < 50 && repository.calls.length < 2; i++) {
        await notifier.flushNow();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final setBack = repository.calls[1].single;
      expect(setBack.merge?.fields, ['isAlly']);
      expect(((setBack.payload as Map)['data'] as Map)['isAlly'], isTrue);
    });

    test('a send that failed is retried checked', () async {
      final online = StateProvider<bool>((ref) => true);
      final repository = _ScriptedRepository(failFirst: true);
      final (_, notifier) =
          open(MemoryDurableStrategyOutboxStore(), repository, online);
      await notifier.enqueue(patch('op-1'), flushImmediately: false);
      await notifier.flushNow();
      for (var i = 0; i < 100 && repository.calls.length < 2; i++) {
        await notifier.flushNow();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(repository.calls.first.single.merge?.base, isNull);
      expect(repository.calls[1].single.merge?.base, {'isAlly': true});
    });
  });
}

/// Lets sends already started, and the writes after them, finish.
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The server refusing this build's protocol, as it refuses every batch from
/// a client older than the current one.
class _UpgradeRequiredRepository extends ConvexStrategyRepository {
  _UpgradeRequiredRepository() : super(IcarusConvexApi(_UnusedTransport()));

  int calls = 0;
  bool refusing = true;

  @override
  Future<bool> serverAcceptsCloudProtocol() async => !refusing;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    calls += 1;
    if (!refusing) {
      return [for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2)];
    }
    throw const ConvexFunctionException(
      code: ConvexErrorCode.clientUpgradeRequired,
      rawCode: 'CLIENT_UPGRADE_REQUIRED',
      message: 'Client upgrade required',
    );
  }
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

/// An add of lineup [id] as one row, the shape this build sends.
LineupAddOp _lineupAdd({
  required String opId,
  String id = 'k',
  String pageId = 'page-1',
  String name = 'lineup',
}) {
  return LineupAddOp(
    opId: opId,
    lineupPublicId: id,
    pagePublicId: pageId,
    payload: cloudLineupsPayload({
      'id': id,
      'origins': [
        {'id': 'o', 'agent': <String, dynamic>{}},
      ],
      'landings': [
        {'id': 'l', 'ability': <String, dynamic>{}},
      ],
      'links': [
        {'id': id, 'originId': 'o', 'landingId': 'l', 'name': name},
      ],
    }),
    sortIndex: 0,
  );
}

/// A link add as builds before one row per lineup wrote it to their outbox:
/// its own row, keyed `lineupLink:<id>`, naming its origin and landing.
LineupAddOp _retiredLinkAdd() {
  return const LineupAddOp(
    opId: 'old-link-add',
    lineupPublicId: 'lineupLink:k',
    pagePublicId: 'page-1',
    payload: {
      'kind': 'lineupLink',
      'payloadVersion': 1,
      'data': {'id': 'k', 'originId': 'o', 'landingId': 'l'},
    },
    sortIndex: 0,
  );
}

/// [op] as saved in the durable outbox of account-a's strategy-1.
DurableOutboxRecord _savedRecord(
  StrategyOp op, {
  DurableOutboxStatus status = DurableOutboxStatus.queued,
  String? lastError,
  int? latestServerRevision,
}) {
  return DurableOutboxRecord(
    accountId: 'account-a',
    strategyPublicId: 'strategy-1',
    entityKey: EntitySyncKey.forStrategyOp(op)!,
    pending: PendingOp(op: op, clientId: 'client-a'),
    status: status,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    lastError: lastError,
    latestServerRevision: latestServerRevision,
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
    String? accountSubject,
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
    String? accountSubject,
  }) async {
    calls.add(List<StrategyOp>.from(ops));
    if (calls.length == 2 && !secondCall.isCompleted) secondCall.complete();
    return [
      for (final op in ops) AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

/// Refuses every op as the server refuses a lineup whose row lives on
/// another page.
class _FailingLineupRepository extends ConvexStrategyRepository {
  _FailingLineupRepository({
    this.code = 'LINEUP_PAGE_MISMATCH',
    this.message = lineupPageMismatchMessage,
  }) : super(IcarusConvexApi(_UnusedTransport()));

  final String code;
  final String message;

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    return [
      for (final op in ops)
        FailedOpAck(
          opId: op.opId,
          code: code,
          rawCode: code,
          message: message,
        ),
    ];
  }
}

/// A server on which a teammate deleted elements element-1 and element-2 and
/// lineup k, each tombstone at revision 2. A patch or reorder of a deleted
/// row is refused as deleted; an add expecting the tombstone's revision
/// brings the row back.
class _TombstoneRepository extends ConvexStrategyRepository {
  _TombstoneRepository() : super(IcarusConvexApi(_UnusedTransport()));

  final List<List<StrategyOp>> calls = [];
  final _deleted = {'element-1', 'element-2', 'k'};

  /// The add that restored each row, by its id.
  final Map<String, StrategyOp> restored = {};

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    calls.add(List<StrategyOp>.from(ops));
    return [for (final op in ops) _apply(op)];
  }

  OpAck _apply(StrategyOp op) {
    final id = op.entityPublicId!;
    if (!_deleted.contains(id)) return AppliedOpAck(opId: op.opId, revision: 2);
    if (op.kind == StrategyOpKind.add && op.expectedRevision == 2) {
      _deleted.remove(id);
      restored[id] = op;
      return AppliedOpAck(opId: op.opId, revision: 3);
    }
    return RejectedOpAck(
      opId: op.opId,
      rejectionReason: op.kind == StrategyOpKind.add
          ? OpRejectionReason.revisionMismatch
          : OpRejectionReason.deleted,
      current: op.entityType == StrategyOpEntityType.lineup
          ? const LineupCurrentSnapshot(revision: 2, value: {})
          : const ElementCurrentSnapshot(revision: 2, value: {}),
    );
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
    String? accountSubject,
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

/// Holds the first record removal (an accepted op leaving the outbox) until
/// [releaseRemove].
class _GatedRemoveStore extends MemoryDurableStrategyOutboxStore {
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

/// Holds the write that promotes a successor (its record's pending op
/// changes and the successor goes) until [releasePromotion].
class _GatedPromotionStore extends MemoryDurableStrategyOutboxStore {
  final promotionStarted = Completer<void>();
  final releasePromotion = Completer<void>();

  @override
  Future<void> put(DurableOutboxRecord record) async {
    if (record.successorPending == null && !promotionStarted.isCompleted) {
      promotionStarted.complete();
      await releasePromotion.future;
    }
    await super.put(record);
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

class _OversizedParkingFailureStore extends MemoryDurableStrategyOutboxStore {
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

/// Records each batch it is sent, holds the first one while [hold] is
/// unfinished, and refuses its first ops with [refusals] in turn (each at
/// revision 5), accepting the rest at revision 2.
class _ScriptedRepository extends ConvexStrategyRepository {
  _ScriptedRepository({
    List<OpRejectionReason> refusals = const [],
    this.hold,
    this.failFirst = false,
  })  : _refusals = [...refusals],
        super(IcarusConvexApi(_UnusedTransport()));

  /// Whether the first batch fails in transit, as a dropped request does.
  bool failFirst;

  final List<OpRejectionReason> _refusals;
  Completer<void>? hold;
  final List<List<StrategyOp>> calls = [];
  final started = Completer<void>();

  @override
  Future<List<OpAck>> applyBatch({
    required String strategyPublicId,
    required String clientId,
    required List<StrategyOp> ops,
    String? accountSubject,
  }) async {
    calls.add(List<StrategyOp>.from(ops));
    if (!started.isCompleted) started.complete();
    if (hold case final gate?) {
      hold = null;
      await gate.future;
    }
    if (failFirst) {
      failFirst = false;
      throw const SocketException('The request was lost.');
    }
    return [
      for (final op in ops)
        if (_refusals.isNotEmpty)
          RejectedOpAck(
            opId: op.opId,
            rejectionReason: _refusals.removeAt(0),
            current: ElementCurrentSnapshot(
              revision: 5,
              value: const {
                'kind': 'agent',
                'payloadVersion': 1,
                'data': {'id': 'element-1', 'isAlly': 'theirs'},
              },
            ),
          )
        else
          AppliedOpAck(opId: op.opId, revision: 2),
    ];
  }
}

/// Holds every write until [gate] completes.
class _GatedPutStore extends MemoryDurableStrategyOutboxStore {
  _GatedPutStore(this.gate);

  final Completer<void> gate;

  @override
  Future<void> put(DurableOutboxRecord record) async {
    await gate.future;
    await super.put(record);
  }
}
