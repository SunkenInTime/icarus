import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/map_doors.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/page_transition/transition_planner.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/canvas_selection_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/screen_zoom_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/transition_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/screenshot/caption_export_overlay.dart';
import 'package:icarus/widgets/caption_markers.dart';
import 'package:icarus/widgets/map_door_layer.dart';
import 'package:icarus/widgets/map_svg_color_mapper.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _TestStrategyProvider extends StrategyProvider {
  @override
  StrategyState build() => StrategyState(
        isSaved: true,
        stratName: null,
        id: 'door-test',
        storageDirectory: null,
        activePageId: 'page-1',
      );

  @override
  void setUnsaved() => state = state.copyWith(isSaved: false);
}

class _FixedMapProvider extends MapProvider {
  _FixedMapProvider(this.map, this.isAttack);

  final MapValue map;
  final bool isAttack;

  @override
  MapState build() => MapState(currentMap: map, isAttack: isAttack);

  @override
  void updateMap(MapValue map) => state = state.copyWith(currentMap: map);
}

ProviderContainer _container({
  MapValue map = MapValue.summit,
  bool isAttack = true,
  bool canEdit = true,
}) {
  final container = ProviderContainer(overrides: [
    strategyProvider.overrideWith(_TestStrategyProvider.new),
    mapProvider.overrideWith(() => _FixedMapProvider(map, isAttack)),
    effectiveMapThemePaletteProvider.overrideWithValue(
      MapThemePalette(
        baseColorValue: 0xFF271406,
        detailColorValue: 0xFFB27C40,
        highlightColorValue: 0xFFF08234,
      ),
    ),
    currentStrategyCapabilitiesProvider.overrideWithValue(
      canEdit
          ? StrategyCapabilities.fullAccess()
          : StrategyCapabilities.fromCloudRole('viewer'),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

MapDoor _door(String id) => mapDoors.firstWhere((door) => door.id == id);

PlacedUtility _plainRectangle(String id) => PlacedUtility(
      id: id,
      type: UtilityType.customRectangle,
      position: const Offset(500, 500),
      customWidth: 5,
      customLength: 5,
      customColorValue: 0xFF22C55E,
      customOpacityPercent: 30,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => CoordinateSystem(playAreaSize: const Size(1600, 900)));

  /// The middle of [row] where the canvas draws a plain rectangle, as a build
  /// that doesn't know doors places it.
  Offset drawnMiddle(PlacedUtility row, {required bool isAttack}) {
    final coordinates = CoordinateSystem.instance;
    final mapScale = Maps.mapScale[_rowMap(row)]!;
    final topLeft = screenPositionForWidget(
      widget: row,
      coordinateSystem: coordinates,
      mapScale: mapScale,
      agentSize: Settings.agentSize,
      abilitySize: Settings.abilitySize,
      isAttack: isAttack,
    );
    final anchor = utilityAnchorForScale(
      utility: row,
      mapScale: mapScale,
      agentSize: Settings.agentSize,
      abilitySize: Settings.abilitySize,
    ).scale(coordinates.scaleFactor, coordinates.scaleFactor);
    return topLeft + anchor;
  }

  group('a door saved as a rectangle', () {
    for (final door in mapDoors) {
      for (final isAttack in [true, false]) {
        test(
            '${door.id} lands on its bar on the '
            '${isAttack ? 'attacking' : 'defending'} side', () {
          final row = door.row(id: 'row');

          final drawn = drawnMiddle(row, isAttack: isAttack);
          final bar = mapDoorMiddleOnCanvas(door, isAttack: isAttack);

          expect((drawn - bar).distance, lessThan(0.01));
        });
      }

      test('${door.id} is as long as its bar', () {
        final row = door.row(id: 'row');
        final coordinates = CoordinateSystem.instance;
        final (from, to) = door.worldLine(changed: 1);
        final anchor = utilityAnchorForScale(
          utility: row,
          mapScale: Maps.mapScale[door.map]!,
          agentSize: Settings.agentSize,
          abilitySize: Settings.abilitySize,
        );

        expect(
          coordinates.scale(anchor.dx * 2),
          closeTo(coordinates.worldHeightToScreen((to - from).distance), 0.01),
        );
      });
    }

    test('points the way the door points when changed', () {
      final wall = _door('summit-mid').row(id: 'row');
      final spun = _door('lotus-a').row(id: 'row');

      expect(wall.rotation, closeTo(0, 1e-9));
      expect(spun.rotation.abs(), closeTo(1.5708, 0.001));
    });

    test("a broken wall is the floor's colour, so old builds show no wall", () {
      expect(
        _door('lotus-a-link').row(id: 'row').customColorValue,
        MapSvgSourceColors.base.toARGB32(),
      );
      expect(
        _door('summit-a').row(id: 'row').customColorValue,
        MapSvgSourceColors.detail.toARGB32(),
      );
      expect(
        _door('lotus-a').row(id: 'row').customColorValue,
        MapSvgSourceColors.detail.toARGB32(),
      );
    });
  });

  group('which rows are doors', () {
    test('a row naming a door of this map is one', () {
      final row = _door('summit-a').row(id: 'row');

      expect(mapDoorOfRow(row, MapValue.summit)?.id, 'summit-a');
    });

    test('a row naming a door of another map is a rectangle', () {
      final row = _door('summit-a').row(id: 'row');

      expect(mapDoorOfRow(row, MapValue.lotus), isNull);
    });

    test('a row naming a door from a later release is a rectangle', () {
      final row = PlacedUtility(
        id: 'row',
        type: UtilityType.customRectangle,
        position: Offset.zero,
        mapDoor: 'haven-c',
      );

      expect(mapDoorOfRow(row, MapValue.haven), isNull);
    });

    test('a rectangle with no door is one', () {
      expect(mapDoorOfRow(_plainRectangle('a'), MapValue.summit), isNull);
    });
  });

  group('clicking a door', () {
    test('saves a row, and a second click takes it away', () {
      final container = _container();
      final utilities = container.read(utilityProvider.notifier);

      utilities.toggleMapDoor(_door('summit-mid'));
      expect(
        changedMapDoors(container.read(utilityProvider), MapValue.summit),
        {'summit-mid'},
      );

      utilities.toggleMapDoor(_door('summit-mid'));
      expect(container.read(utilityProvider), isEmpty);
    });

    test('is one undo step each way', () {
      final container = _container();
      final utilities = container.read(utilityProvider.notifier);
      final history = container.read(actionProvider.notifier);

      utilities.toggleMapDoor(_door('summit-mid'));
      utilities.toggleMapDoor(_door('summit-mid'));

      history.undoAction();
      expect(container.read(utilityProvider), hasLength(1));
      expect(container.read(utilityProvider).single.mapDoor, 'summit-mid');
      history.undoAction();
      expect(container.read(utilityProvider), isEmpty);
      history.redoAction();
      expect(container.read(utilityProvider), hasLength(1));
    });

    test("takes away two teammates' rows as one undo step", () {
      final container = _container();
      final utilities = container.read(utilityProvider.notifier);
      final history = container.read(actionProvider.notifier);
      final door = _door('summit-mid');
      utilities.fromHive([door.row(id: 'mine'), door.row(id: 'theirs')]);

      utilities.toggleMapDoor(door);
      expect(container.read(utilityProvider), isEmpty);

      history.undoAction();
      expect(
        container.read(utilityProvider).map((row) => row.id),
        unorderedEquals(['mine', 'theirs']),
      );
    });

    test('leaves other rows alone', () {
      final container = _container();
      final utilities = container.read(utilityProvider.notifier);
      final door = _door('summit-mid');
      utilities.fromHive([_plainRectangle('shape'), door.row(id: 'row')]);

      utilities.toggleMapDoor(door);

      expect(container.read(utilityProvider).single.id, 'shape');
    });

    test('does nothing for a viewer', () {
      final container = _container(canEdit: false);

      container
          .read(utilityProvider.notifier)
          .toggleMapDoor(_door('summit-mid'));

      expect(container.read(utilityProvider), isEmpty);
    });
  });

  group('a door row is not an item', () {
    test('selecting everything leaves it out', () {
      final container = _container();
      container.read(utilityProvider.notifier).fromHive([
        _plainRectangle('shape'),
        _door('summit-mid').row(id: 'row'),
      ]);

      container.read(canvasSelectionProvider.notifier).selectAll();

      expect(
        container.read(canvasSelectionProvider).map((item) => item.id),
        ['shape'],
      );
    });

    test('a page change leaves it out of the items that move', () {
      final placed = TransitionPlanner.placedWidgetMap(
        agents: const [],
        abilities: const [],
        text: const [],
        images: const [],
        utilities: [
          _plainRectangle('shape'),
          _door('summit-mid').row(id: 'row'),
        ],
        map: MapValue.summit,
      );

      expect(placed.keys, ['shape']);
    });

    test('a caption an old build put on it shows no marker', () {
      final container = _container();
      container.read(utilityProvider.notifier).fromHive([
        _door('summit-mid').row(id: 'row')..caption = 'Dropped on 2',
        _plainRectangle('shape')..caption = 'A note',
      ]);
      final sub = container.listen(captionedItemsProvider, (_, __) {});
      addTearDown(sub.close);

      expect(sub.read().all, {'shape'});
    });

    test('a row on another map stays an item', () {
      final container = _container(map: MapValue.ascent);
      container
          .read(utilityProvider.notifier)
          .fromHive([_door('summit-mid').row(id: 'row')]);

      container.read(canvasSelectionProvider.notifier).selectAll();

      expect(
        container.read(canvasSelectionProvider).map((item) => item.id),
        ['row'],
      );
    });

    test('a picture prints no caption from a door row', () {
      final items = captionExportItems([
        ...withoutMapDoors([
          _door('summit-mid').row(id: 'row')..caption = 'Dropped on 2',
          _plainRectangle('shape')..caption = 'A note',
        ], MapValue.summit),
      ]);

      expect(items.map((item) => item.id), ['shape']);
    });

    test('a selected rectangle that becomes a door on a map change lets go',
        () {
      final container = _container(map: MapValue.ascent);
      final row = _door('summit-mid').row(id: 'row');
      container.read(utilityProvider.notifier).fromHive([row]);
      container.read(canvasSelectionProvider.notifier).selectAll();
      expect(container.read(canvasSelectionProvider), hasLength(1));

      container.read(mapProvider.notifier).updateMap(MapValue.summit);

      expect(container.read(canvasSelectionProvider), isEmpty);
    });
  });

  group('how a door is painted', () {
    Future<Color> middlePixel(MapDoorKind kind, double changed) async {
      const wall = Color(0xFFB27C40);
      final recorder = ui.PictureRecorder();
      MapDoorPainter(
        kind: kind,
        line: (const Offset(10, 20), const Offset(90, 20)),
        changed: changed,
        wallColor: wall,
        thickness: 6,
      ).paint(Canvas(recorder), const Size(100, 40));
      final picture = recorder.endRecording();
      final image = await picture.toImage(100, 40);
      try {
        final bytes = (await image.toByteData())!;
        final at = (20 * 100 + 50) * 4;
        return Color.fromARGB(
          bytes.getUint8(at + 3),
          bytes.getUint8(at),
          bytes.getUint8(at + 1),
          bytes.getUint8(at + 2),
        );
      } finally {
        image.dispose();
        picture.dispose();
      }
    }

    test("a raised wall is the theme's wall colour, like a closed door",
        () async {
      final raised = await middlePixel(MapDoorKind.drop, 1);
      final closed = await middlePixel(MapDoorKind.spin, 0);

      expect(raised.toARGB32(), 0xFFB27C40);
      expect(raised, closed);
    });

    test('a dropped wall draws nothing over the map art', () async {
      expect((await middlePixel(MapDoorKind.drop, 0)).a, 0);
    });
  });

  group('the layer on the canvas', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      MapValue map = MapValue.summit,
      bool isAttack = true,
      bool canEdit = true,
      Widget? above,
    }) async {
      tester.view
        ..physicalSize = const Size(1600, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CoordinateSystem(playAreaSize: const Size(1600, 900));
      final container =
          _container(map: map, isAttack: isAttack, canEdit: canEdit);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: ShadApp(
            home: SizedBox(
              width: 1600,
              height: 900,
              child: Stack(
                children: [
                  const Positioned.fill(child: MapDoorLayer()),
                  if (above != null) above,
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    bool hovered(WidgetTester tester) => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((paint) => paint.painter)
        .whereType<MapDoorPainter>()
        .any((bar) => bar.hovered);

    MouseCursor? cursor() =>
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

    Offset middle(String id, {bool isAttack = true}) =>
        mapDoorMiddleOnCanvas(_door(id), isAttack: isAttack);

    Set<String> changed(ProviderContainer container, MapValue map) =>
        changedMapDoors(container.read(utilityProvider), map);

    testWidgets('a click on a bar changes that door', (tester) async {
      final container = await pump(tester);

      await tester.tapAt(middle('summit-mid'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(changed(container, MapValue.summit), {'summit-mid'});
    });

    testWidgets('finds the door on the defending side', (tester) async {
      final container = await pump(tester, isAttack: false);

      await tester.tapAt(middle('summit-b', isAttack: false));
      await tester.pump(const Duration(milliseconds: 300));

      expect(changed(container, MapValue.summit), {'summit-b'});
    });

    testWidgets('its margin stays the same on screen at any zoom',
        (tester) async {
      final container = await pump(tester);
      container.read(screenZoomProvider.notifier).updateZoom(4);
      await tester.pump();
      final bar = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<MapDoorPainter>()
          .first;

      expect(bar.reach, 1.5);
    });

    testWidgets('a click beside a bar changes nothing', (tester) async {
      final container = await pump(tester);

      await tester.tapAt(middle('summit-mid') + const Offset(0, 30));
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(utilityProvider), isEmpty);
    });

    testWidgets('a map with no doors has nothing to click', (tester) async {
      final container = await pump(tester, map: MapValue.ascent);

      expect(find.byType(CustomPaint), findsNothing);
      await tester.tapAt(const Offset(800, 450));
      expect(container.read(utilityProvider), isEmpty);
    });

    for (final state in [
      InteractionState.drawing,
      InteractionState.erasing,
      InteractionState.lineUpPlacing,
      InteractionState.lineUpEditing,
    ]) {
      testWidgets('ignores a click while ${state.name}', (tester) async {
        final container = await pump(tester);
        container.read(interactionStateProvider.notifier).update(state);
        await tester.pump();

        await tester.tapAt(middle('summit-mid'));
        await tester.pump(const Duration(milliseconds: 300));

        expect(container.read(utilityProvider), isEmpty);
      });
    }

    testWidgets('a viewer sees bars and can neither hover nor click',
        (tester) async {
      final container = await pump(tester, map: MapValue.lotus, canEdit: false);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(5, 5));

      await mouse.moveTo(middle('lotus-a'));
      await tester.pump();
      expect(hovered(tester), isFalse);
      expect(cursor(), SystemMouseCursors.basic);

      await tester.tapAt(middle('lotus-a'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(utilityProvider), isEmpty);
    });

    testWidgets('something placed on top keeps the click', (tester) async {
      var pressed = 0;
      final spot = mapDoorMiddleOnCanvas(_door('summit-mid'), isAttack: true);
      final container = await pump(
        tester,
        above: Positioned(
          left: spot.dx - 20,
          top: spot.dy - 20,
          width: 40,
          height: 40,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => pressed++,
          ),
        ),
      );

      await tester.tapAt(spot);
      await tester.pump(const Duration(milliseconds: 300));

      expect(pressed, 1);
      expect(container.read(utilityProvider), isEmpty);
    });

    testWidgets(
        'hovering lights the bar and shows the hand, and only a click '
        'changes the door', (tester) async {
      final container = await pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(5, 5));

      await mouse.moveTo(middle('summit-mid'));
      await tester.pump(const Duration(seconds: 1));
      expect(hovered(tester), isTrue);
      expect(cursor(), SystemMouseCursors.click);
      expect(container.read(utilityProvider), isEmpty);
      expect(find.byType(Text), findsNothing);

      await mouse.down(middle('summit-mid'));
      await mouse.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(changed(container, MapValue.summit), {'summit-mid'});

      await mouse.moveTo(const Offset(5, 5));
      await tester.pump();
      expect(hovered(tester), isFalse);
      expect(changed(container, MapValue.summit), {'summit-mid'});
    });

    testWidgets('clicks wait for a page change to end', (tester) async {
      final container = await pump(tester);
      container.read(transitionProvider.notifier).start(
            const [],
            startAgentSize: 25,
            endAgentSize: 25,
            startAbilitySize: 25,
            endAbilitySize: 25,
          );
      await tester.pump();

      await tester.tapAt(middle('summit-mid'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(container.read(utilityProvider), isEmpty);
    });

    testWidgets('a page change turns a door part way at its progress',
        (tester) async {
      final container = await pump(tester, map: MapValue.lotus);
      final notifier = container.read(transitionProvider.notifier);
      notifier.prepare(
        const [],
        startAgentSize: 25,
        startAbilitySize: 25,
        fromDoors: const {},
      );
      container
          .read(utilityProvider.notifier)
          .fromHive([_door('lotus-a').row(id: 'row')]);
      notifier.start(
        const [],
        startAgentSize: 25,
        endAgentSize: 25,
        startAbilitySize: 25,
        endAbilitySize: 25,
      );
      notifier.setProgress(0.5);
      await tester.pump();

      final painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((paint) => paint.painter)
          .whereType<MapDoorPainter>()
          .firstWhere((painter) => painter.kind == MapDoorKind.spin);
      expect(painter.changed, 0.5);
    });
  });
}

MapValue _rowMap(PlacedUtility row) =>
    mapDoors.firstWhere((door) => door.id == row.mapDoor).map;
