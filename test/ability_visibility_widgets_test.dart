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
import 'package:icarus/widgets/draggable_widgets/ability/resizable_square_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/sector_circle_widget.dart';
import 'package:icarus/widgets/line_up_media_carousel.dart';
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
          showRangeFill: false,
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
        rangeOutlineColor: Colors.white,
        hasCenterDot: true,
        innerRangeSize: 5,
        innerRangeColor: Colors.red,
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
                showInnerFill: false,
                showInnerOutline: false,
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
                find.byKey(const ValueKey('circle-range-outline-layer')))
            .opacity,
        1,
      );
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('circle-inner-fill-layer')))
            .opacity,
        0,
      );
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('circle-inner-outline-layer')),
            )
            .opacity,
        0,
      );
      expect(find.byType(AbilityWidget), findsOneWidget);

      final fillOnlyCircle = CircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 10,
        rangeOutlineColor: Colors.blue,
        hasCenterDot: true,
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
                showRangeFill: false,
                showRangeOutline: false,
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
                find.byKey(const ValueKey('circle-range-outline-layer')))
            .opacity,
        0,
      );
      expect(
        tester
            .widget<Opacity>(find.byKey(const ValueKey('circle-range-fill-layer')))
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
          showRangeFill: false,
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

    testWidgets('sector icon-only mode keeps icon but hides range and handle',
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
          showRangeFill: false,
          showRangeOutline: false,
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
    testWidgets('placed square ability shows Range', (tester) async {
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

      expect(find.text('Range'), findsOneWidget);
      expect(find.text('Range Outline'), findsNothing);
      expect(find.text('Mesh'), findsNothing);
    });

    testWidgets('placed circle ability shows range and inner layer toggles',
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
            rangeOutlineColor: Colors.white,
            hasCenterDot: true,
            innerRangeSize: 4,
            innerRangeColor: Colors.purple,
          ),
        ),
        position: Offset.zero,
      );

      await _pumpPlacedAbility(
        tester,
        ability: circleAbility,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget));

      expect(find.text('Range Outline'), findsOneWidget);
      expect(find.text('Inner Outline'), findsOneWidget);
      expect(find.text('Inner Fill'), findsOneWidget);
      expect(find.text('Range'), findsNothing);
    });

    testWidgets('placed deadlock ability shows Mesh', (tester) async {
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

      expect(find.text('Mesh'), findsOneWidget);
      expect(find.text('Range'), findsNothing);
    });

    testWidgets(
        'placed sector ability shows and applies range outline/fill toggles',
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

      expect(find.text('Range Outline'), findsOneWidget);
      expect(find.text('Range Fill'), findsOneWidget);

      await tester.tap(find.text('Range Fill'));
      await tester.pumpAndSettle();

      expect(
        container.read(abilityProvider).single.visualState.showRangeFill,
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

      expect(find.text('Range'), findsNothing);
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

      expect(find.text('Range'), findsNothing);
      expect(find.text('Range Outline'), findsNothing);
      expect(find.text('Mesh'), findsNothing);
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

      expect(find.text('Range'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Range'));
      await tester.pumpAndSettle();

      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeFill,
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

      expect(find.text('Range Outline'), findsOneWidget);
      expect(find.text('Range Fill'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.text('Range Outline'));
      await tester.pumpAndSettle();

      expect(
        container
            .read(lineUpProvider)
            .lineUps
            .single
            .ability
            .visualState
            .showRangeOutline,
        isFalse,
      );
    });

    testWidgets('lineup square body right-click does not show menu',
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
        id: 'lineup-body-no-menu',
        agent: PlacedAgent(
          id: 'lineup-body-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-body-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: Offset.zero,
        ),
        youtubeLink: '',
        images: const [],
        notes: 'body hover note',
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

      final squareRect = tester.getRect(find.byType(CustomSquareWidget));
      await tester.tapAt(
        squareRect.topCenter + const Offset(0, 6),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.text('Range'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('lineup square icon right-click still shows menu',
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
        id: 'lineup-icon-menu',
        agent: PlacedAgent(
          id: 'lineup-icon-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-icon-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: Offset.zero,
        ),
        youtubeLink: '',
        images: const [],
        notes: 'icon hover note',
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

      expect(find.text('Range'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('lineup note hover is icon-only', (tester) async {
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
        id: 'lineup-hover-note',
        agent: PlacedAgent(
          id: 'lineup-hover-agent',
          type: AgentType.breach,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-hover-ability',
          data: AgentData.agents[AgentType.breach]!.abilities.first,
          position: Offset.zero,
        ),
        youtubeLink: '',
        images: const [],
        notes: 'icon-only note',
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

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();

      final squareRect = tester.getRect(find.byType(CustomSquareWidget));
      await mouse.moveTo(squareRect.topCenter + const Offset(0, 6));
      await tester.pumpAndSettle();

      expect(find.text('icon-only note'), findsNothing);

      await mouse.moveTo(tester.getCenter(find.byType(AbilityWidget)));
      await tester.pumpAndSettle();

      expect(find.text('icon-only note'), findsOneWidget);
    });

    testWidgets('lineup resizable square body right-click does not show menu',
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
        id: 'lineup-resizable-body-no-menu',
        agent: PlacedAgent(
          id: 'lineup-resizable-agent',
          type: AgentType.neon,
          position: const Offset(20, 20),
        ),
        ability: PlacedAbility(
          id: 'lineup-resizable-ability',
          data: AgentData.agents[AgentType.neon]!.abilities.first,
          position: Offset.zero,
          rotation: math.pi / 6,
        ),
        youtubeLink: '',
        images: const [],
        notes: 'resizable note',
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

      final resizableRect = tester.getRect(find.byType(ResizableSquareWidget));
      await tester.tapAt(
        resizableRect.topCenter + const Offset(0, 6),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.text('Range'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets(
        'stacked lineup icon left-click opens selector before media carousel',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await tester.tap(find.byType(AbilityWidget).last);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lineup-stack-selector')), findsOneWidget);
      expect(find.byType(LineUpMediaCarousel), findsNothing);
    });

    testWidgets('stack selector hover previews the hovered lineup item',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await tester.tap(find.byType(AbilityWidget).last);
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(
            const ValueKey('lineup-stack-option-group-a-item-a'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final hoveredTarget = container.read(hoveredLineUpTargetProvider);
      expect(hoveredTarget?.groupId, 'group-a');
      expect(hoveredTarget?.itemId, 'item-a');
    });

    testWidgets('stack selector option opens the selected lineup media',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await tester.tap(find.byType(AbilityWidget).last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey('lineup-stack-option-group-a-item-a'),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();

      expect(find.byType(LineUpMediaCarousel), findsOneWidget);
    });

    testWidgets(
        'stacked lineup icon right-click opens selector before context menu',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget).last);

      expect(find.byKey(const ValueKey('lineup-stack-selector')), findsOneWidget);
      expect(find.text('Range'), findsNothing);
    });

    testWidgets(
        'stacked lineup right-click selection targets only the chosen item',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await _openContextMenu(tester, find.byType(AbilityWidget).last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(
          const ValueKey('lineup-stack-option-group-a-item-a'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Range'), findsOneWidget);
      await tester.tap(find.text('Range'));
      await tester.pumpAndSettle();

      final currentGroups = container.read(lineUpProvider).groups;
      expect(
        currentGroups.first.items.single.ability.visualState.showRangeFill,
        isFalse,
      );
      expect(
        currentGroups.last.items.single.ability.visualState.showRangeFill,
        isTrue,
      );
    });

    testWidgets('stacked lineup square body right-click stays non-interactive',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      final squareRect = tester.getRect(find.byType(CustomSquareWidget).last);
      await tester.tapAt(
        squareRect.topCenter + const Offset(0, 6),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lineup-stack-selector')), findsNothing);
      expect(find.text('Range'), findsNothing);
    });

    testWidgets('closing stack selector clears selector-owned hover preview',
        (tester) async {
      final container = _createLineUpContainer();
      final groups = _stackedLineUpGroups();
      container.read(lineUpProvider.notifier).fromHive(groups);

      await _pumpLineUpAbilities(
        tester,
        container: container,
        groups: groups,
      );

      await tester.tap(find.byType(AbilityWidget).last);
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(
            const ValueKey('lineup-stack-option-group-a-item-a'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(container.read(hoveredLineUpTargetProvider)?.itemId, 'item-a');

      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('lineup-stack-selector')), findsNothing);
      expect(container.read(hoveredLineUpTargetProvider), isNull);
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

ProviderContainer _createLineUpContainer() {
  return ProviderContainer(
    overrides: [
      actionProvider.overrideWith(_TestActionProvider.new),
      mapProvider.overrideWith(_FixedMapProvider.new),
    ],
  );
}

Future<void> _pumpLineUpAbilities(
  WidgetTester tester, {
  required ProviderContainer container,
  required List<LineUpGroup> groups,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  await tester.pumpWidget(
    _buildHarness(
      container: container,
      child: Stack(
        children: [
          for (final group in groups)
            for (final item in group.items)
              LineUpItemAbilityWidget(groupId: group.id, item: item),
        ],
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<LineUpGroup> _stackedLineUpGroups() {
  const sharedPosition = Offset(48, 64);
  return [
    LineUpGroup(
      id: 'group-a',
      agent: PlacedAgent(
        id: 'agent-a',
        type: AgentType.breach,
        position: const Offset(20, 20),
      ),
      items: [
        LineUpItem(
          id: 'item-a',
          ability: PlacedAbility(
            id: 'ability-a',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: sharedPosition,
          ),
        ),
      ],
    ),
    LineUpGroup(
      id: 'group-b',
      agent: PlacedAgent(
        id: 'agent-b',
        type: AgentType.breach,
        position: const Offset(24, 24),
      ),
      items: [
        LineUpItem(
          id: 'item-b',
          ability: PlacedAbility(
            id: 'ability-b',
            data: AgentData.agents[AgentType.breach]!.abilities.first,
            position: sharedPosition,
          ),
        ),
      ],
    ),
  ];
}

AbilityInfo _sectorAbilityInfo() {
  return AbilityInfo(
    name: 'Sector',
    iconPath: 'assets/agents/Cypher/1.webp',
    type: AgentType.cypher,
    index: 0,
    abilityData: SectorCircleAbility(
      iconPath: 'assets/agents/Cypher/1.webp',
      size: 6.5,
      rangeOutlineColor: Colors.cyan,
      sweepAngleDegrees: 75,
    ),
  );
}


