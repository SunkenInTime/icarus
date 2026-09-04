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
