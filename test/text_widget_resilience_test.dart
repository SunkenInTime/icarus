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
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/widgets/draggable_widgets/text/placed_text_builder.dart';
import 'package:icarus/widgets/draggable_widgets/text/text_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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
  CoordinateSystem(playAreaSize: const Size(1920, 1080));
  const abilityInfoAdapterTypeId = 9;

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        actionProvider.overrideWith(_NoopActionProvider.new),
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

  Widget buildTextHarness(ProviderContainer container, {String marker = 'a'}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text(marker),
              Consumer(
                builder: (context, ref, _) {
                  final placedText = ref.watch(textProvider).first;
                  return TextWidget(
                    id: placedText.id,
                    text: placedText.text,
                    size: placedText.size,
                    fontSize: placedText.fontSize,
                    tagColorValue: placedText.tagColorValue,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildPlacedTextHarness(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final placedText = ref.watch(textProvider).first;
              return Stack(
                children: [
                  Positioned(
                    left: 20,
                    top: 20,
                    child: PlacedTextBuilder(
                      size: placedText.size,
                      placedText: placedText,
                      onDragEnd: (_) {},
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget buildFeedbackParityHarness() {
    return const ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextWidget(
                id: 'editable',
                text: 'same text\nsecond line',
                size: 220,
                fontSize: 16,
                isFeedback: false,
              ),
              SizedBox(height: 16),
              TextWidget(
                id: 'feedback',
                text: 'same text\nsecond line',
                size: 220,
                fontSize: 16,
                isFeedback: true,
              ),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('draft text commits when the widget is torn down',
      (tester) async {
    final container = createContainer();
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'before',
    ]);

    await tester.pumpWidget(buildTextHarness(container));
    await tester.enterText(find.byType(TextField), 'edited');
    await tester.pump();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(container.read(textProvider).single.text, 'edited');
  });

  testWidgets(
      'drag start commits the draft before the drag lifecycle swaps children',
      (tester) async {
    final container = createContainer();
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'before',
    ]);

    await tester.pumpWidget(buildPlacedTextHarness(container));
    await tester.enterText(find.byType(TextField), 'edited during drag');
    await tester.pump();

    final draggable = tester.widget<Draggable<PlacedText>>(
      find.byType(Draggable<PlacedText>),
    );
    draggable.onDragStarted?.call();
    await tester.pump();

    expect(container.read(textProvider).single.text, 'edited during drag');
  });

  testWidgets('commitAllDrafts flushes the latest focused draft without blur',
      (tester) async {
    final container = createContainer();
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'before',
    ]);

    await tester.pumpWidget(buildTextHarness(container));
    await tester.enterText(find.byType(TextField), 'saved draft');
    await tester.pump();

    container.read(textDraftProvider.notifier).commitAllDrafts();
    await tester.pump();

    expect(container.read(textProvider).single.text, 'saved draft');
  });

  testWidgets('focused text survives unrelated parent rebuilds',
      (tester) async {
    final container = createContainer();
    container.read(textProvider.notifier).fromHive([
      PlacedText(id: 'text-1', position: const Offset(10, 20))..text = 'before',
    ]);

    await tester.pumpWidget(buildTextHarness(container, marker: 'a'));
    await tester.enterText(find.byType(TextField), 'draft survives rebuild');
    await tester.pump();

    await tester.pumpWidget(buildTextHarness(container, marker: 'b'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'draft survives rebuild');
    expect(container.read(textProvider).single.text, 'before');
  });

  testWidgets('autosave persists drafts without moving the focused selection',
      (tester) async {
    final box = (await tester.runAsync(
      () => openStrategyTestBoxes('icarus-text-widget-save-'),
    ))!;
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
    await tester.runAsync(() async {
      await box.put(strategy.id, strategy);
    });

    final container = createContainer();
    container.read(textProvider.notifier).fromHive(page.textData);

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

    await tester.pumpWidget(buildTextHarness(container));
    await tester.enterText(find.byType(TextField), 'before edited');
    await tester.pump();

    final fieldBeforeSave = tester.widget<TextField>(find.byType(TextField));
    fieldBeforeSave.controller!.selection =
        const TextSelection.collapsed(offset: 3);
    await tester.pump();

    await tester.runAsync(() async {
      await strategyNotifier.saveToHive(strategy.id);
    });
    await tester.pump();

    final fieldAfterSave = tester.widget<TextField>(find.byType(TextField));
    final savedStrategy = box.get(strategy.id);

    expect(fieldAfterSave.controller!.text, 'before edited');
    expect(fieldAfterSave.controller!.selection,
        const TextSelection.collapsed(offset: 3));
    expect(container.read(textProvider).single.text, 'before');
    expect(container.read(textDraftProvider), {'text-1': 'before edited'});
    expect(savedStrategy, isNotNull);
    expect(savedStrategy!.pages.single.textData.single.text, 'before edited');
  });

  testWidgets('feedback widget matches editable widget size', (tester) async {
    await tester.pumpWidget(buildFeedbackParityHarness());
    await tester.pump();

    final editableSize = tester.getSize(find.byType(TextWidget).first);
    final feedbackSize = tester.getSize(find.byType(TextWidget).last);

    expect(feedbackSize.width, editableSize.width);
    expect(feedbackSize.height, editableSize.height);
  });
}
