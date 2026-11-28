import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/strategy/open_seen.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/strategy/autosave_before_exit.dart';
import 'package:icarus/collab/cloud_media_models.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/durable_cloud_media_outbox.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/const/agents.dart';
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
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy/store_save_facts.dart';
import 'package:icarus/strategy/strategy_page_source.dart';
import 'package:icarus/providers/strategy_opening_provider.dart';
import 'package:icarus/strategy_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:toastification/toastification.dart';
import 'opens_now_support.dart';

bool _adaptersRegistered = false;

class _JoinedStrategies extends StrategyProvider {
  _JoinedStrategies({
    required this.autosaveOn,
    this.saveError,
    this.autosaveFails = false,
  });

  final bool autosaveOn;
  final bool autosaveFails;
  final Object? saveError;
  Completer<void>? heldSave;
  final _autosave = Completer<void>();
  var flushes = 0;
  var saves = 0;
  var cancelled = 0;

  void finishTheAutosave() => _autosave.complete();

  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-a',
        strategyName: 'Strategy A',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  @override
  Future<AutosaveBeforeExit> flushPendingAutosaveBeforeExit() async {
    flushes++;
    if (!autosaveOn) {
      return const NotAutosaved(NotAutosavedBecause.autosaveIsOff);
    }
    await _autosave.future;
    if (autosaveFails) {
      return const NotAutosaved(NotAutosavedBecause.stillUnsaved);
    }
    ref.read(strategySaveStateProvider.notifier).markPersisted();
    return const NothingLeftUnsaved();
  }

  @override
  Future<void> forceSaveNow(String id) async {
    saves++;
    if (saveError case final error?) throw error;
    final saveState = ref.read(strategySaveStateProvider.notifier);
    final snapshot = saveState.dirtyMarks;
    if (heldSave case final held?) {
      heldSave = null;
      await held.future;
    }
    saveState.markPersisted(dirtyMarksSaved: snapshot);
  }

  @override
  void cancelPendingSave() => cancelled++;
}

class _FakeGuardStrategyProvider extends StrategyProvider {
  _FakeGuardStrategyProvider({
    required this.initialState,
    required this.flushResult,
    this.flushError,
    this.saveError,
    this.holdsCanvas = false,
  });

  final StrategyState initialState;
  final bool flushResult;
  final Object? flushError;
  final Object? saveError;
  final bool holdsCanvas;

  int flushCalls = 0;
  int forceSaveCalls = 0;
  int cancelPendingSaveCalls = 0;

  @override
  StrategyState build() => initialState;

  @override
  Future<AutosaveBeforeExit> flushPendingAutosaveBeforeExit() async {
    flushCalls++;
    if (flushError != null) {
      throw flushError!;
    }
    return flushResult
        ? const NothingLeftUnsaved()
        : const NotAutosaved(NotAutosavedBecause.autosaveIsOff);
  }

  @override
  Future<void> forceSaveNow(String id) async {
    forceSaveCalls++;
    if (saveError case final error?) throw error;
    final saveState = ref.read(strategySaveStateProvider.notifier);
    if (holdsCanvas) {
      saveState.noteCanvasHandover(
        const HeldOnCanvas(HeldReason.outboxWriteFailed),
        marksBefore: saveState.dirtyMarks,
      );
      return;
    }
    saveState.markPersisted();
  }

  @override
  void cancelPendingSave() {
    cancelPendingSaveCalls++;
  }
}

class _SavesWhatItSnapshots extends StrategyProvider {
  _SavesWhatItSnapshots({required this.autosaves});

  final bool autosaves;
  final firstWrite = Completer<void>();
  var writes = 0;

  @override
  StrategyState build() => const StrategyState(
        strategyId: 'strategy-written',
        strategyName: 'Strategy written',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      );

  Future<void> _write() async {
    final saveState = ref.read(strategySaveStateProvider.notifier);
    final snapshot = saveState.dirtyMarks;
    writes += 1;
    if (writes == 1) await firstWrite.future;
    saveState.markPersisted(dirtyMarksSaved: snapshot);
  }

  @override
  Future<AutosaveBeforeExit> flushPendingAutosaveBeforeExit() async {
    if (!ref.read(strategySaveStateProvider).isDirty) {
      return const NothingLeftUnsaved();
    }
    if (!autosaves) {
      return const NotAutosaved(NotAutosavedBecause.autosaveIsOff);
    }
    final marks = ref.read(strategySaveStateProvider.notifier).dirtyMarks;
    await _write();
    if (!ref.read(strategySaveStateProvider).isDirty) {
      return const NothingLeftUnsaved();
    }
    return ref.read(strategySaveStateProvider.notifier).dirtyMarks != marks
        ? const EditedDuringTheAutosave()
        : const NotAutosaved(NotAutosavedBecause.stillUnsaved);
  }

  @override
  Future<void> forceSaveNow(String id) => _write();
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

  void failDurability() {
    state = state.copyWith(hasDurabilityFailure: true);
  }

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
  setUp(() => StrategyView.onScreen.value = 1);
  tearDown(() => StrategyView.onScreen.value = 0);

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

      expect(result, isA<NothingLeftUnsaved>());
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

      expect(result, isA<NotAutosaved>());
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

      expect(result, isA<NothingLeftUnsaved>());
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'active draft');
    });

    test('no loaded strategy returns true', () async {
      await _setAutosaveEnabled(true);
      final notifier = container.read(strategyProvider.notifier);

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isA<NothingLeftUnsaved>());
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

    testWidgets(
        'an edit made while the autosave before leaving writes is saved by '
        'another write before the exit goes', (tester) async {
      late StrategyData strategy;
      await tester.runAsync(() async {
        await _setAutosaveEnabled(true);
        strategy = await _storeStrategyWithText(
          id: 'strategy-edited-during',
          name: 'Edited during',
          text: 'before',
        );
      });
      container
          .read(textProvider.notifier)
          .fromHive(strategy.pages.single.textData);
      container.read(strategyProvider.notifier).setFromState(
            StrategyState(
              strategyId: strategy.id,
              strategyName: strategy.name,
              source: StrategySource.local,
              storageDirectory: null,
              isOpen: true,
            ),
          );
      container.read(strategySaveStateProvider.notifier).markDirty();
      late BuildContext context;
      late WidgetRef ref;
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Scaffold(
            body: Consumer(builder: (buildContext, widgetRef, _) {
              context = buildContext;
              ref = widgetRef;
              return const SizedBox.shrink();
            }),
          ),
        ),
      ));

      final answer = await tester.runAsync(() {
        final leaving = guardUnsavedStrategyExit(
          context: context,
          ref: ref,
          source: 'guard-test-edit-during-the-autosave',
        );
        container.read(agentProvider.notifier).addAgent(PlacedAgent(
              id: 'placed-during-the-autosave',
              type: AgentType.jett,
              position: const Offset(300, 300),
            ));
        container.read(strategySaveStateProvider.notifier).markDirty();
        return leaving.timeout(
          const Duration(seconds: 5),
          onTimeout: () => const Stay(),
        );
      });

      expect(answer, isA<Leave>());
      expect(container.read(strategySaveStateProvider).isDirty, isFalse);
      expect(
        Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
            .get(strategy.id)!
            .pages
            .single
            .agentData
            .map((agent) => agent.id),
        contains('placed-during-the-autosave'),
      );
    });
  });

  group('guardUnsavedStrategyExit', () {
    for (final autosaves in [false]) {
      testWidgets(
          'an edit made while the Save of the prompt writes is saved too '
          'before the exit goes', (tester) async {
        final strategies = _SavesWhatItSnapshots(autosaves: autosaves);
        final container = ProviderContainer(
          overrides: [strategyProvider.overrideWith(() => strategies)],
        );
        addTearDown(container.dispose);
        container.read(strategySaveStateProvider.notifier).markDirty();
        late BuildContext context;
        late WidgetRef ref;
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: Scaffold(
              body: Consumer(builder: (buildContext, widgetRef, _) {
                context = buildContext;
                ref = widgetRef;
                return const SizedBox.shrink();
              }),
            ),
          ),
        ));

        final leaving = guardUnsavedStrategyExit(
          context: context,
          ref: ref,
          source: 'guard-test-edit-during-the-write',
        );
        await tester.pumpAndSettle();
        if (!autosaves) {
          await tester.tap(find.text('Save'));
          await tester.pump();
        }
        expect(strategies.writes, 1);
        container.read(strategySaveStateProvider.notifier).markDirty();
        strategies.firstWrite.complete();
        await tester.pumpAndSettle();

        expect(await leaving, isA<Leave>());
        expect(strategies.writes, 2);
        expect(container.read(strategySaveStateProvider).isDirty, isFalse);
      });
    }

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

    Future<void> pumpLibraryUnderEditor(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(home: Scaffold(body: Text('Library'))),
        ),
      );
      final library = tester.element(find.text('Library'));
      unawaited(Navigator.of(library).push(MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Consumer(
            builder: (buildContext, widgetRef, _) {
              context = buildContext;
              ref = widgetRef;
              return const Text('Editor');
            },
          ),
        ),
      )));
      await tester.pumpAndSettle();
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
      final result = await guardThenIgnoringWhatItSaw(
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

    testWidgets(
        'a Save that returns but leaves the strategy unsaved keeps the user '
        'in the editor and says the save failed', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-held',
          strategyName: 'Strategy held',
          source: StrategySource.local,
          storageDirectory: null,
          isOpen: true,
        ),
        flushResult: false,
        holdsCanvas: true,
      );
      container = ProviderContainer(
        overrides: [strategyProvider.overrideWith(() => notifier)],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await pumpHarness(tester);

      var continueCalls = 0;
      final leaving = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-save-left-unsaved',
        onContinue: () async => continueCalls++,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(await leaving, isFalse);
      expect(continueCalls, 0);
      expect(notifier.forceSaveCalls, 1);
      expect(
        appProviderContainer.read(inAppDebugProvider).last.message,
        'Failed to save strategy before leaving.',
      );
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
      final result = await guardThenIgnoringWhatItSaw(
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
      final guardFuture = guardThenIgnoringWhatItSaw(
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
        'the save dialog closes without saving or leaving once another '
        'strategy is the open one', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-a',
          strategyName: 'Strategy A',
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-strategy-changed',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);

      notifier.setFromState(const StrategyState(
        strategyId: 'strategy-b',
        strategyName: 'Strategy B',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsNothing);
      expect(await guardFuture, isFalse);
      expect(notifier.forceSaveCalls, 0);
      expect(notifier.cancelPendingSaveCalls, 0);
      expect(continueCalls, 0);
    });

    for (final choice in ["Don't save", 'Save']) {
      testWidgets(
          'leaving the editor for the library through "$choice" leaves the '
          'library on screen', (tester) async {
        notifier = _FakeGuardStrategyProvider(
          initialState: const StrategyState(
            strategyId: 'strategy-left',
            strategyName: 'Strategy Left',
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
        await pumpLibraryUnderEditor(tester);

        final guardFuture = guardThenIgnoringWhatItSaw(
          context: context,
          ref: ref,
          source: 'guard-test-leave-to-library',
          onContinue: () async {
            Navigator.pop(context);
            notifier.setFromState(const StrategyState(
              strategyId: null,
              strategyName: null,
              source: StrategySource.local,
              storageDirectory: null,
            ));
          },
        );
        await tester.pumpAndSettle();
        expect(find.text('Save changes?'), findsOneWidget);

        await tester.tap(find.text(choice));
        await tester.pumpAndSettle();

        expect(await guardFuture, isTrue);
        expect(find.text('Save changes?'), findsNothing);
        expect(find.text('Library'), findsOneWidget);
        expect(find.text('Editor'), findsNothing);
      });
    }

    testWidgets(
        'once another strategy is the open one, the save dialog closes under '
        'a screen pushed over it and leaves that screen showing',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'strategy-covered',
          strategyName: 'Strategy Covered',
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
      await pumpLibraryUnderEditor(tester);

      var continueCalls = 0;
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-covered',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      unawaited(Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Pushed over the dialog')),
      )));
      await tester.pumpAndSettle();

      notifier.setFromState(const StrategyState(
        strategyId: 'strategy-other',
        strategyName: 'Strategy Other',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Pushed over the dialog'), findsOneWidget);
      expect(find.text('Save changes?', skipOffstage: false), findsNothing);
      expect(await guardFuture, isFalse);
      expect(continueCalls, 0);
      Navigator.of(tester.element(find.text('Pushed over the dialog'))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Editor'), findsOneWidget);
    });

    testWidgets(
        "Don't save leaves the pending save alone until the exit goes ahead",
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-dont-save',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text("Don't save"));
      await tester.pumpAndSettle();

      final result = await guardFuture;
      expect(result, isTrue);
      expect(continueCalls, 1);
      expect(notifier.cancelPendingSaveCalls, 0);
      expect(notifier.forceSaveCalls, 0);
    });

    testWidgets(
        'autosave flush failure reports error and asks before leaving',
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-error',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
      expect(continueCalls, 0);
      final logs = appProviderContainer.read(inAppDebugProvider);
      expect(logs, isNotEmpty);
      expect(logs.last.message, 'Failed to save strategy before leaving.');
      expect(logs.last.source, 'guard-test-error');
    });

    testWidgets('refused work can leave without a promise to retry it',
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
          attentionByEntityKey: {_guardEntityKey: _guardPendingIntent},
          durableLoaded: true,
          lastError: lineupPageMismatchMessage,
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

      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-refused',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsOneWidget);
      expect(find.textContaining('another page'), findsOneWidget);
      expect(find.textContaining('from the sync button'), findsOneWidget);
      expect(find.textContaining('retry it later'), findsNothing);
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isTrue);
    });

    group('a store-owned strategy', () {
      Future<Future<bool>> leaving(
        WidgetTester tester, {
        required StoreAheadOfServer ahead,
        bool canvasAhead = false,
        bool connected = true,
      }) async {
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
              () => _GuardOpQueue(const StrategyOpQueueState(
                accountId: 'account-a',
                strategyPublicId: 'cloud-strategy',
                clientId: 'guard-client',
                durableLoaded: true,
              )),
            ),
            cloudMediaUploadQueueProvider.overrideWith(_GuardMediaQueue.new),
            authProvider.overrideWith(_GuardAuthProvider.new),
            convexConnectionSnapshotProvider.overrideWithValue(connected),
          ],
        );
        addTearDown(container.dispose);
        final save = container.read(strategySaveStateProvider.notifier)
          ..beginStoreOwned()
          ..noteStoreAheadOfServer(ahead);
        if (canvasAhead) save.markDirty();
        await pumpHarness(tester);
        final guard = guardThenIgnoringWhatItSaw(
          context: context,
          ref: ref,
          source: 'guard-test-store-owned',
          onContinue: () async {},
        );
        await tester.pumpAndSettle();
        return guard;
      }

      testWidgets('leaves at once when nothing is ahead of the server',
          (tester) async {
        final guard =
            await leaving(tester, ahead: const StoreMatchesServer());
        expect(find.text('Leave anyway'), findsNothing);
        expect(await guard, isTrue);
      });

      testWidgets(
          'asks before leaving work the store holds unsent, though the old '
          'queue holds none, and lets it leave', (tester) async {
        final guard = await leaving(
          tester,
          ahead: const StoreSending(1),
          connected: false,
        );
        expect(find.text('Leave anyway'), findsOneWidget);
        expect(find.textContaining('have not reached the cloud'),
            findsOneWidget);
        expect(find.textContaining('saved on this device'), findsOneWidget);
        await tester.tap(find.text('Leave anyway'));
        await tester.pumpAndSettle();
        expect(await guard, isTrue);
      });

      testWidgets('says refused work is chosen later from the sync button',
          (tester) async {
        final guard = await leaving(tester, ahead: const StoreNeedsUser(1));
        expect(find.textContaining('choose what to keep'), findsOneWidget);
        await tester.tap(find.text('Stay here'));
        await tester.pumpAndSettle();
        expect(await guard, isFalse);
      });

      testWidgets(
          'a canvas the store does not hold yet cannot leave anyway, and is '
          'handed over first', (tester) async {
        final guard = await leaving(
          tester,
          ahead: const StoreMatchesServer(),
          canvasAhead: true,
        );
        expect(notifier.forceSaveCalls, 1);
        expect(find.text('Leave anyway'), findsNothing);
        await tester.tap(find.text('Stay here'));
        await tester.pumpAndSettle();
        expect(await guard, isFalse);
      });
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-offline',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsOneWidget);
      expect(
        find.textContaining('have not reached the cloud'),
        findsOneWidget,
      );
      expect(opQueue.currentState.pending, hasLength(1));
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();

      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
      expect(opQueue.currentState.pending, hasLength(1));
    });

    testWidgets(
        'an edit held only on the canvas cannot leave beside unrelated '
        'durable work', (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: true,
        holdsCanvas: true,
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
      container.read(strategySaveStateProvider.notifier).markDirty();

      var continueCalls = 0;
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-canvas-held',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(notifier.forceSaveCalls, 1);
      expect(find.text('Leave anyway'), findsNothing);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
      expect(continueCalls, 0);
    });

    testWidgets('leave anyway checks again what changed while it was asked',
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-leave-recheck',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('Leave anyway'), findsOneWidget);

      // The outbox stops being trustworthy while the dialog is open.
      opQueue.failDurability();
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();

      expect(continueCalls, 0);
      expect(find.text('Leave anyway'), findsNothing);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
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
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-viewer',
        onContinue: () async {
          continueCalls++;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsOneWidget);
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();

      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
      expect(opQueue.currentState.pausedByEntityKey, isNotEmpty);
    });

    Future<void> startWithCloudWorkNotKept(
      WidgetTester tester, {
      Object? retryError,
      bool autosaves = true,
    }) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: const StrategyState(
          strategyId: 'cloud-strategy',
          strategyName: 'Cloud Strategy',
          source: StrategySource.cloud,
          isOpen: true,
        ),
        flushResult: autosaves,
        saveError: retryError,
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
    }

    Future<LeaveAnswer> close() => guardUnsavedStrategyExit(
          context: context,
          ref: ref,
          source: 'guard-test-cloud-close',
          closesWindow: true,
        );

    testWidgets(
        'two closes with cloud work not yet kept show one cloud prompt, and '
        'Stay here keeps the editor for both', (tester) async {
      await startWithCloudWorkNotKept(tester);
      final first = close();
      await tester.pumpAndSettle();
      final second = close();
      await tester.pumpAndSettle();

      expect(find.text('Cloud sync pending'), findsOneWidget);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(await first, isA<Stay>());
      expect(await second, isA<Stay>());
    });

    testWidgets(
        'a Retry sync that throws keeps every close in the editor and reports '
        'the error once', (tester) async {
      await startWithCloudWorkNotKept(tester,
          retryError: StateError('the outbox could not be written'));
      final first = close();
      await tester.pumpAndSettle();
      final second = close();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Retry sync'));
      await tester.pumpAndSettle();
      expect(await first, isA<Stay>());
      expect(await second, isA<Stay>());
      expect(
        appProviderContainer
            .read(inAppDebugProvider)
            .where((log) =>
                log.message == 'Failed to save strategy before leaving.')
            .length,
        1,
      );
    });

    for (final takesOver in ['strategy-b', 'cloud-strategy']) {
      testWidgets(
          takesOver == 'cloud-strategy'
              ? "the cloud prompt goes when a local copy with the cloud "
                  "strategy's id takes over, and a close on that copy gets "
                  'its own prompt'
              : 'the cloud prompt goes when another strategy takes over, and '
                  'a close on that strategy gets its own prompt',
          (tester) async {
        await startWithCloudWorkNotKept(tester, autosaves: false);
        LeaveAnswer? aboutA;
        unawaited(close().then((answer) => aboutA = answer));
        await tester.pumpAndSettle();
        expect(find.text('Cloud sync pending'), findsOneWidget);

        notifier.setFromState(StrategyState(
          strategyId: takesOver,
          strategyName: 'Taken over',
          source: StrategySource.local,
          isOpen: true,
        ));
        container.read(strategySaveStateProvider.notifier).markDirty();
        await tester.pumpAndSettle();
        expect(aboutA, isA<Superseded>());
        expect(find.text('Cloud sync pending'), findsNothing);

        final aboutB = close();
        await tester.pumpAndSettle();
        expect(find.text('Save changes?'), findsOneWidget);
        expect(find.text('Cloud sync pending'), findsNothing);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await aboutB, isA<Stay>());
      });
    }

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

      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-cloud-nondurable',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsNothing);
      expect(find.text('Stay here'), findsOneWidget);
      await tester.tap(find.text('Stay here'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isFalse);
    });

    for (final failedStore in ['ops', 'media']) {
      testWidgets('unreadable records cannot hide a $failedStore write failure',
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
        container = ProviderContainer(overrides: [
          strategyProvider.overrideWith(() => notifier),
          strategyOpQueueProvider.overrideWith(() => _GuardOpQueue(
                StrategyOpQueueState(
                  accountId: 'account-a',
                  strategyPublicId: 'cloud-strategy',
                  clientId: 'guard-client',
                  durableLoaded: true,
                  queuedByEntityKey: {_guardEntityKey: _guardPendingIntent},
                  hasDurabilityFailure: failedStore == 'ops',
                ),
              )),
          cloudMediaUploadQueueProvider.overrideWith(() => _GuardMediaQueue(
                CloudMediaUploadQueueState(
                  jobs: const [],
                  isProcessing: false,
                  durabilityError:
                      failedStore == 'media' ? 'Disk write failed.' : null,
                  loadIssues: const [
                    DurableCloudMediaOutboxLoadIssue(
                      storageKey: 'old-unreadable',
                      error: 'bad record',
                    )
                  ],
                ),
              )),
          authProvider.overrideWith(_GuardAuthProvider.new),
          convexConnectionSnapshotProvider.overrideWithValue(false),
        ]);
        addTearDown(container.dispose);
        await pumpHarness(tester);
        var continued = false;
        final guarded = guardThenIgnoringWhatItSaw(
          context: context,
          ref: ref,
          source: 'mixed-durability-test',
          onContinue: () async {
            continued = true;
          },
        );
        await tester.pumpAndSettle();
        expect(find.text('Leave anyway'), findsNothing);
        await tester.tap(find.text('Stay here'));
        await tester.pumpAndSettle();
        expect(await guarded, isFalse);
        expect(continued, isFalse);
      });
    }

    testWidgets('an unreliable media outbox can leave without deleting work',
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
              jobId: 'image-a',
              accountId: 'account-a',
              strategyPublicId: 'cloud-strategy',
              assetPublicId: 'image-a',
              fileExtension: '.png',
              mimeType: 'image/png',
              updatedAt: DateTime.utc(2026, 9, 3),
            ),
          ],
          isProcessing: false,
          loadIssues: const [
            DurableCloudMediaOutboxLoadIssue(
              storageKey: 'account-a|unreadable-image',
              error: 'bad record',
            ),
          ],
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

      var continueCalls = 0;
      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-unreliable-media',
        onContinue: () async {
          continueCalls += 1;
        },
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsOneWidget);
      expect(find.textContaining('will not delete'), findsOneWidget);
      await tester.tap(find.text('Leave anyway'));
      await tester.pumpAndSettle();
      expect(await guardFuture, isTrue);
      expect(continueCalls, 1);
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
              referenceDurable: false,
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

      final guardFuture = guardThenIgnoringWhatItSaw(
        context: context,
        ref: ref,
        source: 'guard-test-staged-media',
        onContinue: () async {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Leave anyway'), findsNothing);
      await tester.tap(find.text('Stay here'));
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
      final result = await guardThenIgnoringWhatItSaw(
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
      final guardFuture = guardThenIgnoringWhatItSaw(
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

  group('exits asked for while the save prompt is up share its answer', () {
    late ProviderContainer container;
    late _JoinedStrategies strategies;
    late BuildContext context;
    late WidgetRef ref;

    Future<void> start(
      WidgetTester tester, {
      bool autosaveOn = false,
      bool autosaveFails = false,
      Object? saveError,
    }) async {
      strategies = _JoinedStrategies(
        autosaveOn: autosaveOn,
        saveError: saveError,
        autosaveFails: autosaveFails,
      );
      container = ProviderContainer(
        overrides: [strategyProvider.overrideWith(() => strategies)],
      );
      addTearDown(container.dispose);
      container.read(strategySaveStateProvider.notifier).markDirty();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ToastificationWrapper(
            child: ShadApp(
              navigatorKey: appNavigatorKey,
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
        ),
      );
      await tester.pump();
      appProviderContainer.read(inAppDebugProvider.notifier).clearLogs();
    }

    Future<LeaveAnswer> ask({bool closes = false}) => guardUnsavedStrategyExit(
          context: context,
          ref: ref,
          source: 'joined-exit-test',
          closesWindow: closes,
        );

    Future<List<LeaveAnswer>> answer(
      WidgetTester tester,
      String choice,
      List<Future<LeaveAnswer>> asked,
    ) async {
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text(choice));
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsNothing);
      return Future.wait(asked);
    }

    testWidgets('two closes ask once, and Cancel keeps the editor for both',
        (tester) async {
      await start(tester);
      final first = ask(closes: true);
      await tester.pumpAndSettle();
      final second = ask(closes: true);

      final answers = await answer(tester, 'Cancel', [first, second]);

      expect(answers, everyElement(isA<Stay>()));
      expect(strategies.cancelled, 0);
    });

    testWidgets('two closes answered Don\'t save close the window once',
        (tester) async {
      await start(tester);
      final first = ask(closes: true);
      await tester.pumpAndSettle();
      final second = ask(closes: true);

      final answers = await answer(tester, "Don't save", [first, second]);

      expect(answers.whereType<Leave>(), hasLength(1));
      expect(answers.last, isA<Leave>());
    });

    testWidgets('a close then a link: Save saves once and only the close goes',
        (tester) async {
      await start(tester);
      final close = ask(closes: true);
      await tester.pumpAndSettle();
      final link = ask();

      final answers = await answer(tester, 'Save', [close, link]);

      expect(answers.first, isA<Leave>());
      expect(answers.last, isA<Stay>());
      expect(strategies.saves, 1);
    });

    testWidgets('a link then a close: the close goes, whatever the order',
        (tester) async {
      await start(tester);
      final link = ask();
      await tester.pumpAndSettle();
      final close = ask(closes: true);

      final answers = await answer(tester, "Don't save", [link, close]);

      expect(answers.first, isA<Stay>());
      expect(answers.last, isA<Leave>());
    });

    testWidgets(
        'Home then a link to another strategy: Don\'t save lets the last '
        'request go, and only that one', (tester) async {
      await start(tester);
      final home = ask();
      await tester.pumpAndSettle();
      final link = ask();

      final answers = await answer(tester, "Don't save", [home, link]);

      expect(answers.first, isA<Stay>());
      expect(answers.last, isA<Leave>());
      expect(strategies.cancelled, 0);
    });

    testWidgets(
        'a close asked for while the Save writes joins it, and an edit made '
        'meanwhile is saved by another write before the close goes',
        (tester) async {
      await start(tester);
      final held = strategies.heldSave = Completer<void>();
      final home = ask();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pump();
      container.read(strategySaveStateProvider.notifier).markDirty();
      final close = ask(closes: true);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Save changes?'), findsNothing);

      held.complete();
      await tester.pumpAndSettle();

      expect(await home, isA<Stay>());
      expect(await close, isA<Leave>());
      expect(strategies.saves, 2);
      expect(container.read(strategySaveStateProvider).isDirty, isFalse);
    });

    testWidgets(
        'a close asked for while the Save of another strategy writes is a '
        'question of its own, about the strategy open now', (tester) async {
      await start(tester);
      final held = strategies.heldSave = Completer<void>();
      final home = ask();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pump();
      strategies.setFromState(const StrategyState(
        strategyId: 'strategy-b',
        strategyName: 'Strategy B',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      ));
      container.read(strategySaveStateProvider.notifier).markDirty();
      final close = ask(closes: true);
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await close, isA<Stay>());
      held.complete();
      await tester.pumpAndSettle();
      expect(await home, isA<Leave>());
    });

    testWidgets(
        'every exit waiting on a question stays once no editor is left on '
        'screen to answer it', (tester) async {
      await start(tester);
      final home = ask();
      await tester.pumpAndSettle();
      final close = ask(closes: true);
      expect(find.text('Save changes?'), findsOneWidget);

      StrategyView.onScreen.value = 0;
      await tester.pumpAndSettle();

      expect(await home, isA<Superseded>());
      expect(await close, isA<Superseded>());
      expect(find.text('Save changes?'), findsNothing);
    });

    testWidgets(
        'an autosave that fails after another strategy took over shows no '
        'prompt for the strategy it was about, and a close on the new one '
        'gets its own', (tester) async {
      await start(tester, autosaveOn: true, autosaveFails: true);
      final home = ask();
      await tester.pump();
      strategies.setFromState(const StrategyState(
        strategyId: 'strategy-b',
        strategyName: 'Strategy B',
        source: StrategySource.local,
        storageDirectory: null,
        isOpen: true,
      ));
      container.read(strategySaveStateProvider.notifier).markDirty();
      strategies.finishTheAutosave();
      await tester.pumpAndSettle();

      expect(await home, isA<Superseded>());
      expect(find.text('Save changes?'), findsNothing);
      final close = ask(closes: true);
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await close, isA<Stay>());
    });

    testWidgets(
        'an editor claiming the open while the prompt is up ends the question, '
        'and a close after it is the only question', (tester) async {
      await start(tester);
      LeaveAnswer? home;
      unawaited(ask().then((answer) => home = answer));
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);

      expect(strategies.claimForAnEditor(strategies.askedByTheUserNow()),
          isNotNull);
      await tester.pumpAndSettle();
      expect(home, isA<Superseded>());
      expect(find.text('Save changes?'), findsNothing);

      final close = ask(closes: true);
      await tester.pumpAndSettle();
      expect(find.text('Save changes?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await close, isA<Stay>());
    });

    testWidgets(
        'a prompt whose strategy stops being the open one before its first '
        'frame is never drawn', (tester) async {
      await start(tester);
      LeaveAnswer? home;
      unawaited(ask().then((answer) => home = answer));
      for (var turn = 0; turn < 20; turn++) {
        await Future<void>.value();
      }
      expect(strategies.claimForAnEditor(strategies.askedByTheUserNow()),
          isNotNull);
      await tester.pump();

      expect(find.text('Save changes?'), findsNothing);
      expect(appNavigatorKey.currentState!.canPop(), isFalse);
      await tester.pumpAndSettle();
      expect(home, isA<Superseded>());
    });

    bool questionListens() =>
        container.getAllProviderElements().any((element) =>
            (element.origin == strategyProvider ||
                element.origin == openCountProvider) &&
            element.hasListeners) ||
        (StrategyView.onScreen as dynamic).hasListeners as bool;

    final waysOut = <String, Future<void> Function(WidgetTester tester)>{
      'answered': (tester) async {
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      },
      'superseded': (tester) async {
        expect(strategies.claimForAnEditor(strategies.askedByTheUserNow()),
            isNotNull);
        await tester.pumpAndSettle();
      },
      'dismissed from outside': (tester) async {
        appNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
      },
      'left by the last editor': (tester) async {
        StrategyView.onScreen.value = 0;
        await tester.pumpAndSettle();
      },
    };
    for (final MapEntry(key: wayOut, value: leave) in waysOut.entries) {
      testWidgets(
          'a question listens to what is open only while it asks, and stops '
          'once it is $wayOut', (tester) async {
        await start(tester);
        expect(questionListens(), isFalse);
        unawaited(ask());
        await tester.pumpAndSettle();
        expect(find.text('Save changes?'), findsOneWidget);
        expect(questionListens(), isTrue);

        await leave(tester);

        expect(find.text('Save changes?'), findsNothing);
        expect(questionListens(), isFalse);
      });
    }

    testWidgets(
        'a Save pressed in the same step another open is counted, before the '
        "question has heard of it, saves nothing", (tester) async {
      await start(tester);
      void Function()? pressSave;
      final pressing = container.listen(openCountProvider, (_, __) {
        pressSave?.call();
      });
      addTearDown(pressing.close);
      LeaveAnswer? home;
      unawaited(ask().then((answer) => home = answer));
      await tester.pumpAndSettle();
      pressSave = tester
          .widget<ShadButton>(find.widgetWithText(ShadButton, 'Save'))
          .onPressed;

      expect(strategies.claimForAnEditor(strategies.askedByTheUserNow()),
          isNotNull);
      await tester.pumpAndSettle();

      expect(strategies.saves, 0);
      expect(home, isA<Superseded>());
      expect(find.text('Save changes?'), findsNothing);
    });

    testWidgets(
        'an autosave that fails after the last editor left asks nothing over '
        'the library, and everyone stays', (tester) async {
      await start(tester, autosaveOn: true, autosaveFails: true);
      final home = ask();
      await tester.pump();
      StrategyView.onScreen.value = 0;
      strategies.finishTheAutosave();
      await tester.pumpAndSettle();

      expect(find.text('Save changes?'), findsNothing);
      expect(await home, isA<Superseded>());
    });

    testWidgets('Home then a link answered Cancel: neither goes',
        (tester) async {
      await start(tester);
      final home = ask();
      await tester.pumpAndSettle();
      final link = ask();

      final answers = await answer(tester, 'Cancel', [home, link]);

      expect(answers, everyElement(isA<Stay>()));
    });

    testWidgets(
        'a Save that fails is a Cancel for every request: the error is shown '
        'and the editor keeps the strategy and its work', (tester) async {
      await start(tester, saveError: StateError('the disk is full'));
      final home = ask();
      await tester.pumpAndSettle();
      final link = ask();

      final answers = await answer(tester, 'Save', [home, link]);

      expect(answers, everyElement(isA<Stay>()));
      expect(container.read(strategyProvider).strategyId, 'strategy-a');
      expect(container.read(strategySaveStateProvider).isDirty, isTrue);
      expect(
        appProviderContainer.read(inAppDebugProvider).last.message,
        'Failed to save strategy before leaving.',
      );
      expect(find.text('Failed to save strategy before leaving.'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets(
        'with autosave on, a link that comes while the save runs joins it: '
        'no prompt, one save, and the link goes', (tester) async {
      await start(tester, autosaveOn: true);
      final home = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'joined-exit-test',
      );
      final link = guardUnsavedStrategyExit(
        context: context,
        ref: ref,
        source: 'joined-exit-test',
      );
      await tester.pump();
      expect(find.text('Save changes?'), findsNothing);
      strategies.finishTheAutosave();
      await tester.pumpAndSettle();

      expect(await home, isA<Stay>());
      expect(await link, isA<Leave>());
      expect(strategies.flushes, 1);
      expect(find.text('Save changes?'), findsNothing);
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
