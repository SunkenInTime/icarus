import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/const/update_checker.dart';
import 'package:icarus/providers/collab/active_page_live_sync_provider.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/lineup_conflicts_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/desktop_update_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/update_status_provider.dart';
import 'package:icarus/strategy/lineup_group_changes.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/client_upgrade_button.dart';
import 'package:icarus/widgets/cloud_sync_button.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';

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

/// Counts saves instead of writing; the outbox's state is the test's.
class _SavingStrategyProvider extends _CloudStrategyProvider {
  int saves = 0;

  @override
  Future<void> forceSaveNow(String id) async {
    saves += 1;
  }
}

/// Answers whether the server accepts this build's protocol.
class _ProtocolRepository extends Fake implements ConvexStrategyRepository {
  _ProtocolRepository({required this.accepts});

  final bool accepts;
  int asked = 0;

  @override
  Future<bool> serverAcceptsCloudProtocol() async {
    asked += 1;
    return accepts;
  }
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
  _AttentionOpQueue(
    this.rejectedCount, {
    this.hasOtherStrategyAttention = false,
  });

  final int rejectedCount;
  final bool hasOtherStrategyAttention;
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
              entityKey: EntitySyncKey.element('page-1', 'element-$index'),
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
        accountOutbox: hasOtherStrategyAttention
            ? const AccountStrategyOutboxSummary(
                accountId: 'account-a',
                strategies: {
                  'closed-strategy': StrategyOutboxSummary(
                    strategyPublicId: 'closed-strategy',
                    queuedCount: 0,
                    inFlightCount: 0,
                    pausedCount: 1,
                    attentionCount: 0,
                    successorCount: 0,
                  ),
                },
              )
            : const AccountStrategyOutboxSummary(),
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
  _ConflictSession({this.result = true, this.failure, this.keepBoth});

  final bool result;
  final Object? failure;

  /// What Keep both answers; by default what [result] says.
  final KeepBothOutcome? keepBoth;
  int useCloudCount = 0;
  int keepBothCount = 0;

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

  @override
  Future<KeepBothOutcome> keepBothForRejected() async {
    keepBothCount += 1;
    if (failure != null) throw failure!;
    return keepBoth ??
        (result ? KeepBothOutcome.kept : KeepBothOutcome.unchanged);
  }
}

class _DeletedPageSession extends StrategyPageSessionNotifier {
  _DeletedPageSession({
    required this.leaves,
    this.restore = DeletedPageRestore.restored,
  });

  final bool leaves;
  final DeletedPageRestore restore;
  int leaveCount = 0;
  int restoreCount = 0;

  @override
  StrategyPageSessionState build() => const StrategyPageSessionState(
        activePageId: 'page-1',
        availablePageIds: ['page-2'],
        transitionState: PageTransitionState.idle,
        isApplyingPage: false,
      );

  void teammateDeletes() => setStateForTest(
        state.copyWith(deletedPage: (pageId: 'page-1', name: 'A exec')),
      );

  @override
  Future<bool> leaveDeletedPage() async {
    leaveCount += 1;
    if (leaves) setStateForTest(state.copyWith(clearDeletedPage: true));
    return leaves;
  }

  @override
  Future<DeletedPageRestore> restoreDeletedPage() async {
    restoreCount += 1;
    if (restore == DeletedPageRestore.restored) {
      setStateForTest(state.copyWith(clearDeletedPage: true));
    }
    return restore;
  }
}

class _FixedLiveSync extends ActivePageLiveSyncNotifier {
  _FixedLiveSync(this.fixed);

  final ActivePageLiveSyncState fixed;

  @override
  ActivePageLiveSyncState build() => fixed;
}

ProviderContainer _createContainer({
  bool connected = true,
  StrategyOpQueueState? opQueueState,
  CloudMediaUploadQueueState? mediaQueueState,
  StrategySaveState? saveState,
  ActivePageLiveSyncState? liveSyncState,
}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      if (liveSyncState != null)
        activePageLiveSyncProvider.overrideWith(
          () => _FixedLiveSync(liveSyncState),
        ),
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
  List<LineupGroupConflict>? lineupConflicts,
}) {
  return ProviderContainer(
    overrides: [
      strategyProvider.overrideWith(_CloudStrategyProvider.new),
      strategyOpQueueProvider.overrideWith(() => queue),
      strategyPageSessionProvider.overrideWith(() => session),
      lineupConflictsProvider.overrideWithValue(lineupConflicts),
      cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
      cloudMediaAccountIdProvider.overrideWithValue('account-a'),
      convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
    ],
  );
}

Finder _syncButton(String status) =>
    find.byKey(ValueKey('cloud-sync-button-$status'));

/// The one-line meaning the button shows on hover.
String _syncTooltip(WidgetTester tester) {
  final button = tester.widget<EditorToolbarButton>(
    find.byType(EditorToolbarButton),
  );
  return button.tooltip;
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();

    expect(_syncButton('synced'), findsOneWidget);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'visible local edit');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_syncButton('editing'), findsOneWidget);
    expect(_syncButton('synced'), findsNothing);

    expect(_syncTooltip(tester), 'Edit not synced yet');
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_syncButton('offline'), findsOneWidget);
    expect(_syncButton('editing'), findsNothing);
    expect(_syncButton('synced'), findsNothing);
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

  test('queued work in another strategy prevents a synced status', () {
    final container = _createContainer(
      opQueueState: const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'closed-strategy': StrategyOutboxSummary(
              strategyPublicId: 'closed-strategy',
              queuedCount: 1,
              inFlightCount: 0,
              pausedCount: 0,
              attentionCount: 0,
              successorCount: 0,
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);

    expect(container.read(cloudSyncStatusProvider), CloudSyncStatus.syncing);
  });

  testWidgets('inactive attention directs the user to the cloud library',
      (tester) async {
    final container = _createContainer(
      opQueueState: const StrategyOpQueueState(
        accountId: 'account-a',
        strategyPublicId: 'cloud-strategy',
        clientId: 'client-a',
        durableLoaded: true,
        accountOutbox: AccountStrategyOutboxSummary(
          accountId: 'account-a',
          strategies: {
            'closed-strategy': StrategyOutboxSummary(
              strategyPublicId: 'closed-strategy',
              queuedCount: 0,
              inFlightCount: 0,
              pausedCount: 1,
              attentionCount: 0,
              successorCount: 0,
              reason: 'Retry limit reached',
            ),
          },
        ),
      ),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();

    expect(_syncButton('attention'), findsOneWidget);
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Saved work in another strategy needs attention. Open it from the '
        'Cloud library to review the reason.',
      ),
      findsOneWidget,
    );
    expect(find.text('Retry sync'), findsNothing);
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(_syncButton('offline'), findsOneWidget);
    expect(_syncButton('attention'), findsNothing);
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();

    final queue = container.read(strategyOpQueueProvider);
    expect(queue.outboxIsReliable, isFalse);
    expect(_syncButton('attention'), findsOneWidget);
    expect(_syncButton('synced'), findsNothing);

    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();
    expect(find.text('Retry sync'), findsOneWidget);
    expect(find.textContaining('safely stored'), findsNothing);
  });

  group('when the server needs a newer Icarus', () {
    ProviderContainer upgradeContainer({
      bool updateWaiting = false,
      StrategyOpQueueState? queue,
      _SavingStrategyProvider? strategy,
      _ProtocolRepository? repository,
      void Function()? onUpdateCheck,
    }) {
      final container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(
            strategy == null ? _CloudStrategyProvider.new : () => strategy,
          ),
          strategyOpQueueProvider.overrideWith(
            queue == null ? _SettledOpQueue.new : () => _FixedOpQueue(queue),
          ),
          cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
          authProvider.overrideWith(_ReadyAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(true),
          convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
          appUpdateStatusProvider.overrideWith((ref) async {
            onUpdateCheck?.call();
            return UpdateCheckResult(
              isSupported: true,
              isUpdateAvailable: updateWaiting,
              source: 'test',
            );
          }),
          desktopUpdateControllerProvider.overrideWithValue(null),
          if (repository != null)
            convexStrategyRepositoryProvider.overrideWithValue(repository),
        ],
      );
      container.read(clientUpgradeRequiredProvider.notifier).noteError(
            clientUpgradeRequiredQueueError,
          );
      return container;
    }

    Future<void> pump(
      WidgetTester tester,
      ProviderContainer container,
      Widget child,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ToastificationWrapper(
            child: ShadApp(home: Scaffold(body: child)),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> openPopover(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await pump(
        tester,
        container,
        const CloudSyncButton(style: kEditorToolbarButtonStyle),
      );
      await tester.tap(_syncButton('attention'));
      await tester.pumpAndSettle();
    }

    test('nothing appears synced, even with nothing queued', () async {
      final container = upgradeContainer();
      addTearDown(container.dispose);
      await container.read(convexConnectionProvider.future);

      expect(
        container.read(cloudSyncStatusProvider),
        CloudSyncStatus.attention,
      );
    });

    testWidgets('says so and offers the update in place of a retry',
        (tester) async {
      final container = upgradeContainer(updateWaiting: true);
      addTearDown(container.dispose);

      await openPopover(tester, container);

      expect(
        find.text('Icarus was updated. Install the update to keep syncing.'),
        findsOneWidget,
      );
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Retry sync'), findsNothing);
      expect(find.text('Keep mine'), findsNothing);
    });

    test('looks for the update again once refused', () async {
      var checks = 0;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final previous = UpdateChecker.windowsStoreCheckOverride;
      UpdateChecker.windowsStoreCheckOverride = () async {
        checks += 1;
        return <String, dynamic>{
          'isSupported': true,
          'isUpdateAvailable': false,
        };
      };
      addTearDown(() => UpdateChecker.windowsStoreCheckOverride = previous);

      await container.read(appUpdateStatusProvider.future);
      expect(checks, 1);
      container
          .read(clientUpgradeRequiredProvider.notifier)
          .noteError(clientUpgradeRequiredQueueError);
      await container.read(appUpdateStatusProvider.future);

      expect(checks, 2);
    });

    testWidgets(
        'says honestly when no update is there yet, and can check again',
        (tester) async {
      var checks = 0;
      final repository = _ProtocolRepository(accepts: true);
      final container = upgradeContainer(
        repository: repository,
        onUpdateCheck: () => checks += 1,
      );
      addTearDown(container.dispose);

      await openPopover(tester, container);

      expect(
        find.textContaining("the update isn't available for this app yet"),
        findsOneWidget,
      );
      expect(find.textContaining('Your saved work stays on this device'),
          findsOneWidget);
      expect(find.textContaining('Install the update'), findsNothing);
      expect(find.text('Retry sync'), findsNothing);
      final checksBefore = checks;

      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();

      // The update is looked for again, and the server asked whether it
      // accepts this build again (a rolled-back deploy), which it does.
      expect(checks, greaterThan(checksBefore));
      expect(repository.asked, 1);
      expect(container.read(clientUpgradeRequiredProvider), isFalse);
    });

    testWidgets('unsaved work outranks the refusal and is never reloaded away',
        (tester) async {
      final container = upgradeContainer(
        updateWaiting: true,
        queue: const StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'client-a',
          durableLoaded: true,
          hasDurabilityFailure: true,
          lastError: 'Cloud work could not be verified in the durable '
              'outbox. Nothing was sent.',
        ),
      );
      addTearDown(container.dispose);

      await openPopover(tester, container);

      expect(find.text('Retry sync'), findsOneWidget);
      expect(find.textContaining('Icarus was updated'), findsNothing);
      expect(find.byKey(const ValueKey('client-upgrade-button')), findsNothing);
    });

    testWidgets('the web reloads when no work is waiting to be kept',
        (tester) async {
      final strategy = _SavingStrategyProvider();
      final container = upgradeContainer(strategy: strategy);
      addTearDown(container.dispose);
      var reloads = 0;

      await pump(
        tester,
        container,
        ClientUpgradeNotice(
          isWeb: true,
          onReload: () => reloads += 1,
          builder: (context, message, action) =>
              Column(children: [Text(message), action!]),
        ),
      );
      expect(find.text('Icarus was updated. Reload to keep syncing.'),
          findsOneWidget);
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();

      expect(reloads, 1);
    });

    testWidgets('reload asks first while the outbox is uncertain',
        (tester) async {
      final strategy = _SavingStrategyProvider();
      final container = upgradeContainer(
        strategy: strategy,
        queue: const StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'client-a',
          durableLoaded: true,
          hasDurabilityFailure: true,
        ),
      );
      addTearDown(container.dispose);
      var reloads = 0;

      await pump(
        tester,
        container,
        ClientUpgradeNotice(
          isWeb: true,
          onReload: () => reloads += 1,
          builder: (context, message, action) =>
              Column(children: [Text(message), action!]),
        ),
      );
      await tester.tap(find.text('Reload'));
      await tester.pumpAndSettle();

      // The same guard as leaving the strategy: it can't confirm the work
      // is kept on this device, so it offers to stay, never to leave.
      expect(reloads, 0);
      expect(find.text('Cloud sync pending'), findsOneWidget);
      expect(find.text('Leave anyway'), findsNothing);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
    });
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(
      find.textContaining('applies to all 2 conflicting changes'),
      findsOneWidget,
    );
    // An element conflict has no lineup changes to list and nothing to keep
    // beside the cloud's version.
    expect(find.text('Keep both'), findsNothing);
    expect(find.text('Your changes'), findsNothing);

    await tester.tap(find.text('Use cloud'));
    await tester.pumpAndSettle();

    expect(session.useCloudCount, 1);
    expect(queue.retryRejectedCount, 0);
    expect(queue.flushNowCount, 0);
  });

  group('lineup conflicts', () {
    LineupChange change(String label, String description) =>
        LineupChange(label: label, description: description);

    final conflicts = [
      LineupGroupConflict(
        key: const EntitySyncKey.lineup('page-1', 'link-a'),
        yours: [change('Heaven', 'notes edited')],
        cloud: [
          change('Mid', 'renamed'),
          change('Short', 'added'),
          change('Long', 'landing moved'),
          change('Deep', 'deleted'),
          change('Sova lineup', 'images changed'),
        ],
      ),
    ];

    Future<void> openPopover(
        WidgetTester tester, ProviderContainer container) async {
      // The test font sets every glyph a full em wide, so the lists wrap far
      // more than in the app; a desktop-sized window gives them the room.
      tester.view.physicalSize = const Size(1280, 1024);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
                body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(_syncButton('attention'));
      await tester.pumpAndSettle();
    }

    Finder line(String text) => find.text(text, findRichText: true);

    testWidgets(
        'without the version both sides started from, list one section of '
        'how yours differs from the cloud', (tester) async {
      final queue = _AttentionOpQueue(1);
      final session = _ConflictSession();
      final container = _createConflictContainer(
        queue: queue,
        session: session,
        lineupConflicts: [
          LineupGroupConflict(
            key: const EntitySyncKey.lineup('page-1', 'link-a'),
            yours: [
              change('Heaven', 'notes edited'),
              change('Mid', 'notes edited'),
            ],
            cloud: null,
          ),
          // One conflict without that version is enough to show none of
          // the sides' changes apart.
          LineupGroupConflict(
            key: const EntitySyncKey.lineup('page-1', 'link-z'),
            yours: [change('Long', 'landing moved')],
            cloud: [change('Short', 'added')],
          ),
        ],
      );
      addTearDown(container.dispose);
      await openPopover(tester, container);

      expect(
          find.text('How your version differs from the cloud'), findsOneWidget);
      expect(line('Heaven · notes edited'), findsOneWidget);
      expect(line('Mid · notes edited'), findsOneWidget);
      expect(line('Long · landing moved'), findsOneWidget);
      expect(find.text('Your changes'), findsNothing);
      expect(find.text('Cloud changes'), findsNothing);
      expect(line('Short · added'), findsNothing);
      expect(find.text('Keep both'), findsOneWidget);
    });

    testWidgets('list what each side changed and offer Keep both',
        (tester) async {
      final queue = _AttentionOpQueue(1);
      final session = _ConflictSession();
      final container = _createConflictContainer(
        queue: queue,
        session: session,
        lineupConflicts: conflicts,
      );
      addTearDown(container.dispose);
      await openPopover(tester, container);

      expect(
        find.textContaining('A teammate changed these lineups'),
        findsOneWidget,
      );
      expect(find.text('Your changes'), findsOneWidget);
      expect(line('Heaven · notes edited'), findsOneWidget);
      expect(find.text('Cloud changes'), findsOneWidget);
      expect(line('Mid · renamed'), findsOneWidget);
      expect(line('Short · added'), findsOneWidget);
      expect(line('Long · landing moved'), findsOneWidget);
      expect(line('Deep · deleted'), findsOneWidget);
      // Past four lines the rest are counted.
      expect(line('Sova lineup · images changed'), findsNothing);
      expect(find.text('and 1 more lineup'), findsOneWidget);
      expect(find.text('Use cloud'), findsOneWidget);
      expect(find.text('Keep mine'), findsOneWidget);
      expect(find.text('Keep both'), findsOneWidget);

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(session.keepBothCount, 1);
      expect(session.useCloudCount, 0);
      expect(queue.retryRejectedCount, 0);
      expect(queue.flushNowCount, 0);
    });

    testWidgets('a Keep both that cannot load the cloud version says so',
        (tester) async {
      final queue = _AttentionOpQueue(1);
      final session = _ConflictSession(result: false);
      final container = _createConflictContainer(
        queue: queue,
        session: session,
        lineupConflicts: conflicts,
      );
      addTearDown(container.dispose);
      await openPopover(tester, container);

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(session.keepBothCount, 1);
      expect(
        find.text('Could not load the cloud version. Nothing was changed.'),
        findsOneWidget,
      );
      expect(find.text('Keep both'), findsOneWidget);
    });

    testWidgets(
        'a Keep both that copied but could not resolve says the conflict '
        'is still open', (tester) async {
      final queue = _AttentionOpQueue(1);
      final session = _ConflictSession(keepBoth: KeepBothOutcome.copiesOnly);
      final container = _createConflictContainer(
        queue: queue,
        session: session,
        lineupConflicts: conflicts,
      );
      addTearDown(container.dispose);
      await openPopover(tester, container);

      await tester.tap(find.text('Keep both'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Your version was added as a copy'),
        findsOneWidget,
      );
      expect(find.textContaining('the conflict is still open'), findsOneWidget);
    });
  });

  testWidgets(
      'active conflict controls remain when another strategy needs attention',
      (tester) async {
    final queue = _AttentionOpQueue(
      1,
      hasOtherStrategyAttention: true,
    );
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(find.textContaining('Choose which version to keep'), findsOneWidget);
    expect(
      find.textContaining('another strategy also needs attention'),
      findsOneWidget,
    );
    expect(find.textContaining('Cloud library'), findsOneWidget);
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('too large for cloud sync'),
      findsOneWidget,
    );
    expect(find.textContaining('Another edit reached'), findsNothing);
    expect(find.text('Use cloud'), findsOneWidget);
    expect(find.text('Keep mine'), findsOneWidget);
  });

  for (final (name, reason, expected) in [
    (
      'another page',
      lineupPageMismatchMessage,
      'clashes with one on another page',
    ),
    (
      'its old cloud format',
      retiredLineupOpMessage,
      'saved by an older version of Icarus',
    ),
  ]) {
    testWidgets('a lineup refused for $name says why, not "another edit"',
        (tester) async {
      final queue = _AttentionOpQueue(1);
      final container = _createConflictContainer(
        queue: queue,
        session: _ConflictSession(),
      );
      addTearDown(container.dispose);
      container
          .read(strategySaveStateProvider.notifier)
          .setCloudSyncError(reason);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
              body: CloudSyncButton(style: kEditorToolbarButtonStyle),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(_syncButton('attention'));
      await tester.pumpAndSettle();

      expect(find.textContaining(expected), findsOneWidget);
      expect(find.textContaining('Another edit reached'), findsNothing);
      expect(find.textContaining('Choose which version'), findsNothing);
      expect(find.text('Use cloud'), findsOneWidget);
      expect(find.text('Keep mine'), findsOneWidget);
    });
  }

  testWidgets(
      'a lineup group the server refused as overlapping another says why, '
      'not that a teammate changed it', (tester) async {
    tester.view.physicalSize = const Size(1280, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = _AttentionOpQueue(1);
    final container = _createConflictContainer(
      queue: queue,
      session: _ConflictSession(),
      // Even with lineup changes to list, the specific reason comes first.
      lineupConflicts: const [
        LineupGroupConflict(
          key: EntitySyncKey.lineup('page-1', 'link-a'),
          yours: [LineupChange(label: 'Heaven', description: 'added')],
          cloud: [],
        ),
      ],
    );
    addTearDown(container.dispose);
    container
        .read(strategySaveStateProvider.notifier)
        .setCloudSyncError(lineupOverlapMessage);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('shares a spot with lineups saved separately'),
      findsOneWidget,
    );
    expect(
        find.textContaining('Keep mine replaces their changes'), findsNothing);
    expect(
        find.textContaining('A teammate changed these lineups'), findsNothing);
    expect(find.textContaining('Another edit reached'), findsNothing);
    expect(find.text('Your changes'), findsNothing);
    expect(find.text('Keep both'), findsNothing);
    expect(find.text('Use cloud'), findsOneWidget);
  });

  for (final (name, error, keepMine) in [
    ('alone', lineupOverlapMessage, true),
    (
      'beside other work',
      '$lineupOverlapMessage. $otherWorkNeedsAttentionNote',
      true,
    ),
  ]) {
    testWidgets(
        'an overlap refusal $name still offers Keep mine, saying when it '
        'helps', (tester) async {
      final queue = _AttentionOpQueue(keepMine ? 2 : 1);
      final container = _createConflictContainer(
        queue: queue,
        session: _ConflictSession(),
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).setCloudSyncError(
            error,
          );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
              body: CloudSyncButton(style: kEditorToolbarButtonStyle),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(_syncButton('attention'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('shares a spot with lineups saved separately'),
        findsOneWidget,
      );
      expect(
        find.textContaining('refused while the spot is still shared'),
        findsOneWidget,
      );
      expect(find.text('Use cloud'), findsOneWidget);
      expect(find.text('Keep mine'), keepMine ? findsOneWidget : findsNothing);
      expect(find.text('Retry sync'), findsNothing);
      expect(find.text('Keep both'), findsNothing);
    });
  }

  testWidgets(
      'a lineup refusal among several changes says the choice covers all '
      'of them', (tester) async {
    final queue = _AttentionOpQueue(2);
    final container = _createConflictContainer(
      queue: queue,
      session: _ConflictSession(),
    );
    addTearDown(container.dispose);
    container
        .read(strategySaveStateProvider.notifier)
        .setCloudSyncError(lineupPageMismatchMessage);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(find.textContaining('another page'), findsOneWidget);
    expect(
      find.textContaining('applies to all 2 changes that need attention'),
      findsOneWidget,
    );
  });

  testWidgets('a lineup refusal beside other refused work mentions both',
      (tester) async {
    final queue = _AttentionOpQueue(2);
    final container = _createConflictContainer(
      queue: queue,
      session: _ConflictSession(),
    );
    addTearDown(container.dispose);
    container.read(strategySaveStateProvider.notifier).setCloudSyncError(
          '$lineupPageMismatchMessage. $otherWorkNeedsAttentionNote',
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
    await tester.pumpAndSettle();

    expect(find.textContaining('another page'), findsOneWidget);
    expect(
      find.textContaining('Other changes here were not saved either'),
      findsOneWidget,
    );
    expect(find.textContaining('Another edit reached'), findsNothing);
    expect(
      find.textContaining('applies to all 2 changes that need attention'),
      findsOneWidget,
    );
  });

  group('refusal toast', () {
    Finder toast(String text) => find.byWidgetPredicate(
          (widget) => widget is Text && widget.data == text,
          skipOffstage: false,
        );

    Future<ProviderContainer> pumpButton(WidgetTester tester) async {
      final container = _createConflictContainer(
        queue: _AttentionOpQueue(1),
        session: _ConflictSession(),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ToastificationWrapper(
            child: ShadApp(
              home: Scaffold(
                body: CloudSyncButton(style: kEditorToolbarButtonStyle),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    Future<void> drainToasts(WidgetTester tester) async {
      toastification.dismissAll(delayForAnimation: false);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    }

    testWidgets('a lineup refusal toasts its own reason', (tester) async {
      final container = await pumpButton(tester);

      container.read(strategyConflictProvider.notifier).push(
            const ConflictResolution(
              type: ConflictResolutionType.rebase,
              opId: 'refused-link',
              message: lineupPageMismatchMessage,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        toast(friendlyCloudSyncError(lineupPageMismatchMessage)),
        findsOneWidget,
      );
      expect(
        find.textContaining('Another edit reached', skipOffstage: false),
        findsNothing,
      );
      await drainToasts(tester);
    });

    testWidgets('an edit that lost a race still toasts as a conflict',
        (tester) async {
      final container = await pumpButton(tester);

      container.read(strategyConflictProvider.notifier).push(
            const ConflictResolution(
              type: ConflictResolutionType.rebase,
              opId: 'stale-edit',
              message: 'revision_mismatch',
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('Another edit reached', skipOffstage: false),
        findsOneWidget,
      );
      await drainToasts(tester);
    });
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
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
          home:
              Scaffold(body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(_syncButton('attention'));
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

  test('an image still uploading keeps the unsaved mark', () {
    final container = _createContainer(
      saveState: const StrategySaveState(
        isDirty: true,
        isSaving: false,
        hasPendingCloudSync: false,
        cloudSyncError: null,
        hasPendingMediaSync: true,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      ),
    );
    addTearDown(container.dispose);

    container.read(strategySaveStateProvider.notifier).clearStaleCloudMark();

    expect(container.read(strategySaveStateProvider).isDirty, isTrue);
  });

  group('unsaved work on a page a teammate deleted', () {
    Future<_DeletedPageSession> pumpButton(
      WidgetTester tester, {
      required bool leaves,
      bool deletedBeforeMount = false,
      DeletedPageRestore restore = DeletedPageRestore.restored,
    }) async {
      final session = _DeletedPageSession(leaves: leaves, restore: restore);
      final container = ProviderContainer(overrides: [
        strategyProvider.overrideWith(_CloudStrategyProvider.new),
        strategyOpQueueProvider.overrideWith(_SettledOpQueue.new),
        strategyPageSessionProvider.overrideWith(() => session),
        cloudMediaUploadQueueProvider.overrideWith(_EmptyMediaQueue.new),
        convexConnectionProvider.overrideWith((ref) => Stream.value(true)),
      ]);
      addTearDown(container.dispose);
      if (deletedBeforeMount) {
        container.read(strategyPageSessionProvider);
        session.teammateDeletes();
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
                body: CloudSyncButton(style: kEditorToolbarButtonStyle)),
          ),
        ),
      );
      await tester.pump();
      if (!deletedBeforeMount) session.teammateDeletes();
      await tester.pumpAndSettle();
      return session;
    }

    testWidgets('says so until the user has read it', (tester) async {
      final session = await pumpButton(tester, leaves: true);

      expect(find.text('This page was deleted'), findsOneWidget);
      expect(
        find.textContaining('“A exec” was deleted while you were editing it'),
        findsOneWidget,
      );
      // Only reading it closes it.
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('This page was deleted'), findsOneWidget);

      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(session.leaveCount, 1);
      expect(session.restoreCount, 0);
      expect(find.text('This page was deleted'), findsNothing);
    });

    testWidgets('restoring the page keeps the work and closes the notice',
        (tester) async {
      final session = await pumpButton(tester, leaves: true);
      expect(find.text('Restore page'), findsOneWidget);

      await tester.tap(find.text('Restore page'));
      await tester.pumpAndSettle();

      expect(session.restoreCount, 1);
      expect(session.leaveCount, 0);
      expect(find.text('This page was deleted'), findsNothing);
    });

    testWidgets(
        'a page that can no longer be restored says so and leaves discard',
        (tester) async {
      final session = await pumpButton(
        tester,
        leaves: true,
        restore: DeletedPageRestore.gone,
      );

      await tester.tap(find.text('Restore page'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
            '“A exec” can no longer be restored, so your latest changes'),
        findsOneWidget,
      );
      expect(find.text('Restore page'), findsNothing);
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(session.leaveCount, 1);
      expect(find.text('This page was deleted'), findsNothing);
    });

    testWidgets('a restore that fails says so and keeps both choices',
        (tester) async {
      final session = await pumpButton(
        tester,
        leaves: true,
        restore: DeletedPageRestore.failed,
      );

      await tester.tap(find.text('Restore page'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not confirm the page was restored'),
        findsOneWidget,
      );
      expect(find.text('This page was deleted'), findsOneWidget);
      expect(find.text('Restore page'), findsOneWidget);
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(session.leaveCount, 1);
      expect(find.text('This page was deleted'), findsNothing);
    });

    testWidgets('shows when the button mounts after the page was deleted',
        (tester) async {
      await pumpButton(tester, leaves: true, deletedBeforeMount: true);

      expect(find.text('This page was deleted'), findsOneWidget);
    });

    testWidgets('stays while changes are still being sent', (tester) async {
      final session = await pumpButton(tester, leaves: false);

      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();

      expect(session.leaveCount, 1);
      expect(
        find.textContaining('Could not leave this page yet'),
        findsOneWidget,
      );
      expect(find.text('This page was deleted'), findsOneWidget);
    });
  });
}

class _ReadyAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}
