import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/hive/hive_registrar.g.dart';
import 'package:icarus/providers/action_provider.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(_NoopActionProvider.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
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

    container.read(textDraftProvider.notifier).setDraft('text-1', 'draft value');
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

    container.read(textDraftProvider.notifier).setDraft('text-1', 'draft value');
    notifier.fromHive([
      PlacedText(
        id: 'text-1',
        position: const Offset(10, 20),
      ),
    ]);

    expect(container.read(textDraftProvider), isEmpty);

    container.read(textDraftProvider.notifier).setDraft('text-1', 'draft value');
    notifier.clearAll();

    expect(container.read(textDraftProvider), isEmpty);
    expect(container.read(textProvider), isEmpty);
  });

  test('saveToHive flushes draft text into persisted page data', () async {
    final tempDir = await Directory.systemTemp.createTemp('icarus-text-save-');
    Hive.init(tempDir.path);
    Hive.registerAdapters();
    final box = await Hive.openBox<StrategyData>(HiveBoxNames.strategiesBox);
    addTearDown(() async {
      await Hive.close();
      await tempDir.delete(recursive: true);
    });

    final page = StrategyPage(
      id: 'page-1',
      name: 'Page 1',
      drawingData: const [],
      agentData: const [],
      abilityData: const [],
      textData: [
        PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'before',
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
    container.read(textDraftProvider.notifier).setDraft('text-1', 'saved draft');

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
  });
}
