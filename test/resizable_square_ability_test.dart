import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ResizableSquareAbility.resolveLength', () {
    const minLength = 5.0;
    const maxLength = 20.0;

    test('defaults to min when max-default is disabled', () {
      final ability = ResizableSquareAbility(
        width: 3,
        height: maxLength,
        iconPath: 'assets/agents/Cypher/1.webp',
        color: Colors.white,
        minLength: minLength,
      );

      expect(ability.resolveLength(0), minLength);
    });

    test('clamps values outside the supported range', () {
      final ability = ResizableSquareAbility(
        width: 3,
        height: maxLength,
        iconPath: 'assets/agents/Cypher/1.webp',
        color: Colors.white,
        minLength: minLength,
      );

      expect(ability.resolveLength(2), minLength);
      expect(ability.resolveLength(25), maxLength);
      expect(ability.resolveLength(12), 12);
    });
  });

  group('Neon/Cypher/Harbor defaults', () {
    test('Neon first ability is a wall resizable square that defaults to max',
        () {
      final ability = AgentData.agents[AgentType.neon]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      expect(ability.isWall, isTrue);
      expect(ability.defaultToMaxLength, isTrue);
      expect(ability.minLength, AgentData.inGameMeters);

      final widget = ability.createWidget(
        id: 'neon',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });

    test('Cypher first ability defaults to max', () {
      final ability = AgentData.agents[AgentType.cypher]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      expect(ability.isWall, isTrue);
      expect(ability.defaultToMaxLength, isTrue);

      final widget = ability.createWidget(
        id: 'cypher',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });

    test('Harbor last ability defaults to max and has a top border', () {
      final ability = AgentData.agents[AgentType.harbor]!.abilities.last
          .abilityData! as ResizableSquareAbility;

      expect(ability.defaultToMaxLength, isTrue);
      expect(ability.minLength, AgentData.inGameMeters);
      expect(ability.hasTopborder, isTrue);

      final widget = ability.createWidget(
        id: 'harbor',
        isAlly: true,
        mapScale: 1,
        length: 0,
      ) as ResizableSquareWidget;

      expect(widget.length, ability.height);
      expect(widget.maxLength, ability.height);
    });
  });

  group('Wall square geometry contracts', () {
    const mapScale = 1.25;
    const abilitySize = 42.0;

    test('wall square abilities report the full rendered width', () {
      final ability = AgentData
          .agents[AgentType.viper]!.abilities[2].abilityData! as SquareAbility;

      final size =
          ability.getSize(mapScale: mapScale, abilitySize: abilitySize);
      final anchor =
          ability.getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);

      expect(size.dx, abilitySize * 2);
      expect(anchor.dx, abilitySize);
    });

    test('wall resizable abilities report the full rendered width', () {
      final neonAbility = AgentData.agents[AgentType.neon]!.abilities.first
          .abilityData! as ResizableSquareAbility;
      final cypherAbility = AgentData.agents[AgentType.cypher]!.abilities.first
          .abilityData! as ResizableSquareAbility;

      for (final ability in [neonAbility, cypherAbility]) {
        final size =
            ability.getSize(mapScale: mapScale, abilitySize: abilitySize);
        final anchor = ability.getAnchorPoint(
          mapScale: mapScale,
          abilitySize: abilitySize,
        );
        final lengthAnchor = ability.getLengthAnchor(mapScale, abilitySize);

        expect(size.dx, abilitySize * 2);
        expect(anchor.dx, abilitySize);
        expect(lengthAnchor.dx, abilitySize);
      }
    });

    test('non-wall squares keep width based on map scale', () {
      final ability = AgentData.agents[AgentType.breach]!.abilities.first
          .abilityData! as SquareAbility;

      final size =
          ability.getSize(mapScale: mapScale, abilitySize: abilitySize);

      expect(size.dx, ability.width * mapScale);
    });
  });

  testWidgets(
      'PlacedAbilityWidget uses the resolved max length for the initial handle position',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final abilityInfo = AgentData.agents[AgentType.neon]!.abilities.first;
    final placedAbility = PlacedAbility(
      id: 'neon-placed',
      data: abilityInfo,
      position: const Offset(100, 100),
      length: 0,
    );

    final container = _createContainer();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    container.read(abilityProvider.notifier).fromHive([placedAbility]);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: ShadApp(
          home: Stack(
            children: [
              PlacedAbilityWidget(
                ability: placedAbility,
                onDragEnd: (_, __) {},
                id: placedAbility.id,
                data: placedAbility,
                rotation: placedAbility.rotation,
                length: placedAbility.length,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pump();

    final rotatableWidget =
        tester.widget<RotatableWidget>(find.byType(RotatableWidget));
    expect(rotatableWidget.buttonTop, 0);
  });

  testWidgets('wall resizable widget size matches modeled width',
      (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final ability = AgentData.agents[AgentType.neon]!.abilities.first
        .abilityData! as ResizableSquareAbility;
    final container = _createContainer();
    final abilitySize = container.read(strategySettingsProvider).abilitySize;

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ability.createWidget(
              id: 'neon-width',
              isAlly: true,
              mapScale: 1,
              length: 0,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final renderedSize = tester.getSize(find.byType(ResizableSquareWidget));
    final modeledSize =
        ability.getSize(mapScale: 1, abilitySize: abilitySize).scale(
              CoordinateSystem.instance.scaleFactor,
              CoordinateSystem.instance.scaleFactor,
            );

    expect(renderedSize.width, closeTo(modeledSize.dx, 0.0001));
  });

  testWidgets('wall square widget size matches modeled width', (tester) async {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));

    final ability = AgentData.agents[AgentType.viper]!.abilities[2].abilityData!
        as SquareAbility;
    final container = _createContainer();
    final abilitySize = container.read(strategySettingsProvider).abilitySize;

    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ability.createWidget(
              id: 'viper-width',
              isAlly: true,
              mapScale: 1,
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    final renderedSize = tester.getSize(find.byType(CustomSquareWidget));
    final modeledSize =
        ability.getSize(mapScale: 1, abilitySize: abilitySize).scale(
              CoordinateSystem.instance.scaleFactor,
              CoordinateSystem.instance.scaleFactor,
            );

    expect(renderedSize.width, closeTo(modeledSize.dx, 0.0001));
  });

  group("Vyse's Shear", () {
    // Shear before it could be resized, a fixed 12 m square.
    final fixedShear = SquareAbility(
      width: 1 * AgentData.inGameMeters,
      height: 12 * AgentData.inGameMeters,
      iconPath: 'assets/agents/Vyse/1.webp',
      color: Colors.deepPurple,
    );
    final shear = AgentData.agents[AgentType.vyse]!.abilities.first
        .abilityData! as ResizableSquareAbility;
    const mapScale = 1.25;

    const canvasKey = ValueKey('shear-canvas');

    Future<({Size box, Rect body, Rect icon, List<int> pixels})> render(
      WidgetTester tester,
      Ability ability, {
      double? length,
      AbilityVisualState? visualState,
    }) async {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final container = _createContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                key: canvasKey,
                child: SizedBox(
                  width: 200,
                  height: 300,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 80,
                        top: 20,
                        child: ability.createWidget(
                          id: 'shear',
                          isAlly: true,
                          mapScale: mapScale,
                          length: length,
                          visualState: visualState,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final result = (
        box: tester.getSize(find.byWidgetPredicate(
            (w) => w is CustomSquareWidget || w is ResizableSquareWidget)),
        body: tester.getRect(find.byKey(const ValueKey('square-range-body'))),
        icon: tester.getRect(find.byType(AbilityWidget)),
        pixels: (await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(canvasKey));
          final image = await boundary.toImage();
          final bytes = await image.toByteData();
          return bytes!.buffer.asUint8List().toList();
        }))!,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      return result;
    }

    test('keeps the box saved Shears were placed in', () {
      const abilitySize = 42.0;
      expect(
          shear.getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize),
          fixedShear.getAnchorPoint(
              mapScale: mapScale, abilitySize: abilitySize));
      expect(shear.getSize(mapScale: mapScale, abilitySize: abilitySize),
          fixedShear.getSize(mapScale: mapScale, abilitySize: abilitySize));
    });

    testWidgets('a saved Shear draws the same pixels', (tester) async {
      // Decode the icon first so both renders draw its glyph.
      await render(tester, fixedShear);
      for (final visualState in const [
        AbilityVisualState(),
        AbilityVisualState(showRangeFill: false),
      ]) {
        final before =
            await render(tester, fixedShear, visualState: visualState);
        final after =
            await render(tester, shear, length: 0, visualState: visualState);

        expect(after.box, before.box);
        expect(after.pixels, before.pixels,
            reason: 'range shown: ${visualState.showRangeFill}');
      }
    });

    testWidgets('a shortened Shear pulls its far end toward Vyse',
        (tester) async {
      final full = await render(tester, shear, length: 0);
      final short =
          await render(tester, shear, length: 5 * AgentData.inGameMeters);
      final scale = CoordinateSystem.instance.scaleFactor;

      expect(short.box, full.box);
      expect(short.icon, full.icon);
      expect(short.body.bottom, full.body.bottom);
      expect(short.body.height,
          closeTo(5 * AgentData.inGameMeters * mapScale * scale, 0.001));
    });

    test('a page change tweens from the length a saved Shear draws', () {
      final info = AgentData.agents[AgentType.vyse]!.abilities.first;
      PlacedAbility placed(double length) => PlacedAbility(
          data: info, position: Offset.zero, id: 'shear', length: length);
      const short = 5 * AgentData.inGameMeters;

      final entry =
          PageTransitionEntry.move(from: placed(0), to: placed(short));

      expect(entry.startLength, shear.height);
      expect(entry.endLength, short);
      expect(PageTransitionEntry.visualsDiffer(placed(0), placed(shear.height)),
          isFalse);
    });

    test('shortens to 1 m like Trapwire', () {
      expect(shear.defaultToMaxLength, isTrue);
      expect(shear.minLength, AgentData.inGameMeters);
      expect(shear.resolveLength(0), shear.height);
    });
  });
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

ProviderContainer _createContainer() {
  return ProviderContainer(
    overrides: [
      mapProvider.overrideWith(_FixedMapProvider.new),
    ],
  );
}
