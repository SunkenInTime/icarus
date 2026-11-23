import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:icarus/const/app_provider_container.dart';
import 'package:icarus/const/hive_boxes.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/strategy/local_library.dart';
import 'package:icarus/strategy/strategy_migrator.dart';
import 'package:icarus/providers/strategy_page.dart';
import 'package:icarus/strategy/strategy_models.dart';

import 'library_rows/generated_strategies.dart';
import 'library_store/unit_harness.dart';

final class _SignedOut extends AuthProvider {
  @override
  AppAuthState build() => AppAuthState.fromSession(null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  setUpAll(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_SignedOut.new)],
    );
    appProviderContainer = container;
  });
  setUp(() async => openUnitHive());
  tearDown(() async => Hive.close());

  var opened = 0;
  Future<String> open() async {
    opened += 1;
    final id = 'without-undo-$opened';
    final strategy = StrategyMigrator.migrateToCurrentVersion(
      generatedStrategy(Optionals.unset).copyWith(
        id: id,
        mapData: MapValue.ascent,
        pages: [
          for (var n = 0; n < 2; n++)
            generatedPage(
              id: '$id-p$n',
              sortIndex: n,
              optionals: Optionals.set,
              isAttack: true,
            ).copyWith(),
        ],
      ),
    );
    await Hive.box<StrategyData>(HiveBoxNames.strategiesBox)
        .put(strategy.id, strategy);
    expect(
      await container.read(strategyProvider.notifier).loadFromHive(id),
      isTrue,
    );
    return id;
  }

  ActionProvider actions() => container.read(actionProvider.notifier);
  int history() => container.read(actionProvider).length;
  StrategyData stored(String id) => const LocalLibrary().storedStrategy(id)!;
  StrategyPage storedPage(String id) => stored(id).pages.singleWhere((page) =>
      page.id == container.read(strategyPageSessionProvider).activePageId);
  Future<void> save(String id) =>
      container.read(strategyProvider.notifier).forceSaveNow(id);

  Future<void> earlierCaption() async {
    final agent = container.read(agentProvider).first.id;
    container.read(agentProvider.notifier).setCaption(agent, 'Earlier edit');
  }

  void expectEarlierCaptionUndone() => expect(
      container.read(agentProvider).first.caption, isNot('Earlier edit'));

  group('edits that are not undo steps', () {
    test(
        'a text\'s tag colour changes the canvas and is saved, adds no undo '
        'step, and an undo after it undoes the edit before it', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final text = container.read(textProvider).first.id;
      container.read(textProvider.notifier).updateTagColor(text, 0xFF22C55E);

      expect(history(), steps);
      expect(container.read(textProvider).first.tagColorValue, 0xFF22C55E);
      await save(id);
      expect(storedPage(id).textData.first.tagColorValue, 0xFF22C55E);
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(textProvider).first.tagColorValue, 0xFF22C55E);
    });

    test(
        'an image\'s tag colour changes the canvas and is saved, adds no undo '
        'step, and an undo after it undoes the edit before it', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final image = container.read(placedImageProvider).images.first.id;
      container
          .read(placedImageProvider.notifier)
          .updateTagColor(image, 0xFF22C55E);

      expect(history(), steps);
      await save(id);
      expect(storedPage(id).imageData.first.tagColorValue, 0xFF22C55E);
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(placedImageProvider).images.first.tagColorValue,
          0xFF22C55E);
    });

    test(
        'resizing a text changes its size and position and is saved, adds no '
        'undo step, and an undo after it undoes the edit before it', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final text = container.read(textProvider).first.id;
      container
          .read(textProvider.notifier)
          .resize(text, size: 300, position: const Offset(250, 150));

      expect(history(), steps);
      await save(id);
      expect(storedPage(id).textData.first.size, 300);
      expect(storedPage(id).textData.first.position, const Offset(250, 150));
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(textProvider).first.size, 300);
    });

    test(
        'resizing an image changes its scale and position and is saved, adds '
        'no undo step, and an undo after it undoes the edit before it',
        () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final image = container.read(placedImageProvider).images.first;
      container.read(placedImageProvider.notifier).resize(image.id,
          scale: image.scale * 1.5, position: const Offset(330, 270));
      final scale = container.read(placedImageProvider).images.first.scale;

      expect(history(), steps);
      await save(id);
      expect(storedPage(id).imageData.first.scale, scale);
      expect(storedPage(id).imageData.first.position, const Offset(330, 270));
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(placedImageProvider).images.first.scale, scale);
    });

    test(
        'switching the side of the page on screen is saved, adds no undo '
        'step, and leaves the other page alone', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final before = container.read(mapProvider).isAttack;
      await container
          .read(strategyProvider.notifier)
          .switchSide(allPages: false);

      expect(history(), steps);
      expect(container.read(mapProvider).isAttack, !before);
      await save(id);
      expect(storedPage(id).isAttack, !before);
      expect(
        stored(id)
            .pages
            .where((page) => page.id != storedPage(id).id)
            .single
            .isAttack,
        before,
      );
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(mapProvider).isAttack, !before);
    });

    test(
        'the neutral colours of the page on screen are saved and add no undo '
        'step', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final before =
          container.read(strategySettingsProvider).useNeutralTeamColors;
      container
          .read(strategySettingsProvider.notifier)
          .updateNeutralTeamColors(!before);

      expect(history(), steps);
      await save(id);
      expect(storedPage(id).settings.useNeutralTeamColors, !before);
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(strategySettingsProvider).useNeutralTeamColors,
          !before);
    });

    test('changing the map is saved and adds no undo step', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      container.read(mapProvider.notifier).updateMap(MapValue.bind);

      expect(history(), steps);
      await save(id);
      expect(stored(id).mapData, MapValue.bind);
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(container.read(mapProvider).currentMap, MapValue.bind);
    });

    test(
        'choosing a theme profile, setting an override (which drops the '
        'profile) and clearing it are saved and add no undo step', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      final strategies = container.read(strategyProvider.notifier);
      strategies.setThemeProfileForCurrentStrategy(
          MapThemeProfilesProvider.immutableValorantProfileId);
      await save(id);
      expect(stored(id).themeProfileId,
          MapThemeProfilesProvider.immutableValorantProfileId);

      final palette = MapThemePalette(
        baseColorValue: 0xFF101010,
        detailColorValue: 0xFF202020,
        highlightColorValue: 0xFF303030,
      );
      strategies.setThemeOverrideForCurrentStrategy(palette);
      await save(id);
      expect(stored(id).themeOverridePalette?.baseColorValue, 0xFF101010);
      expect(stored(id).themeProfileId, isNull);

      strategies.clearThemeOverrideForCurrentStrategy();
      await save(id);
      expect(stored(id).themeOverridePalette, isNull);

      expect(history(), steps);
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(stored(id).themeProfileId, isNull);
      expect(stored(id).themeOverridePalette, isNull);
    });

    test(
        'renaming the open strategy writes the new name to Hive at once and '
        'adds no undo step', () async {
      final id = await open();
      await earlierCaption();
      final steps = history();
      await container
          .read(strategyProvider.notifier)
          .renameStrategy(id, 'Renamed in the title');

      expect(history(), steps);
      expect(stored(id).name, 'Renamed in the title');
      expect(container.read(strategyProvider).strategyName,
          'Renamed in the title');
      actions().undoAction();
      expectEarlierCaptionUndone();
      expect(stored(id).name, 'Renamed in the title');
    });
  });

  group('a drag move puts the item on top of its kind', () {
    final kinds = <String,
        (
      List<String> Function(),
      void Function(String, Offset),
      Offset Function(String)
    )>{
      'agent': (
        () => [for (final a in container.read(agentProvider)) a.id],
        (id, at) =>
            container.read(agentProvider.notifier).updatePosition(at, id),
        (id) => container
            .read(agentProvider)
            .singleWhere((a) => a.id == id)
            .position,
      ),
      'ability': (
        () => [for (final a in container.read(abilityProvider)) a.id],
        (id, at) =>
            container.read(abilityProvider.notifier).updatePosition(at, id),
        (id) => container
            .read(abilityProvider)
            .singleWhere((a) => a.id == id)
            .position,
      ),
      'text': (
        () => [for (final t in container.read(textProvider)) t.id],
        (id, at) =>
            container.read(textProvider.notifier).updatePosition(at, id),
        (id) => container
            .read(textProvider)
            .singleWhere((t) => t.id == id)
            .position,
      ),
      'image': (
        () =>
            [for (final i in container.read(placedImageProvider).images) i.id],
        (id, at) =>
            container.read(placedImageProvider.notifier).updatePosition(at, id),
        (id) => container
            .read(placedImageProvider)
            .images
            .singleWhere((i) => i.id == id)
            .position,
      ),
      'utility': (
        () => [for (final u in container.read(utilityProvider)) u.id],
        (id, at) =>
            container.read(utilityProvider.notifier).updatePosition(at, id),
        (id) => container
            .read(utilityProvider)
            .singleWhere((u) => u.id == id)
            .position,
      ),
    };

    for (final MapEntry(key: kind, value: (ids, move, at)) in kinds.entries) {
      test(
          'a dragged $kind goes last in its list, the drag is one undo step, '
          'undo puts its position back and leaves it last, and redo moves it '
          'again and leaves it last', () async {
        final id = await open();
        if (ids().length < 2) {
          switch (kind) {
            case 'text':
              final text = container.read(textProvider).first;
              container.read(textProvider.notifier).addText(PlacedText(
                    id: 'second-text',
                    position: text.position + const Offset(40, 40),
                    sizeVersion: text.sizeVersion,
                  )..text = 'Second');
            case 'image':
              final image = container.read(placedImageProvider).images.first;
              container.read(placedImageProvider.notifier).addImageCopy(
                  image.copyWith(
                      id: 'second-image',
                      position: image.position + const Offset(40, 40)));
          }
        }
        final first = ids().first;
        final from = at(first);
        final steps = history();
        move(first, from + const Offset(30, 20));

        expect(ids().last, first);
        expect(history(), steps + 1);
        await save(id);
        actions().undoAction();
        expect(at(first), from);
        expect(ids().last, first);
        actions().redoAction();
        expect(at(first), from + const Offset(30, 20));
        expect(ids().last, first);
      });
    }
  });
}
