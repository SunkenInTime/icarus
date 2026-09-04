import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/active_page_live_sync_models.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

bool _adaptersRegistered = false;

class _FakeGuardStrategyProvider extends StrategyProvider {
  _FakeGuardStrategyProvider({
    required this.initialState,
    required this.flushResult,
    this.flushError,
  });

  final StrategyState initialState;
  final bool flushResult;
  final Object? flushError;

  int flushCalls = 0;
  int forceSaveCalls = 0;
  int cancelPendingSaveCalls = 0;

  @override
  StrategyState build() => initialState;

  @override
  Future<bool> flushPendingAutosaveBeforeExit() async {
    flushCalls++;
    if (flushError != null) {
      throw flushError!;
    }
    return flushResult;
  }

  @override
  Future<void> forceSaveNow(String id) async {
    forceSaveCalls++;
    ref.read(strategySaveStateProvider.notifier).markPersisted();
  }

  @override
  void cancelPendingSave() {
    cancelPendingSaveCalls++;
  }
}

class _ThrowingSaveStrategyProvider extends StrategyProvider {
  _ThrowingSaveStrategyProvider(this.initialState);

  final StrategyState initialState;

  @override
  StrategyState build() => initialState;

  @override
  Future<void> forceSaveNow(String id) {
    throw StateError('save failed');
  }
}

class _GuardAuthProvider extends AuthProvider {
  @override
  AppAuthState build() => const AppAuthState(
        isLoading: false,
        isAuthenticated: true,
        isConvexUserReady: true,
        convexAuthStatus: ConvexAuthStatus.ready,
        user: null,
      );
}

class _GuardOpQueue extends StrategyOpQueueNotifier {
  _GuardOpQueue(this.initialState);

  final StrategyOpQueueState initialState;

  @override
  StrategyOpQueueState build() => initialState;

  StrategyOpQueueState get currentState => state;

  void settle() {
    state = StrategyOpQueueState(
      accountId: initialState.accountId,
      strategyPublicId: initialState.strategyPublicId,
      clientId: initialState.clientId,
      durableLoaded: true,
    );
  }
}

class _GuardMediaQueue extends CloudMediaUploadQueueNotifier {
  _GuardMediaQueue([
    this.initialState = const CloudMediaUploadQueueState(
      jobs: [],
      isProcessing: false,
    ),
  ]);

  final CloudMediaUploadQueueState initialState;

  @override
  CloudMediaUploadQueueState build() => initialState;
}

const _guardEntityKey = EntitySyncKey.strategy();
const _guardPendingIntent = QueuedEntityIntent(
  entityKey: _guardEntityKey,
  pending: PendingOp(
    op: StrategyPatchOp(
      opId: 'guard-op',
      payload: <String, dynamic>{'name': 'pending'},
      expectedStrategyRevision: 1,
    ),
    clientId: 'guard-client',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));

  setUpAll(() {
    appProviderContainer = ProviderContainer();
  });

  tearDownAll(() {
    appProviderContainer.dispose();
  });

  group('StrategyProvider.flushPendingAutosaveBeforeExit', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'icarus-unsaved-guard-provider-',
      );
      Hive.init(tempDir.path);
      if (!_adaptersRegistered) {
        registerIcarusAdapters(Hive);
        _adaptersRegistered = true;
      }
      await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
      await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
      await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
      await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
      await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
      container = ProviderContainer();
    });

    tearDown(() async {
      container.dispose();
      await Hive.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('autosave enabled saves dirty strategy and returns true', () async {
      await _setAutosaveEnabled(true);
      final strategy = await _storeStrategyWithText(
        id: 'strategy-1',
        name: 'Strategy 1',
        text: 'before',
      );

      container
          .read(textProvider.notifier)
          .fromHive(strategy.pages.single.textData);
      container
          .read(textDraftProvider.notifier)
          .setDraft('text-1', 'autosaved draft');

      final notifier = container.read(strategyProvider.notifier);
      notifier.setFromState(
        StrategyState(
          strategyId: strategy.id,
          strategyName: strategy.name,
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
      );
      container.read(strategySaveStateProvider.notifier).markDirty();

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isTrue);
      expect(container.read(strategySaveStateProvider).isDirty, isFalse);
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'autosaved draft');
    });

    test('autosave disabled returns false without saving', () async {
      await _setAutosaveEnabled(false);
      final strategy = await _storeStrategyWithText(
        id: 'strategy-2',
        name: 'Strategy 2',
        text: 'before',
      );

      container
          .read(textProvider.notifier)
          .fromHive(strategy.pages.single.textData);
      container
          .read(textDraftProvider.notifier)
          .setDraft('text-1', 'unsaved draft');

      final notifier = container.read(strategyProvider.notifier);
      notifier.setFromState(
        StrategyState(
          strategyId: strategy.id,
          strategyName: strategy.name,
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
      );
      container.read(strategySaveStateProvider.notifier).markDirty();

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isFalse);
      expect(container.read(strategySaveStateProvider).isDirty, isTrue);
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'before');
    });

    test('an active draft is saved even when committed state was clean',
        () async {
      await _setAutosaveEnabled(true);
      final strategy = await _storeStrategyWithText(
        id: 'strategy-3',
        name: 'Strategy 3',
        text: 'before',
      );

      container
          .read(textProvider.notifier)
          .fromHive(strategy.pages.single.textData);
      container
          .read(textDraftProvider.notifier)
          .setDraft('text-1', 'active draft');

      final notifier = container.read(strategyProvider.notifier);
      notifier.setFromState(
        StrategyState(
          strategyId: strategy.id,
          strategyName: strategy.name,
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
      );

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isTrue);
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'active draft');
    });

    test('no loaded strategy returns true', () async {
      await _setAutosaveEnabled(true);
      final notifier = container.read(strategyProvider.notifier);

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isTrue);
    });

    test('save failure throws to the caller', () async {
      await _setAutosaveEnabled(true);
      final container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(
            () => _ThrowingSaveStrategyProvider(
              const StrategyState(
                strategyId: 'strategy-4',
                strategyName: 'Strategy 4',
                source: StrategySource.local,
                storageDirectory: null,
                isOpen: true,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();

      await expectLater(
        container
            .read(strategyProvider.notifier)
            .flushPendingAutosaveBeforeExit(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('guardUnsavedStrategyExit', () {
    late ProviderContainer container;
    late _FakeGuardStrategyProvider notifier;
    late BuildContext context;
    late WidgetRef ref;

    Future<void> pumpHarness(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Scaffold(
              body: Consumer(
                builder: (buildContext, widgetRef, _) {
                  context = buildContext;
                  ref = widgetRef;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    setUp(() {
      appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
    });

    testWidgets(
        'dirty autosave-enabled exit saves and continues without dialog',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-a',
          strategyName: 'Strategy A',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: true,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await pumpHarness(tester);

      var continueCalls = 0;
      final result = await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-autosave',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.flushCalls, 1);
      expect(find.text('Save changes?'), findsNothing);
    });

    testWidgets('clean local state still flushes an active text draft',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-draft',
          strategyName: 'Draft Strategy',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: true,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(textDraftProvider.notifier)
          .setDraft('text-1', 'active local draft');
      await pumpHarness(tester);

      var continueCalls = 0;
      final result = await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-local-draft',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.flushCalls, 1);
      expect(find.text('Save changes?'), findsNothing);
    });

    testWidgets(
        'dirty autosave-disabled exit shows dialog and save still works',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-b',
          strategyName: 'Strategy B',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: false,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-manual-save',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final result = await guardFuture;
      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.flushCalls, 1);
      expect(notifier.forceSaveCalls, 1);
    });

    testWidgets(
        'dirty autosave-disabled exit keeps dont-save branch behavior intact',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-c',
          strategyName: 'Strategy C',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: false,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-dont-save',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text("Don't Save"));
      await tester.pumpAndSettle();

      final result = await guardFuture;
      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.cancelPendingSaveCalls, 1);
      expect(notifier.forceSaveCalls, 0);
    });

    testWidgets('autosave flush failure reports error and blocks exit',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-d',
          strategyName: 'Strategy D',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: true,
        flushError: StateError('boom'),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await pumpHarness(tester);

      var continueCalls = 0;
      final result = await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-error',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(continueCalls, 0);
      expect(find.text('Save changes?'), findsNothing);
      final logs = appProviderContainer.read(inAppDebugProvider);
      expect(logs, isNotEmpty);
      expect(logs.last.message, 'Failed to save strategy before leaving.');
      expect(logs.last.source, 'guard-test-error');
    });

    testWidgets('offline durable work can leave and remains queued',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final opQueue = _GuardOpQueue(
        StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'guard-client',
          queuedByEntityKey: {_guardEntityKey: _guardPendingIntent},
          durableLoaded: true,
          lastError: 'Cloud connection is offline.',
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(() => opQueue),
          cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-offline',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsOneWidget);
      expect(
        find.textContaining('have not reached the cloud'),
        findsOneWidget,
      );
      expect(opQueue.currentState.pending, hasLength(1));
      await tester.tap(find.text('Leave Anyway'));
      await tester.pumpAndSettle();

      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
      expect(opQueue.currentState.pending, hasLength(1));
    });

    testWidgets('paused viewer work has a leave-anyway path', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final opQueue = _GuardOpQueue(
        StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'guard-client',
          pausedByEntityKey: {_guardEntityKey: _guardPendingIntent},
          durableLoaded: true,
          lastError: 'This viewer edit cannot be retried automatically.',
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(() => opQueue),
          cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-viewer',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsOneWidget);
      await tester.tap(find.text('Leave Anyway'));
      await tester.pumpAndSettle();

      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
      expect(opQueue.currentState.pausedByEntityKey, isNotEmpty);
    });

    testWidgets('non-durable cloud work cannot leave', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final opQueue = _GuardOpQueue(
        StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'guard-client',
          queuedByEntityKey: {_guardEntityKey: _guardPendingIntent},
          durableLoaded: true,
          hasDurabilityFailure: true,
          lastError: 'Cloud work could not be saved to the durable outbox.',
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(() => opQueue),
          cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-nondurable',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsNothing);
      expect(find.text('Stay Here'), findsOneWidget);
      await tester.tap(find.text('Stay Here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
    });

    testWidgets('an unreliable media outbox cannot leave', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final mediaQueue = _GuardMediaQueue(
        CloudMediaUploadQueueState(
          jobs: [
            CloudMediaUploadJob(
              jobId: 'image-a',
              accountId: 'account-a',
              strategyPublicId: 'cloud-strategy',
              assetPublicId: 'image-a',
              fileExtension: '.png',
              mimeType: 'image/png',
              state: CloudMediaJobState.pendingUpload,
              attempts: 0,
              updatedAt: DateTime.utc(2026, 9, 3),
            ),
          ],
          isProcessing: false,
          durabilityError: 'Media work could not be saved on this device.',
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(
            () => _GuardOpQueue(
              const StrategyOpQueueState(
                accountId: 'account-a',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              ),
            ),
          ),
          cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-unreliable-media',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsNothing);
      expect(find.textContaining('could not confirm'), findsOneWidget);
      await tester.tap(find.text('Stay Here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
    });

    testWidgets(
        'current-strategy unknown-owner media can leave but never claims retry',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final mediaQueue = _GuardMediaQueue(
        CloudMediaUploadQueueState(
          jobs: const [],
          unknownOwnerJobs: [
            CloudMediaUploadJob(
              jobId: 'legacy-image',
              accountId: null,
              strategyPublicId: 'cloud-strategy',
              assetPublicId: 'legacy-image',
              fileExtension: '.png',
              mimeType: 'image/png',
              state: CloudMediaJobState.pendingUpload,
              attempts: 0,
              updatedAt: DateTime.utc(2026, 9, 3),
            ),
          ],
          isProcessing: false,
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(
            () => _GuardOpQueue(
              const StrategyOpQueueState(
                accountId: 'account-b',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              ),
            ),
          ),
          cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-unknown-owner',
        onContinue: () async {
          continueCalls += 1;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsOneWidget);
      expect(find.textContaining('will not be sent automatically'),
          findsOneWidget);
      await tester.tap(find.text('Leave Anyway'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
    });

    testWidgets('unrelated unknown-owner media does not block exit',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final mediaQueue = _GuardMediaQueue(
        CloudMediaUploadQueueState(
          jobs: const [],
          unknownOwnerJobs: [
            CloudMediaUploadJob(
              jobId: 'legacy-image',
              accountId: null,
              strategyPublicId: 'other-strategy',
              assetPublicId: 'legacy-image',
              fileExtension: '.png',
              mimeType: 'image/png',
              state: CloudMediaJobState.pendingUpload,
              attempts: 0,
              updatedAt: DateTime.utc(2026, 9, 3),
            ),
          ],
          isProcessing: false,
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(
            () => _GuardOpQueue(
              const StrategyOpQueueState(
                accountId: 'account-b',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              ),
            ),
          ),
          cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      var continueCalls = 0;
      final result = await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-unrelated-unknown-owner',
        onContinue: () async {
          continueCalls += 1;
        },
      );
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(find.text('Cloud sync pending'), findsNothing);
    });

    testWidgets('media without a durable strategy reference cannot leave',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final mediaQueue = _GuardMediaQueue(
        CloudMediaUploadQueueState(
          jobs: [
            CloudMediaUploadJob(
              jobId: 'staged-image',
              accountId: 'account-a',
              strategyPublicId: 'cloud-strategy',
              assetPublicId: 'staged-image',
              fileExtension: '.png',
              mimeType: 'image/png',
              state: CloudMediaJobState.pendingUpload,
              referenceDurable: false,
              attempts: 0,
              updatedAt: DateTime.utc(2026, 9, 3),
            ),
          ],
          isProcessing: false,
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(
            () => _GuardOpQueue(
              const StrategyOpQueueState(
                accountId: 'account-a',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              ),
            ),
          ),
          cloudMediaUploadQueueProvider.overrideWith(() => mediaQueue),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-staged-media',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave Anyway'), findsNothing);
      await tester.tap(find.text('Stay Here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
    });

    testWidgets('cloud exit stages an active text draft before leaving',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(
            () => _GuardOpQueue(
              const StrategyOpQueueState(
                accountId: 'account-a',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              ),
            ),
          ),
          cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(textDraftProvider.notifier)
          .setDraft('text-a', 'active cloud draft');
      await pumpHarness(tester);

      var continueCalls = 0;
      final result = await guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-draft',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.forceSaveCalls, 1);
      expect(container.read(textDraftProvider), isEmpty);
    });

    testWidgets('active cloud flush completes and exits without a dialog',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
      );
      final opQueue = _GuardOpQueue(
        StrategyOpQueueState(
          accountId: 'account-a',
          strategyPublicId: 'cloud-strategy',
          clientId: 'guard-client',
          queuedByEntityKey: {_guardEntityKey: _guardPendingIntent},
          durableLoaded: true,
          isFlushing: true,
        ),
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(() => opQueue),
          cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(true),
        ],
      );
      addTearDown(container.dispose);
      await pumpHarness(tester);

      var continueCalls = 0;
      final guardFuture = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-flush',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pump();
      opQueue.settle();
      await tester.pump(const Duration(milliseconds: 150));

      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
      expect(find.text('Cloud sync pending'), findsNothing);
    });
  });
}

Future<void> _setAutosaveEnabled(bool enabled) async {
  await Hive.box<AppPreferences>(HiveBoxNames.appPreferencesBox).put(
    MapThemeProfilesProvider.appPreferencesSingletonKey,
    AppPreferences(
      defaultThemeProfileIdForNewStrategies:
          MapThemeProfilesProvider.immutableDefaultProfileId,
      autosaveEnabled: enabled,
    ),
  );
}

Future<StrategyData> _storeStrategyWithText({
  required String id,
  required String name,
  required String text,
}) async {
  final page = StrategyPage(
    id: 'page-1',
    name: 'Page 1',
    drawingData: const [],
    agentData: const [],
    abilityData: const [],
    textData: [
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = text,
    ],
    imageData: const [],
    utilityData: const [],
    sortIndex: 0,
    isAttack: true,
    settings: StrategySettings(),
  );
  final strategy = StrategyData(
    id: id,
    name: name,
    mapData: MapValue.ascent,
    versionNumber: 1,
    lastEdited: DateTime(2024),
    folderID: null,
    pages: [page],
  );
  await Hive.box<StrategyData>(HiveBoxNames.strategiesBox).put(id, strategy);
  return strategy;
}
