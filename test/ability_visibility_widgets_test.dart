import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/action_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/custom_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/sector_circle_widget.dart';
import 'package:icarus/widgets/line_up_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _TestActionProvider extends ActionProvider {
  @override
  List<UserAction> build() => [];

  @override
  void addAction(UserAction action) {
    poppedItems = [];
    state = [...state, action];
  }
}

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.bind, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('Ability visibility widgets', () {
    testWidgets('square icon-only mode hides range body and handle',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final ability = PlacedAbility(
        id: 'square-hidden',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: const Offset(100, 120),
        rotation: math.pi / 4,
        visualState: const AbilityVisualState(
          showRangeBody: false,
          showPerimeter: true,
        ),
      );
      container.read(abilityProvider.notifier).fromHive([ability]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              PlacedAbilityWidget(
                ability: ability,
                onDragEnd: (_) {},
                id: ability.id,
                data: ability,
                rotation: ability.rotation,
                length: ability.length,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final rangeBody = tester.widget<Opacity>(
        find.byKey(const ValueKey('square-range-body')),
      );
      final rotatable = tester.widget<RotatableWidget>(
        find.byType(RotatableWidget),
      );

      expect(rangeBody.opacity, 0);
      expect(rotatable.showHandle, isFalse);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('circle visibility toggles preserve icon and target layers',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final perimeterCircle = CircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 10,
        outlineColor: Colors.white,
        hasCenterDot: true,
        hasPerimeter: true,
        perimeterSize: 5,
        fillColor: Colors.red,
      );

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Center(
            child: perimeterCircle.createWidget(
              id: 'perimeter-circle',
              isAlly: true,
              mapScale: 1,
              visualState: const AbilityVisualState(
                showRangeBody: false,
                showPerimeter: true,
              ),
              watchMouse: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Opacity>(
                find.byKey(const ValueKey('circle-perimeter-layer')))
            .opacity,
        1,
      );
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('circle-size-layer')))
            .opacity,
        0,
      );
      expect(find.byType(AbilityWidget), findsOneWidget);

      final fillOnlyCircle = CircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 10,
        outlineColor: Colors.blue,
        hasCenterDot: true,
        hasPerimeter: false,
      );

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Center(
            child: fillOnlyCircle.createWidget(
              id: 'fill-circle',
              isAlly: true,
              mapScale: 1,
              visualState: const AbilityVisualState(
                showRangeBody: false,
                showPerimeter: false,
              ),
              watchMouse: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Opacity>(
                find.byKey(const ValueKey('circle-perimeter-layer')))
            .opacity,
        0,
      );
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('circle-size-layer')))
            .opacity,
        0,
      );
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('deadlock hidden mesh hides mesh and all handles',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final ability = PlacedAbility(
        id: 'deadlock-hidden',
        data: AgentData.agents[AgentType.deadlock]!.abilities[2],
        position: const Offset(100, 120),
        visualState: const AbilityVisualState(
          showRangeBody: false,
          showPerimeter: true,
        ),
      );
      container.read(abilityProvider.notifier).fromHive([ability]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              PlacedAbilityWidget(
                ability: ability,
                onDragEnd: (_) {},
                id: ability.id,
                data: ability,
                rotation: ability.rotation,
                length: ability.length,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mesh = tester.widget<Opacity>(
        find.byKey(const ValueKey('deadlock-mesh-layer')),
      );

      expect(mesh.opacity, 0);
      expect(
          find.byKey(const ValueKey('deadlock-rotation-handle')), findsNothing);
      expect(find.byKey(const ValueKey('deadlock-arm-handle-topRight')),
          findsNothing);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('sector hidden range body keeps icon but hides fill and handle',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final ability = PlacedAbility(
        id: 'sector-hidden',
        data: _sectorAbilityInfo(),
        position: const Offset(100, 120),
        visualState: const AbilityVisualState(
          showRangeBody: false,
          showPerimeter: true,
        ),
      );
      container.read(abilityProvider.notifier).fromHive([ability]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              PlacedAbilityWidget(
                ability: ability,
                onDragEnd: (_) {},
                id: ability.id,
                data: ability,
                rotation: ability.rotation,
                length: ability.length,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final painter = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is SectorCirclePainter,
        ),
      );
      final rotatable = tester.widget<RotatableWidget>(
        find.byType(RotatableWidget),
      );

      expect((painter.painter! as SectorCirclePainter).fillColor, isNull);
      expect(rotatable.showHandle, isFalse);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });
  });

  group('Ability visibility context menus', () {
    testWidgets('placed square ability shows Toggle Range', (tester) async {
      final squareAbility = PlacedAbility(
        id: 'square-menu',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: Offset.zero,
      );

      await _pumpPlacedAbility(
        tester,
        ability: squareAbility,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Range'), findsOneWidget);
      expect(find.text('Toggle Perimeter'), findsNothing);
      expect(find.text('Toggle Mesh'), findsNothing);
    });

    testWidgets('placed circle ability shows perimeter and size toggles',
        (tester) async {
      final circleAbility = PlacedAbility(
        id: 'circle-menu',
        data: AbilityInfo(
          name: 'Circle',
          iconPath: 'assets/agents/Cypher/1.webp',
          type: AgentType.astra,
          index: 0,
          abilityData: CircleAbility(
            iconPath: 'assets/agents/Cypher/1.webp',
            size: 8,
            outlineColor: Colors.white,
            hasCenterDot: true,
            hasPerimeter: true,
            perimeterSize: 4,
            fillColor: Colors.purple,
          ),
        ),
        position: Offset.zero,
      );

      await _pumpPlacedAbility(
        tester,
        ability: circleAbility,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Perimeter'), findsOneWidget);
      expect(find.text('Toggle Size'), findsOneWidget);
      expect(find.text('Toggle Range'), findsNothing);
    });

    testWidgets('placed deadlock ability shows Toggle Mesh', (tester) async {
      final deadlockAbility = PlacedAbility(
        id: 'deadlock-menu',
        data: AgentData.agents[AgentType.deadlock]!.abilities[2],
        position: Offset.zero,
      );

      await _pumpPlacedAbility(
        tester,
        ability: deadlockAbility,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Mesh'), findsOneWidget);
      expect(find.text('Toggle Range'), findsNothing);
    });

    testWidgets(
        'placed sector ability shows and applies size/perimeter toggles',
        (tester) async {
      final sectorAbility = PlacedAbility(
        id: 'sector-menu',
        data: _sectorAbilityInfo(),
        position: Offset.zero,
      );

      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      container.read(abilityProvider.notifier).fromHive([sectorAbility]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              PlacedAbilityWidget(
                ability: sectorAbility,
                onDragEnd: (_) {},
                id: sectorAbility.id,
                data: sectorAbility,
                rotation: sectorAbility.rotation,
                length: sectorAbility.length,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Perimeter'), findsOneWidget);
      expect(find.text('Toggle Size'), findsOneWidget);

      await tester.tap(find.text('Toggle Size'));
      await tester.pumpAndSettle();

      expect(
        container.read(abilityProvider).single.visualState.showRangeBody,
        isFalse,
      );
    });

    testWidgets('placed square body right-click does not show menu',
        (tester) async {
      final squareAbility = PlacedAbility(
        id: 'square-body-no-menu',
        data: AgentData.agents[AgentType.breach]!.abilities.first,
        position: Offset.zero,
      );

      await _pumpPlacedAbility(
        tester,
        ability: squareAbility,
      );

      final squareRect = tester.getRect(find.byType(CustomSquareWidget));
      await tester.tapAt(
        squareRect.topCenter + const Offset(0, 6),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.text('Toggle Range'), findsNothing);
    });

    testWidgets('sidebar preview does not expose placed-ability menu',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final ability = AgentData.agents[AgentType.breach]!.abilities.first;

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Center(
            child: ability.abilityData!.createWidget(
              id: null,
              isAlly: true,
              mapScale: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Range'), findsNothing);
      expect(find.text('Toggle Perimeter'), findsNothing);
      expect(find.text('Toggle Mesh'), findsNothing);
    });

    testWidgets('lineup preview menu merges visibility and delete actions',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final lineUp = LineUp(
        id: 'lineup-menu',
        agent: PlacedAgent(
          id: 'lineup-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: const Offset(50, 50),
        ),
        youtubeLink: '',
        images: const [],
        notes: 'preview',
      );
      container.read(lineUpProvider.notifier).fromHive([lineUp]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              LineUpAbilityWidget(lineUp: lineUp),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Range'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Toggle Range'));
      await tester.pumpAndSettle();

      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeBody,
        isFalse,
      );
    });

    testWidgets('lineup sector menu merges visibility and delete actions',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          actionProvider.overrideWith(_TestActionProvider.new),
          mapProvider.overrideWith(_FixedMapProvider.new),
        ],
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });

      final lineUp = LineUp(
        id: 'lineup-sector-menu',
        agent: PlacedAgent(
          id: 'lineup-sector-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-sector-ability',
          data: _sectorAbilityInfo(),
          position: const Offset(50, 50),
        ),
        youtubeLink: '',
        images: const [],
        notes: 'preview',
      );
      container.read(lineUpProvider.notifier).fromHive([lineUp]);

      await tester.pumpWidget(
        _buildHarness(
          container: container,
          child: Stack(
            children: [
              LineUpAbilityWidget(lineUp: lineUp),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Toggle Perimeter'), findsOneWidget);
      expect(find.text('Toggle Size'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Toggle Perimeter'));
      await tester.pumpAndSettle();

      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showPerimeter,
        isFalse,
      );
    });
  });
}

Widget _buildHarness({
  required ProviderContainer container,
  required Widget child,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: ShadApp(
      home: Scaffold(
        body: child,
      ),
    ),
  );
}

Future<void> _pumpPlacedAbility(
  WidgetTester tester, {
  required PlacedAbility ability,
}) async {
  final container = ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_TestActionProvider.new),
      mapProvider.overrideWith(_FixedMapProvider.new),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
  container.read(abilityProvider.notifier).fromHive([ability]);

  await tester.pumpWidget(
    _buildHarness(
      container: container,
      child: Stack(
        children: [
          PlacedAbilityWidget(
            ability: ability,
            onDragEnd: (_) {},
            id: ability.id,
            data: ability,
            rotation: ability.rotation,
            length: ability.length,
          ),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openContextMenu(WidgetTester tester, Finder finder) async {
  await tester.tapAt(
    tester.getCenter(finder),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

AbilityInfo _sectorAbilityInfo() {
  return AbilityInfo(
    name: 'Sector',
    iconPath: 'assets/agents/Cypher/1.webp',
    type: AgentType.cypher,
    index: 95,
    abilityData: SectorCircleAbility(
      iconPath: 'assets/agents/Cypher/1.webp',
      size: 6.5,
      outlineColor: Colors.cyan,
      sweepAngleDegrees: 75,
    ),
  );
}
