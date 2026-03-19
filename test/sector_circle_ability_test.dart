import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/abilities.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/widgets/draggable_widgets/ability/ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/placed_ability_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/rotatable_widget.dart';
import 'package:icarus/widgets/draggable_widgets/ability/sector_circle_widget.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
  });

  group('SectorCircleAbility geometry', () {
    test('matches CircleAbility width and adds handle headroom on top', () {
      const mapScale = 1.3;
      const abilitySize = 40.0;
      final circle = CircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 6.5,
        rangeOutlineColor: Colors.cyan,
      );
      final sector = SectorCircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 6.5,
        rangeOutlineColor: Colors.cyan,
        sweepAngleDegrees: 75,
      );

      final circleAnchor =
          circle.getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);
      final sectorAnchor =
          sector.getAnchorPoint(mapScale: mapScale, abilitySize: abilitySize);
      final circleSize =
          circle.getSize(mapScale: mapScale, abilitySize: abilitySize);
      final sectorSize =
          sector.getSize(mapScale: mapScale, abilitySize: abilitySize);

      expect(sectorAnchor.dx, circleAnchor.dx);
      expect(
        sectorAnchor.dy,
        circleAnchor.dy + SectorCircleWidget.handleTopInsetVirtual,
      );
      expect(sectorSize.dx, circleSize.dx);
      expect(
        sectorSize.dy,
        circleSize.dy + SectorCircleWidget.handleTopInsetVirtual,
      );
    });

    test('is rotatable', () {
      final sector = SectorCircleAbility(
        iconPath: 'assets/agents/Cypher/1.webp',
        size: 6.5,
        rangeOutlineColor: Colors.cyan,
        sweepAngleDegrees: 75,
      );

      expect(isRotatable(sector), isTrue);
    });

    test('switchSides mirrors position, rotates, and leaves length intact', () {
      const mapScale = 1.1;
      const abilitySize = 42.0;
      final abilityInfo = AbilityInfo(
        name: 'Sector',
        iconPath: 'assets/agents/Cypher/1.webp',
        type: AgentType.cypher,
        index: 99,
        abilityData: SectorCircleAbility(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 6.5,
          rangeOutlineColor: Colors.cyan,
          sweepAngleDegrees: 75,
        ),
      );
      const initialPosition = Offset(120, 245);
      const initialRotation = 0.8;
      const initialLength = 17.0;

      final placedAbility = PlacedAbility(
        id: 'sector-switch',
        data: abilityInfo,
        position: initialPosition,
        rotation: initialRotation,
        length: initialLength,
      );

      final fullSize = abilityInfo.abilityData!
          .getSize(mapScale: mapScale, abilitySize: abilitySize)
          .scale(
            CoordinateSystem.instance.scaleFactor,
            CoordinateSystem.instance.scaleFactor,
          );
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: fullSize,
        isRotatable: true,
      );

      placedAbility.switchSides(mapScale: mapScale, abilitySize: abilitySize);

      expect(placedAbility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(placedAbility.position.dy, closeTo(expectedPosition.dy, 0.0001));
      expect(
          placedAbility.rotation, closeTo(initialRotation + math.pi, 0.0001));
      expect(placedAbility.length, initialLength);
    });
  });

  group('SectorCircleWidget styling', () {
    testWidgets('matches no-center-dot circle fill and stroke values',
        (tester) async {
      const outlineColor = Colors.orange;
      final expectedStrokeWidth = CoordinateSystem.instance.scale(5);

      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: outlineColor,
          sweepAngleDegrees: 80,
          hasCenterDot: false,
          opacity: 70,
          id: 'sector-style',
          isAlly: true,
        ),
      );

      final painter = _sectorPainter(tester);

      expect(painter.fillColor, outlineColor.withAlpha(70));
      expect(painter.strokeColor, outlineColor);
      expect(painter.strokeWidth, expectedStrokeWidth);
    });

    testWidgets('matches perimeter circle styling values', (tester) async {
      const outlineColor = Colors.white;
      const fillColor = Colors.deepPurple;
      final expectedStrokeWidth = CoordinateSystem.instance.scale(2);

      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: outlineColor,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          opacity: 45,
          innerRangeSize: 36,
          innerRangeColor: fillColor,
          id: 'sector-perimeter',
          isAlly: true,
        ),
      );

      final painter = _sectorPainter(tester);

      expect(painter.fillColor, isNull);
      expect(painter.strokeColor, outlineColor.withAlpha(100));
      expect(painter.strokeWidth, expectedStrokeWidth);
      expect(
        find.byWidgetPredicate((widget) {
          if (widget is! Container) {
            return false;
          }
          final decoration = widget.decoration;
          return decoration is BoxDecoration &&
              decoration.shape == BoxShape.circle &&
              decoration.color == fillColor.withAlpha(45);
        }),
        findsOneWidget,
      );
    });

    testWidgets('counter-rotates the ability icon', (tester) async {
      const rotation = math.pi / 5;

      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: Colors.orange,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          id: 'sector-rotated',
          isAlly: true,
          rotation: rotation,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: -rotation),
        findsOneWidget,
      );
    });

    testWidgets('zero rotation leaves the icon transform neutral',
        (tester) async {
      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: Colors.orange,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          id: 'sector-zero-rotation',
          isAlly: true,
          rotation: 0,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: 0),
        findsOneWidget,
      );
    });

    testWidgets('no center dot omits the ability icon', (tester) async {
      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: Colors.orange,
          sweepAngleDegrees: 80,
          hasCenterDot: false,
          id: 'sector-no-center-dot',
          isAlly: true,
          rotation: math.pi / 4,
        ),
      );

      expect(find.byType(AbilityWidget), findsNothing);
    });

    testWidgets('visibility can hide the sector fill while keeping stroke',
        (tester) async {
      const outlineColor = Colors.orange;
      final expectedStrokeWidth = CoordinateSystem.instance.scale(2);

      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: outlineColor,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          id: 'sector-hide-fill',
          isAlly: true,
          visualState: AbilityVisualState(
            showRangeFill: false,
          ),
        ),
      );

      final painter = _sectorPainter(tester);

      expect(painter.fillColor, isNull);
      expect(painter.strokeColor, outlineColor);
      expect(painter.strokeWidth, expectedStrokeWidth);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('visibility can hide the sector stroke while keeping fill',
        (tester) async {
      const outlineColor = Colors.orange;

      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: outlineColor,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          opacity: 55,
          id: 'sector-hide-stroke',
          isAlly: true,
          visualState: AbilityVisualState(
            showRangeOutline: false,
          ),
        ),
      );

      final painter = _sectorPainter(tester);

      expect(painter.fillColor, outlineColor.withAlpha(55));
      expect(painter.strokeColor, Colors.transparent);
      expect(painter.strokeWidth, 0);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('visibility can hide sector body and perimeter together',
        (tester) async {
      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: Colors.orange,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          id: 'sector-icon-only',
          isAlly: true,
          visualState: AbilityVisualState(
            showRangeFill: false,
            showRangeOutline: false,
          ),
        ),
      );

      final painter = _sectorPainter(tester);

      expect(painter.fillColor, isNull);
      expect(painter.strokeColor, Colors.transparent);
      expect(painter.strokeWidth, 0);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('perimeter mode hides the inner circle when range body is off',
        (tester) async {
      await _pumpWidget(
        tester,
        const SectorCircleWidget(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 120,
          rangeOutlineColor: Colors.white,
          sweepAngleDegrees: 80,
          hasCenterDot: true,
          innerRangeSize: 36,
          innerRangeColor: Colors.deepPurple,
          id: 'sector-perimeter-hidden-fill',
          isAlly: true,
          visualState: AbilityVisualState(
            showInnerFill: false,
          ),
        ),
      );

      final sizeLayer = tester.widget<Opacity>(
        find.byKey(const ValueKey('sector-inner-fill-layer')),
      );
      final painter = _sectorPainter(tester);

      expect(sizeLayer.opacity, 0);
      expect(painter.strokeWidth, CoordinateSystem.instance.scale(2));
      expect(find.byType(AbilityWidget), findsOneWidget);
    });
  });

  group('SectorCircleAbility integration', () {
    testWidgets('PlacedAbilityWidget uses the shared rotatable shell',
        (tester) async {
      final abilityInfo = AbilityInfo(
        name: 'Sector',
        iconPath: 'assets/agents/Cypher/1.webp',
        type: AgentType.cypher,
        index: 98,
        abilityData: SectorCircleAbility(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 6.5,
          rangeOutlineColor: Colors.cyan,
          sweepAngleDegrees: 75,
        ),
      );
      final placedAbility = PlacedAbility(
        id: 'sector-placed',
        data: abilityInfo,
        position: const Offset(100, 100),
      );

      final container = ProviderContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      container.read(abilityProvider.notifier).fromHive([placedAbility]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
              body: _PlacedSectorAbilityHarness(),
            ),
          ),
        ),
      );

      await tester.pump();

      expect(find.byType(RotatableWidget), findsOneWidget);
      expect(find.byType(SectorCircleWidget), findsOneWidget);

      final rotatable =
          tester.widget<RotatableWidget>(find.byType(RotatableWidget));
      final expectedOrigin = abilityInfo.abilityData!.getAnchorPoint(
        mapScale: 1,
        abilitySize: container.read(strategySettingsProvider).abilitySize,
      );
      expect(rotatable.origin, expectedOrigin);
      expect(rotatable.buttonTop, isNull);
    });

    testWidgets('icon-only sector hides the rotation handle',
        (tester) async {
      final abilityInfo = AbilityInfo(
        name: 'Sector',
        iconPath: 'assets/agents/Cypher/1.webp',
        type: AgentType.cypher,
        index: 95,
        abilityData: SectorCircleAbility(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 6.5,
          rangeOutlineColor: Colors.cyan,
          sweepAngleDegrees: 75,
        ),
      );
      final placedAbility = PlacedAbility(
        id: 'sector-handle-hidden',
        data: abilityInfo,
        position: const Offset(100, 100),
        visualState: const AbilityVisualState(
          showRangeFill: false,
          showRangeOutline: false,
        ),
      );

      final container = ProviderContainer();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        container.dispose();
      });
      container.read(abilityProvider.notifier).fromHive([placedAbility]);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ShadApp(
            home: Scaffold(
              body: _PlacedSectorAbilityHarness(),
            ),
          ),
        ),
      );

      await tester.pump();

      final rotatable =
          tester.widget<RotatableWidget>(find.byType(RotatableWidget));

      expect(rotatable.showHandle, isFalse);
      expect(find.byType(AbilityWidget), findsOneWidget);
    });

    testWidgets('PlacedWidgetPreview builds the sector widget', (tester) async {
      final abilityInfo = AbilityInfo(
        name: 'Sector',
        iconPath: 'assets/agents/Cypher/1.webp',
        type: AgentType.cypher,
        index: 97,
        abilityData: SectorCircleAbility(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 6.5,
          rangeOutlineColor: Colors.cyan,
          sweepAngleDegrees: 75,
        ),
      );
      final placedAbility = PlacedAbility(
        id: 'sector-preview',
        data: abilityInfo,
        position: const Offset(0, 0),
      );

      await _pumpWidget(
        tester,
        PlacedWidgetPreview.build(
          placedAbility,
          1,
          agentSize: 40,
          abilitySize: 24,
        ),
      );

      expect(find.byType(SectorCircleWidget), findsOneWidget);
    });

    testWidgets(
        'PlacedWidgetPreview forwards rotation for icon counter-rotation',
        (tester) async {
      const rotation = math.pi / 7;
      final abilityInfo = AbilityInfo(
        name: 'Sector',
        iconPath: 'assets/agents/Cypher/1.webp',
        type: AgentType.cypher,
        index: 96,
        abilityData: SectorCircleAbility(
          iconPath: 'assets/agents/Cypher/1.webp',
          size: 6.5,
          rangeOutlineColor: Colors.cyan,
          sweepAngleDegrees: 75,
        ),
      );
      final placedAbility = PlacedAbility(
        id: 'sector-preview-rotation',
        data: abilityInfo,
        position: const Offset(0, 0),
        rotation: rotation,
      );

      await _pumpWidget(
        tester,
        PlacedWidgetPreview.build(
          placedAbility,
          1,
          rotation: rotation,
          agentSize: 40,
          abilitySize: 24,
        ),
      );

      expect(
        _findAbilityTransformByAngle(tester, expectedAngle: -rotation),
        findsOneWidget,
      );
    });
  });
}

class _PlacedSectorAbilityHarness extends ConsumerWidget {
  const _PlacedSectorAbilityHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ability = ref.watch(abilityProvider).single;
    return Stack(
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
    );
  }
}

Future<void> _pumpWidget(WidgetTester tester, Widget child) async {
  final container = ProviderContainer();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ShadApp(
        home: Scaffold(
          body: Center(child: child),
        ),
      ),
    ),
  );

  await tester.pump();
}

Finder _findAbilityTransformByAngle(
  WidgetTester tester, {
  required double expectedAngle,
}) {
  return find.byWidgetPredicate((widget) {
    if (widget is! Transform) {
      return false;
    }

    final element = tester.element(find.byWidget(widget));
    final hasAbilityWidgetDescendant = find
        .descendant(
          of: find.byElementPredicate((candidate) => candidate == element),
          matching: find.byType(AbilityWidget),
        )
        .evaluate()
        .isNotEmpty;

    if (!hasAbilityWidgetDescendant) {
      return false;
    }

    final matrix = widget.transform;
    final angle = math.atan2(matrix.entry(1, 0), matrix.entry(0, 0));
    return (angle - expectedAngle).abs() < 0.0001;
  });
}

SectorCirclePainter _sectorPainter(WidgetTester tester) {
  final customPaint = tester.widget<CustomPaint>(
    find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint && widget.painter is SectorCirclePainter,
    ),
  );

  return customPaint.painter! as SectorCirclePainter;
}


