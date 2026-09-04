import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
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

class _EmptyMediaQueue extends CloudMediaUploadQueueNotifier {
  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );
}

class _FixedMediaQueue extends CloudMediaUploadQueueNotifier {
  _FixedMediaQueue(this.initialState);

  final CloudMediaUploadQueueState initialState;

  @override
  CloudMediaUploadQueueState build() => initialState;
}

class _FixedOpQueue extends StrategyOpQueueNotifier {
  _FixedOpQueue(this.initialState);

  final StrategyOpQueueState initialState;

  @override
  StrategyOpQueueState build() => initialState;
}

class _FixedSaveState extends StrategySaveStateNotifier {
  _FixedSaveState(this.initialState);

  final StrategySaveState initialState;

  @override
  StrategySaveState build() => initialState;
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

ProviderContainer _createContainer({
  bool connected = true,
  StrategyOpQueueState? opQueueState,
  CloudMediaUploadQueueState? mediaQueueState,
  StrategySaveState? saveState,
}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      strategyOpQueueProvider.overrideWith(
        opQueueState == null
            ? _SettledOpQueue.new
            : () => _FixedOpQueue(opQueueState),
      ),
      cloudMediaUploadQueueProvider.overrideWith(
        mediaQueueState == null
            ? _EmptyMediaQueue.new
            : () => _FixedMediaQueue(mediaQueueState),
      ),
      convexConnectionProvider.overrideWith((ref) => Stream.value(connected)),
      if (saveState != null)
        strategySaveStateProvider.overrideWith(
          () => _FixedSaveState(saveState),
        ),
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
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
      convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
    ],
  );
}

void main() {
  test('restored active-strategy media renders as syncing', () {
    final container = _createContainer(
      mediaQueueState: CloudMediaUploadQueueState(
        jobs: [
          CloudMediaUploadJob(
            jobId: 'restored-image',
            accountId: 'account-a',
            strategyPublicId: 'cloud-strategy',
            assetPublicId: 'restored-image',
            fileExtension: 'png',
            mimeType: 'image/png',
            state: CloudMediaJobState.pendingUpload,
            referenceDurable: false,
            attempts: 0,
            updatedAt: DateTime.utc(2026),
          ),
        ],
        isProcessing: false,
      ),
    );
    addTearDown(container.dispose);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.syncing);
    expect(
      container.read(cloudSyncStatusProvider),
      isNot(CloudSyncStatus.synced),
    );
  });

  test('restored active-strategy media errors remain visible offline',
      () async {
    final container = _createContainer(
      connected: false,
      mediaQueueState: CloudMediaUploadQueueState(
        jobs: [
          CloudMediaUploadJob(
            jobId: 'missing-image',
            accountId: 'account-a',
            strategyPublicId: 'cloud-strategy',
            assetPublicId: 'missing-image',
            fileExtension: 'png',
            mimeType: 'image/png',
            state: CloudMediaJobState.failed,
            attempts: 1,
            lastError: 'Local media file is missing.',
            updatedAt: DateTime.utc(2026),
          ),
        ],
        isProcessing: false,
      ),
    );
    addTearDown(container.dispose);
    await container.read(convexConnectionProvider.future);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.attention);
  });

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

  test('status provider prioritizes connectivity over an offline flush error',
      () async {
    final container = _createContainer(
      connected: false,
      saveState: const StrategySaveState(
        isDirty: true,
        isSaving: false,
        hasPendingCloudSync: true,
        cloudSyncError: 'Cloud connection is offline.',
        hasPendingMediaSync: false,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      ),
    );
    addTearDown(container.dispose);
    await container.read(convexConnectionProvider.future);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.offline);
  });

  test('real queue attention remains visible while offline', () async {
    const entityKey = EntitySyncKey.strategy();
    const intent = QueuedEntityIntent(
      entityKey: entityKey,
      pending: PendingOp(
        op: StrategyPatchOp(
          opId: 'conflicted-op',
          payload: <String, dynamic>{'name': 'conflicted'},
          expectedStrategyRevision: 1,
        ),
        clientId: 'client-a',
      ),
    );
    final container = _createContainer(
      connected: false,
      opQueueState: StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        attentionByEntityKey: <EntitySyncKey, QueuedEntityIntent>{
          entityKey: intent,
        },
        durableLoaded: true,
      ),
    );
    addTearDown(container.dispose);
    await container.read(convexConnectionProvider.future);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.attention);
  });

  test('media errors remain visible while offline', () async {
    final container = _createContainer(
      connected: false,
      saveState: const StrategySaveState(
        isDirty: false,
        isSaving: false,
        hasPendingCloudSync: true,
        cloudSyncError: null,
        hasPendingMediaSync: true,
        mediaSyncErrorCount: 1,
        lastPersistedAt: null,
      ),
    );
    addTearDown(container.dispose);
    await container.read(convexConnectionProvider.future);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.attention);
  });

  testWidgets('offline flush errors render Offline instead of Needs attention',
      (tester) async {
    final container = _createContainer(
      connected: false,
      saveState: const StrategySaveState(
        isDirty: true,
        isSaving: false,
        hasPendingCloudSync: true,
        cloudSyncError: 'Cloud connection is offline.',
        hasPendingMediaSync: false,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      ),
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
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
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
