import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/in_app_debug_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
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
    state = state.copyWith(isSaved: true);
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
      notifier
        ..setFromState(
          StrategyState(
            isSaved: false,
            stratName: strategy.name,
            id: strategy.id,
            storageDirectory: null,
            activePageId: strategy.pages.single.id,
          ),
        )
        ..activePageID = strategy.pages.single.id;

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isTrue);
      expect(container.read(strategyProvider).isSaved, isTrue);
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
      notifier
        ..setFromState(
          StrategyState(
            isSaved: false,
            stratName: strategy.name,
            id: strategy.id,
            storageDirectory: null,
            activePageId: strategy.pages.single.id,
          ),
        )
        ..activePageID = strategy.pages.single.id;

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isFalse);
      expect(container.read(strategyProvider).isSaved, isFalse);
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'before');
    });

    test('already saved returns true without another save', () async {
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
          .setDraft('text-1', 'draft should not save');

      final notifier = container.read(strategyProvider.notifier);
      notifier
        ..setFromState(
          StrategyState(
            isSaved: true,
            stratName: strategy.name,
            id: strategy.id,
            storageDirectory: null,
            activePageId: strategy.pages.single.id,
          ),
        )
        ..activePageID = strategy.pages.single.id;

      final result = await notifier.flushPendingAutosaveBeforeExit();

      expect(result, isTrue);
      final saved =
          Hive.box<StrategyData>(HiveBoxNames.strategiesBox).get(strategy.id);
      expect(saved, isNotNull);
      expect(saved!.pages.single.textData.single.text, 'before');
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
              StrategyState(
                isSaved: false,
                stratName: 'Strategy 4',
                id: 'strategy-4',
                storageDirectory: null,
                activePageId: 'page-1',
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

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
        initialState: StrategyState(
          isSaved: false,
          stratName: 'Strategy A',
          id: 'strategy-a',
          storageDirectory: null,
          activePageId: 'page-1',
        ),
        flushResult: true,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
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

    testWidgets(
        'dirty autosave-disabled exit shows dialog and save still works',
        (tester) async {
      notifier = _FakeGuardStrategyProvider(
        initialState: StrategyState(
          isSaved: false,
          stratName: 'Strategy B',
          id: 'strategy-b',
          storageDirectory: null,
          activePageId: 'page-1',
        ),
        flushResult: false,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
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
        initialState: StrategyState(
          isSaved: false,
          stratName: 'Strategy C',
          id: 'strategy-c',
          storageDirectory: null,
          activePageId: 'page-1',
        ),
        flushResult: false,
      );
      container = ProviderContainer(
        overrides: [
          strategyProvider.overrideWith(() => notifier),
        ],
      );
      addTearDown(container.dispose);
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
        initialState: StrategyState(
          isSaved: false,
          stratName: 'Strategy D',
          id: 'strategy-d',
          storageDirectory: null,
          activePageId: 'page-1',
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
