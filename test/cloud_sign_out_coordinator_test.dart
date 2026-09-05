import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/services/cloud_sign_out_coordinator.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('cancel keeps durable inactive strategy and media work signed in',
      (tester) async {
    var rawSignOuts = 0;
    var editorCloses = 0;
    final container = _container(
      opQueue: _pendingQueue(),
      mediaQueue: _pendingMedia(),
      rawSignOut: () async {
        rawSignOuts += 1;
        return true;
      },
      closeEditor: () async => editorCloses += 1,
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Cloud work is still waiting'), findsOneWidget);
    expect(
      find.textContaining('3 saved changes across 3 strategies'),
      findsOneWidget,
    );
    expect(find.textContaining('remains on this device'), findsOneWidget);
    expect(find.textContaining('same account signs in again'), findsOneWidget);
    expect(find.textContaining('Bind retake'), findsOneWidget);
    expect(find.textContaining('Ascent execute'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(rawSignOuts, 0);
    expect(editorCloses, 0);
  });

  testWidgets(
      'confirmed sign out closes the cloud editor without clearing work',
      (tester) async {
    var rawSignOuts = 0;
    var editorCloses = 0;
    final opQueue = _pendingQueue();
    final mediaQueue = _pendingMedia();
    final container = _container(
      opQueue: opQueue,
      mediaQueue: mediaQueue,
      rawSignOut: () async {
        rawSignOuts += 1;
        return true;
      },
      closeEditor: () async => editorCloses += 1,
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out Anyway'));
    await tester.pumpAndSettle();

    expect(editorCloses, 1);
    expect(rawSignOuts, 1);
    expect(opQueue.accountOutbox.workCount, 2);
    expect(mediaQueue.jobs, hasLength(1));
  });

  testWidgets('failed local persistence blocks sign out on screen',
      (tester) async {
    var rawSignOuts = 0;
    final container = _container(
      preparation: () async => throw StateError('disk full'),
      rawSignOut: () async {
        rawSignOuts += 1;
        return true;
      },
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    expect(find.text("Can't sign out yet"), findsOneWidget);
    expect(
      find.textContaining('could not confirm that all pending cloud work'),
      findsOneWidget,
    );
    expect(find.text('Sign Out Anyway'), findsNothing);
    expect(rawSignOuts, 0);
  });

  testWidgets('preparation commits drafts and asks both outboxes to persist',
      (tester) async {
    final strategy = _PreparingCloudStrategy();
    final media = _PreparingMediaQueue();
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith(_SignedInAuth.new),
      strategyProvider.overrideWith(() => strategy),
      strategySaveStateProvider.overrideWith(_CleanSaveState.new),
      strategyOpQueueProvider.overrideWith(
        () => _FixedOpQueue(const StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'active-strategy',
          durableLoaded: true,
        )),
      ),
      cloudMediaUploadQueueProvider.overrideWith(() => media),
      cloudEditorCloseProvider.overrideWithValue(() async {}),
      rawSignOutProvider.overrideWithValue(() async => true),
      cloudStrategyNamesProvider.overrideWithValue(const {}),
    ]);
    addTearDown(container.dispose);
    container
        .read(textDraftProvider.notifier)
        .setDraft('draft-no-longer-mounted', 'last thought');
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();

    expect(strategy.forceSaveCount, 1);
    expect(media.retryCount, 1);
    expect(container.read(textDraftProvider), isEmpty);
    expect(find.text('Sign out?'), findsOneWidget);
  });

  testWidgets('an unreliable durable outbox blocks sign out', (tester) async {
    var rawSignOuts = 0;
    final container = _container(
      opQueue: const StrategyOpQueueState(
        accountId: 'account-a',
        durableLoaded: true,
        hasDurabilityFailure: true,
      ),
      rawSignOut: () async {
        rawSignOuts += 1;
        return true;
      },
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    expect(find.text("Can't sign out yet"), findsOneWidget);
    expect(rawSignOuts, 0);
  });

  testWidgets('normal sign out still asks for explicit confirmation',
      (tester) async {
    var rawSignOuts = 0;
    final container = _container(
      rawSignOut: () async {
        rawSignOuts += 1;
        return true;
      },
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();
    expect(rawSignOuts, 1);
  });

  testWidgets('another account media is not shown or relabeled',
      (tester) async {
    final otherAccountMedia = CloudMediaUploadQueueState(
      jobs: [
        CloudMediaUploadJob(
          jobId: 'account-b-media',
          accountId: 'account-b',
          strategyPublicId: 'account-b-strategy',
          assetPublicId: 'account-b-media',
          fileExtension: 'png',
          mimeType: 'image/png',
          state: CloudMediaJobState.pendingUpload,
          referenceDurable: true,
          attempts: 0,
          updatedAt: DateTime.utc(2026),
        ),
      ],
      isProcessing: false,
    );
    final container = _container(mediaQueue: otherAccountMedia);
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out?'), findsOneWidget);
    expect(find.text('Cloud work is still waiting'), findsNothing);
    expect(find.textContaining('account-b'), findsNothing);
  });

  testWidgets('raw sign-out failure does not report success or navigate',
      (tester) async {
    var editorCloses = 0;
    final container = _container(
      rawSignOut: () async => false,
      closeEditor: () async => editorCloses += 1,
    );
    addTearDown(container.dispose);
    await _pumpHarness(tester, container);

    await tester.tap(find.text('Request sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign Out'));
    await tester.pumpAndSettle();

    expect(editorCloses, 1);
    expect(find.text('Sign out failed'), findsOneWidget);
    expect(find.text('Request sign out'), findsOneWidget);
  });
}

StrategyOpQueueState _pendingQueue() {
  return const StrategyOpQueueState(
    accountId: 'account-a',
    strategyPublicId: 'active-strategy',
    clientId: 'client-a',
    durableLoaded: true,
    accountOutbox: AccountStrategyOutboxSummary(
      accountId: 'account-a',
      strategies: {
        'active-strategy': StrategyOutboxSummary(
          strategyPublicId: 'active-strategy',
          queuedCount: 1,
          inFlightCount: 0,
          pausedCount: 0,
          attentionCount: 0,
          successorCount: 0,
        ),
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
  );
}

CloudMediaUploadQueueState _pendingMedia() {
  return CloudMediaUploadQueueState(
    jobs: [
      CloudMediaUploadJob(
        jobId: 'media-one',
        accountId: 'account-a',
        strategyPublicId: 'media-strategy',
        assetPublicId: 'media-one',
        fileExtension: 'png',
        mimeType: 'image/png',
        state: CloudMediaJobState.pendingUpload,
        referenceDurable: true,
        attempts: 0,
        updatedAt: DateTime.utc(2026),
      ),
    ],
    isProcessing: false,
  );
}

ProviderContainer _container({
  StrategyOpQueueState opQueue = const StrategyOpQueueState(
    accountId: 'account-a',
    durableLoaded: true,
  ),
  CloudMediaUploadQueueState mediaQueue = const CloudMediaUploadQueueState(
    jobs: [],
    isProcessing: false,
  ),
  CloudSignOutPreparation? preparation,
  RawSignOut? rawSignOut,
  CloudEditorClose? closeEditor,
}) {
  return ProviderContainer(overrides: [
    authProvider.overrideWith(_SignedInAuth.new),
    strategyProvider.overrideWith(_ActiveCloudStrategy.new),
    strategySaveStateProvider.overrideWith(_CleanSaveState.new),
    strategyOpQueueProvider.overrideWith(() => _FixedOpQueue(opQueue)),
    cloudMediaUploadQueueProvider.overrideWith(
      () => _FixedMediaQueue(mediaQueue),
    ),
    cloudSignOutPreparationProvider.overrideWithValue(
      preparation ?? () async {},
    ),
    rawSignOutProvider.overrideWithValue(rawSignOut ?? () async => true),
    cloudEditorCloseProvider.overrideWithValue(closeEditor ?? () async {}),
    cloudStrategyNamesProvider.overrideWithValue(const {
      'active-strategy': 'Active strategy',
      'closed-strategy': 'Bind retake',
      'media-strategy': 'Ascent execute',
    }),
  ]);
}

Future<void> _pumpHarness(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ShadApp(home: _SignOutHarness()),
    ),
  );
}

class _SignOutHarness extends ConsumerWidget {
  const _SignOutHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ShadButton(
          onPressed: () => unawaited(
            ref.read(cloudSignOutRequestProvider)(context),
          ),
          child: const Text('Request sign out'),
        ),
      ),
    );
  }
}

class _SignedInAuth extends AuthProvider {
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

class _ActiveCloudStrategy extends StrategyProvider {
  @override
  StrategyState build() => const StrategyState(
        strategyId: 'active-strategy',
        strategyName: 'Active strategy',
        source: StrategySource.cloud,
        storageDirectory: null,
        isOpen: true,
      );
}

class _PreparingCloudStrategy extends _ActiveCloudStrategy {
  int forceSaveCount = 0;

  @override
  Future<void> forceSaveNow(String id) async {
    forceSaveCount += 1;
  }
}

class _CleanSaveState extends StrategySaveStateNotifier {
  @override
  StrategySaveState build() => const StrategySaveState(
        isDirty: false,
        isSaving: false,
        hasPendingCloudSync: false,
        cloudSyncError: null,
        hasPendingMediaSync: false,
        mediaSyncErrorCount: 0,
        lastPersistedAt: null,
      );
}

class _FixedOpQueue extends StrategyOpQueueNotifier {
  _FixedOpQueue(this.initialState);

  final StrategyOpQueueState initialState;

  @override
  StrategyOpQueueState build() => initialState;
}

class _FixedMediaQueue extends CloudMediaUploadQueueNotifier {
  _FixedMediaQueue(this.initialState);

  final CloudMediaUploadQueueState initialState;

  @override
  CloudMediaUploadQueueState build() => initialState;
}

class _PreparingMediaQueue extends CloudMediaUploadQueueNotifier {
  int retryCount = 0;

  @override
  CloudMediaUploadQueueState build() => const CloudMediaUploadQueueState(
        jobs: [],
        isProcessing: false,
      );

  @override
  Future<void> retryNow({bool ignoreBackoff = false}) async {
    retryCount += 1;
  }
}
