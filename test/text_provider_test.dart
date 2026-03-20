import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registration.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/folder_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_draft_provider.dart';
import 'package:icarus/providers/text_provider.dart';

class _NoopActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    state = [...state, action];
  }
}

class _TrackingActionProvider extends ActionProvider {
  _TrackingActionProvider(this.recordedActions);

  final List<UserAction> recordedActions;

  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    recordedActions.add(action);
    state = [...state, action];
  }

  @override
  void resetActionState() {
    poppedItems = [];
    state = [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  const abilityInfoAdapterTypeId = 9;

  ProviderContainer createContainer({
    ActionProvider Function()? actionProviderFactory,
  }) {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(
          actionProviderFactory ?? _NoopActionProvider.new,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<Box<StrategyData>> openStrategyTestBoxes(String prefix) async {
    final tempDir = await Directory.systemTemp.createTemp(prefix);
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(abilityInfoAdapterTypeId)) {
      registerIcarusAdapters(Hive);
    }
    final strategyBox =
        await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    await Hive.openBox<Folder>(HiveBoxNames.foldersBox);
    await Hive.openBox<MapThemeProfile>(HiveBoxNames.mapThemeProfilesBox);
    await Hive.openBox<AppPreferences>(HiveBoxNames.appPreferencesBox);
    await Hive.openBox<bool>(HiveBoxNames.favoriteAgentsBox);
    addTearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });
    return strategyBox;
  }

  test('commitText updates committed text and records one edit action', () {
    final container = createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'before',
    ]);

    notifier.commitText('text-1', 'after');

    final texts = container.read(textProvider);
    expect(texts.single.text, 'after');
    expect(container.read(actionProvider), hasLength(1));
    expect(container.read(actionProvider).single.type, ActionType.edit);
    expect(container.read(actionProvider).single.group, ActionGroup.text);
  });

  test('commitText is a no-op when the committed text is unchanged', () {
    final container = createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'same',
    ]);

    notifier.commitText('text-1', 'same');

    expect(container.read(textProvider).single.text, 'same');
    expect(container.read(actionProvider), isEmpty);
  });

  test('undo and redo restore committed text edits', () {
    final container = createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'before',
    ]);

    notifier.commitText('text-1', 'after');
    final action = container.read(actionProvider).single;

    notifier.undoAction(action);
    expect(container.read(textProvider).single.text, 'before');

    notifier.redoAction(action);
    expect(container.read(textProvider).single.text, 'after');
  });

  test('removeText preserves the latest visible draft for undo-delete', () {
    final container = createContainer();
    final notifier = container.read(textProvider.notifier);

    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      )..text = 'before',
    ]);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'draft value');
    notifier.removeText('text-1');

    expect(container.read(textProvider), isEmpty);
    notifier.undoAction(
      UserAction(
        type: ActionType.deletion,
        id: 'text-1',
        group: ActionGroup.text,
      ),
    );

    expect(container.read(textProvider).single.text, 'draft value');
  });

  test('fromHive and clearAll clear transient drafts', () {
    final container = createContainer();
    final notifier = container.read(textProvider.notifier);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'draft value');
    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      ),
    ]);

    expect(container.read(textDraftProvider), isEmpty);

    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'draft value');
    notifier.clearAll();

    expect(container.read(textDraftProvider), isEmpty);
    expect(container.read(textProvider), isEmpty);
  });

  test('saveToHive persists draft text without mutating live text state',
      () async {
    final box = await openStrategyTestBoxes('icarus-text-save-');

    final page = StrategyPage(
      id: 'page-1',
      name: 'Page 1',
      drawingData: const [],
      agentData: const [],
      abilityData: const [],
      textData: [
        PlacedText(id: 'text-1', position: const Offset(10, 20))
          ..text = 'before',
      ],
      imageData: const [],
      utilityData: const [],
      sortIndex: 0,
      isAttack: true,
      settings: StrategySettings(),
    );
    final strategy = StrategyData(
      id: 'strategy-1',
      name: 'Strategy 1',
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime(2024),
      folderID: null,
      pages: [page],
    );
    await box.put(strategy.id, strategy);

    final container = createContainer();
    container.read(textProvider.notifier).fromHive(page.textData);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'saved draft');

    final strategyNotifier = container.read(strategyProvider.notifier);
    strategyNotifier
      ..setFromState(
        StrategyState(
          isSaved: false,
          stratName: strategy.name,
          id: strategy.id,
          storageDirectory: null,
          activePageId: page.id,
        ),
      )
      ..activePageID = page.id;

    await strategyNotifier.saveToHive(strategy.id);

    final savedStrategy = box.get(strategy.id);
    expect(savedStrategy, isNotNull);
    expect(savedStrategy!.pages.single.textData.single.text, 'saved draft');
    expect(container.read(textProvider).single.text, 'before');
    expect(container.read(textDraftProvider), {'text-1': 'saved draft'});
    expect(container.read(actionProvider), isEmpty);
  });

  test(
      'setActivePage persists outgoing drafts without creating text edit actions',
      () async {
    final box = await openStrategyTestBoxes('icarus-text-page-switch-');
    final pageOne = StrategyPage(
      id: 'page-1',
      name: 'Page 1',
      drawingData: const [],
      agentData: const [],
      abilityData: const [],
      textData: [
        PlacedText(id: 'text-1', position: const Offset(10, 20))
          ..text = 'before',
      ],
      imageData: const [],
      utilityData: const [],
      sortIndex: 0,
      isAttack: true,
      settings: StrategySettings(),
    );
    final pageTwo = StrategyPage(
      id: 'page-2',
      name: 'Page 2',
      drawingData: const [],
      agentData: const [],
      abilityData: const [],
      textData: [
        PlacedText(id: 'text-2', position: const Offset(30, 40))
          ..text = 'page two',
      ],
      imageData: const [],
      utilityData: const [],
      sortIndex: 1,
      isAttack: true,
      settings: StrategySettings(),
    );
    final strategy = StrategyData(
      id: 'strategy-1',
      name: 'Strategy 1',
      mapData: MapValue.ascent,
      versionNumber: 1,
      lastEdited: DateTime(2024),
      folderID: null,
      pages: [pageOne, pageTwo],
    );
    await box.put(strategy.id, strategy);

    final recordedActions = <UserAction>[];
    final container = createContainer(
      actionProviderFactory: () => _TrackingActionProvider(recordedActions),
    );
    container.read(textProvider.notifier).fromHive(pageOne.textData);
    container
        .read(textDraftProvider.notifier)
        .setDraft('text-1', 'draft leaving page');

    final strategyNotifier = container.read(strategyProvider.notifier);
    strategyNotifier
      ..setFromState(
        StrategyState(
          isSaved: false,
          stratName: strategy.name,
          id: strategy.id,
          storageDirectory: null,
          activePageId: pageOne.id,
        ),
      )
      ..activePageID = pageOne.id;

    await strategyNotifier.setActivePage(pageTwo.id);

    final savedStrategy = box.get(strategy.id);
    expect(savedStrategy, isNotNull);
    expect(
        savedStrategy!.pages.first.textData.single.text, 'draft leaving page');
    expect(container.read(textProvider).single.id, 'text-2');
    expect(container.read(textProvider).single.text, 'page two');
    expect(
      recordedActions.where(
        (action) =>
            action.group == ActionGroup.text && action.type == ActionType.edit,
      ),
      isEmpty,
    );
  });
}
