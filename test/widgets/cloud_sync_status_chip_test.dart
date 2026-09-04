import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/cloud_sync_status_chip.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _CloudStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'cloud-strategy',
        strategyName: 'Cloud Strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );
}

class _SettledOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
      );
}

class _UnreliableOpQueue extends StrategyOpQueueNotifier {
  @override
  StrategyOpQueueState build() => const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
        hasDurabilityFailure: true,
        lastError: 'Cloud work could not be verified in the durable outbox. '
            'Nothing was sent.',
      );
}

class _EmptyMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );
}

class _AttentionOpQueue extends StrategyOpQueueNotifier {
  _AttentionOpQueue(this.rejectedCount);

  final int rejectedCount;
  int retryRejectedCount = 0;
  int flushNowCount = 0;

  @override
  StrategyOpQueueState build() => StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
        attentionByEntityKey: {
          for (var index = 0; index < rejectedCount; index++)
            EntitySyncKey.element('page-1', 'element-$index'):
                QueuedEntityIntent(
              entityKey:
                  EntitySyncKey.element('page-1', 'element-$index'),
              pending: PendingOp(
                op: ElementPatchOp(
                  opId: 'rejected-$index',
                  elementPublicId: 'element-$index',
                  pagePublicId: 'page-1',
                  payload: const {'value': 'mine'},
                  expectedElementRevision: 1,
                ),
                clientId: 'client-a',
              ),
            ),
        },
        lastError: 'Some saved work needs attention.',
      );

  @override
  Future<void> retryPaused({bool flushImmediately = true}) async {}

  @override
  Future<void> retryRejected({bool flushImmediately = true}) async {
    retryRejectedCount += 1;
  }

  @override
  Future<void> flushNow() async {
    flushNowCount += 1;
  }
}

class _ConflictSession extends StrategyPageSessionNotifier {
  _ConflictSession({this.result = true, this.failure});

  final bool result;
  final Object? failure;
  int useCloudCount = 0;

  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-1',
        availablePageIds: ['page-1'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );

  @override
  Future<bool> useCloudVersionsForRejected() async {
    useCloudCount += 1;
    if (failure != null) throw failure!;
    return result;
  }
}

ProviderContainer _createContainer({bool connected = true}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      strategyOpQueueProvider.overrideWith(_SettledOpQueue.new),
      cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
      convexConnectionProvider.overrideWith((ref) => Stream.value(connected)),
    ],
  );
}

ProviderContainer _createConflictContainer({
  required _AttentionOpQueue queue,
  required _ConflictSession session,
}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      strategyOpQueueProvider.overrideWith(() => queue),
      strategyPageSessionProvider.overrideWith(() => session),
      cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
      convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
    ],
  );
}

void main() {
  testWidgets('an active text draft can never appear synced', (tester) async {
    final container = _createContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Synced'), findsOneWidget);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'visible local edit');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Editing…'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);

    await tester.tap(find.text('Editing…'));
    await tester.pumpAndSettle();
    expect(find.text('Edit not synced yet'), findsOneWidget);
    expect(
      find.text(
        'Finish editing or switch pages to send this change to the cloud.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('offline remains visible while a text draft is active',
      (tester) async {
    final container = _createContainer(connected: false);
    addTearDown(container.dispose);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'offline edit');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Editing…'), findsNothing);
    expect(find.text('Synced'), findsNothing);
  });

  testWidgets('durability uncertainty never appears synced or reliable',
      (tester) async {
    final container = ProviderContainer(
      overrides: [
        strategyProvider.overrideWith(_CloudStrategyProvider.new),
        strategyOpQueueProvider.overrideWith(_UnreliableOpQueue.new),
        cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
        convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();

    final queue = container.read(strategyOpQueueProvider);
    expect(queue.outboxIsReliable, isFalse);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);

    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();
    expect(find.text('Retry sync'), findsOneWidget);
    expect(find.textContaining('safely stored'), findsNothing);
  });

  testWidgets('conflict popover offers an explicit cloud choice',
      (tester) async {
    final queue = _AttentionOpQueue(2);
    final session = _ConflictSession();
    final container = _createConflictContainer(
      queue: queue,
      session: session,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();

    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(
      find.textContaining('applies to all 2 conflicting changes'),
      findsOneWidget,
    );

    await tester.tap(find.text('Use cloud'));
    await tester.pumpAndSettle();

    expect(session.useCloudCount, 1);
    expect(queue.retryRejectedCount, 0);
    expect(queue.flushNowCount, 0);
  });

  testWidgets('keep mine remains an explicit rejected retry', (tester) async {
    final queue = _AttentionOpQueue(1);
    final session = _ConflictSession();
    final container = _createConflictContainer(
      queue: queue,
      session: session,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();

    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);

    await tester.tap(find.text('Keep mine'));
    await tester.pumpAndSettle();

    expect(queue.retryRejectedCount, 1);
    expect(queue.flushNowCount, 1);
    expect(session.useCloudCount, 0);
  });

  testWidgets('oversized saved work shows its durable attention reason',
      (tester) async {
    final queue = _AttentionOpQueue(1);
    final session = _ConflictSession();
    final container = _createConflictContainer(
      queue: queue,
      session: session,
    );
    addTearDown(container.dispose);
    container
        .read(strategySaveStateProvider.notifier)
        .setCloudSyncError(cloudOperationTooLargeMessage);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('too large for cloud sync'),
      findsOneWidget,
    );
    expect(find.textContaining('Another edit reached'), findsNothing);
    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
  });

  testWidgets('failed cloud load keeps attention and explains the failure',
      (tester) async {
    final queue = _AttentionOpQueue(1);
    final session = _ConflictSession(result: false);
    final container = _createConflictContainer(
      queue: queue,
      session: session,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use cloud'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not load the cloud version. Your saved version was not changed.',
      ),
      findsOneWidget,
    );
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      hasLength(1),
    );
  });

  testWidgets('thrown cloud load keeps attention and explains the failure',
      (tester) async {
    final queue = _AttentionOpQueue(1);
    final session = _ConflictSession(failure: StateError('refresh failed'));
    final container = _createConflictContainer(
      queue: queue,
      session: session,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: CloudSyncStatusChip()),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use cloud'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not load the cloud version. Your saved version was not changed.',
      ),
      findsOneWidget,
    );
    expect(
      container.read(strategyOpQueueProvider).attentionByEntityKey,
      hasLength(1),
    );
  });
}
