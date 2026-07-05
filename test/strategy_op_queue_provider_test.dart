import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';

void main() {
  group('Entity sync keys', () {
    test('round trips page ids that contain delimiters', () {
      const pageId = 'strategy-1:page:1';
      const elementId = 'element-1';
      const lineupId = 'lineup-1';
      const strategyKey = EntitySyncKey.strategy();
      const pageKey = EntitySyncKey.pageSettings(pageId);
      const elementKey = EntitySyncKey.element(pageId, elementId);
      const lineupKey = EntitySyncKey.lineup(pageId, lineupId);

      expect(strategyKey.kind, EntitySyncKeyKind.strategy);
      expect(strategyKey.overlayType, isNull);
      expect(pageKey.kind, EntitySyncKeyKind.pageSettings);
      expect(pageKey.overlayType, ActivePageOverlayEntityType.pageSettings);
      expect(pageKey.pageId, pageId);
      expect(elementKey.pageId, pageId);
      expect(elementKey.kind, EntitySyncKeyKind.element);
      expect(elementKey.overlayType, ActivePageOverlayEntityType.element);
      expect(elementKey.entityId, elementId);
      expect(lineupKey.pageId, pageId);
      expect(lineupKey.kind, EntitySyncKeyKind.lineup);
      expect(lineupKey.overlayType, ActivePageOverlayEntityType.lineup);
      expect(lineupKey.entityId, lineupId);
    });
  });

  group('StrategyOpQueueNotifier coalescing', () {
    late ProviderContainer container;
    late StrategyOpQueueNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      notifier = container.read(strategyOpQueueProvider.notifier);
      notifier.setActiveStrategy('strategy-1');
    });

    tearDown(() {
      container.dispose();
    });

    test('coalesces add followed by patch into one add op', () {
      notifier.enqueue(
        const StrategyOp(
          opId: 'add-1',
          kind: StrategyOpKind.add,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: '{"value":"a"}',
          sortIndex: 0,
        ),
      );
      notifier.enqueue(
        const StrategyOp(
          opId: 'patch-1',
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: '{"value":"b"}',
          sortIndex: 2,
        ),
      );

      final pending = container.read(strategyOpQueueProvider).pending;
      expect(pending, hasLength(1));
      expect(pending.single.op.kind, StrategyOpKind.add);
      expect(pending.single.op.payload, '{"value":"b"}');
      expect(pending.single.op.sortIndex, 2);
    });

    test('coalesces repeated patches to the latest payload', () {
      notifier.enqueue(
        const StrategyOp(
          opId: 'patch-1',
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: 'lineup-1',
          pagePublicId: 'page-1',
          payload: '{"value":"a"}',
          sortIndex: 0,
        ),
      );
      notifier.enqueue(
        const StrategyOp(
          opId: 'patch-2',
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.lineup,
          entityPublicId: 'lineup-1',
          pagePublicId: 'page-1',
          payload: '{"value":"b"}',
          sortIndex: 1,
        ),
      );

      final pending = container.read(strategyOpQueueProvider).pending;
      expect(pending, hasLength(1));
      expect(pending.single.op.kind, StrategyOpKind.patch);
      expect(pending.single.op.payload, '{"value":"b"}');
      expect(pending.single.op.sortIndex, 1);
    });

    test('removes add when followed by delete for same entity', () {
      notifier.enqueue(
        const StrategyOp(
          opId: 'add-1',
          kind: StrategyOpKind.add,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: '{"value":"a"}',
          sortIndex: 0,
        ),
      );
      notifier.enqueue(
        const StrategyOp(
          opId: 'delete-1',
          kind: StrategyOpKind.delete,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-1',
          pagePublicId: 'page-1',
        ),
      );

      final pending = container.read(strategyOpQueueProvider).pending;
      expect(pending, isEmpty);
    });

    test('preserves unrelated pending ops', () {
      notifier.enqueue(
        const StrategyOp(
          opId: 'patch-1',
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-1',
          pagePublicId: 'page-1',
          payload: '{"value":"a"}',
          sortIndex: 0,
        ),
      );
      notifier.enqueue(
        const StrategyOp(
          opId: 'patch-2',
          kind: StrategyOpKind.patch,
          entityType: StrategyOpEntityType.element,
          entityPublicId: 'element-2',
          pagePublicId: 'page-1',
          payload: '{"value":"b"}',
          sortIndex: 1,
        ),
      );

      final pending = container.read(strategyOpQueueProvider).pending;
      expect(pending, hasLength(2));
      expect(
        pending.map((op) => op.op.entityPublicId),
        ['element-1', 'element-2'],
      );
    });
  });
}
