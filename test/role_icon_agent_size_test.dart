import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/utilities.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/widgets/draggable_widgets/shared/framed_icon_shell.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/utility_widget_builder.dart';
import 'package:icarus/widgets/page_transition_overlay.dart';

class _FixedMapProvider extends MapProvider {
  _FixedMapProvider({
    required this.mapValue,
  });

  final MapValue mapValue;

  @override
  MapState build() => MapState(currentMap: mapValue, isAttack: true);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _FixedStrategySettingsProvider extends StrategySettingsProvider {
  _FixedStrategySettingsProvider(this.settings);

  final StrategySettings settings;

  @override
  StrategySettings build() => settings;

  @override
  void fromHive(StrategySettings settings) {}
}

ProviderContainer _createContainer({
  required StrategySettings settings,
  MapValue mapValue = MapValue.bind,
}) {
  final container = ProviderContainer(
    overrides: [
      mapProvider.overrideWith(() => _FixedMapProvider(mapValue: mapValue)),
      strategySettingsProvider
          .overrideWith(() => _FixedStrategySettingsProvider(settings)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ProviderContainer container,
  required Widget child,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Center(child: child),
        ),
      ),
    ),
  );

  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const agentSize = 40.0;
  const abilitySize = 24.0;

  setUp(() {
    CoordinateSystem(playAreaSize: const Size(1920, 1080));
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  group('Role icons sized from agentSize', () {
    test('toolbar drag anchor uses the agent size center point', () {
      final toolData = RoleIconToolData.fromType(
        type: UtilityType.controller,
        agentSize: agentSize,
      );

      expect(toolData.centerPoint, const Offset(agentSize / 2, agentSize / 2));
      expect(toolData.centerPoint.dx, isNot(abilitySize / 2));
      expect(toolData.centerPoint.dy, isNot(abilitySize / 2));
    });

    testWidgets('transition preview renders role icons with agentSize',
        (tester) async {
      final container = _createContainer(
        settings: StrategySettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );

      await _pumpHarness(
        tester,
        container: container,
        child: PlacedWidgetPreview.build(
          PlacedUtility(
            id: 'preview-role-icon',
            type: UtilityType.controller,
            position: Offset.zero,
          ),
          1,
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );

      final framedShell =
          tester.widget<FramedIconShell>(find.byType(FramedIconShell));
      expect(framedShell.size, agentSize);
      expect(framedShell.size, isNot(abilitySize));
    });

    testWidgets('placed utility builder renders role icons with agentSize',
        (tester) async {
      final container = _createContainer(
        settings: StrategySettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );

      final placedUtility = PlacedUtility(
        id: 'placed-role-icon',
        type: UtilityType.controller,
        position: Offset.zero,
      );

      await _pumpHarness(
        tester,
        container: container,
        child: UtilityWidgetBuilder(
          utility: placedUtility,
          onDragEnd: (_) {},
          id: placedUtility.id,
          rotation: placedUtility.rotation,
          length: placedUtility.length,
        ),
      );

      final framedShell =
          tester.widget<FramedIconShell>(find.byType(FramedIconShell));
      expect(framedShell.size, agentSize);
      expect(framedShell.size, isNot(abilitySize));
    });

    test('utility side switching uses the role icon agent footprint', () {
      final container = _createContainer(
        settings: StrategySettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );
      const initialPosition = Offset(100, 200);

      container.read(utilityProvider.notifier).fromHive([
        PlacedUtility(
          id: 'role-icon',
          type: UtilityType.controller,
          position: initialPosition,
        ),
      ]);

      container.read(utilityProvider.notifier).switchSides();

      final flippedUtility = container.read(utilityProvider).single;
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: Offset(
          CoordinateSystem.instance.scale(agentSize),
          CoordinateSystem.instance.scale(agentSize),
        ),
      );

      expect(flippedUtility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(flippedUtility.position.dy, closeTo(expectedPosition.dy, 0.0001));
    });

    test('non-role utilities keep their existing footprint', () {
      final container = _createContainer(
        settings: StrategySettings(
          agentSize: agentSize,
          abilitySize: abilitySize,
        ),
      );
      const initialPosition = Offset(150, 250);

      container.read(utilityProvider.notifier).fromHive([
        PlacedUtility(
          id: 'spike',
          type: UtilityType.spike,
          position: initialPosition,
        ),
      ]);

      container.read(utilityProvider.notifier).switchSides();

      final flippedUtility = container.read(utilityProvider).single;
      final expectedSize = UtilityData.utilityWidgets[UtilityType.spike]!
          .getSize(agentSize: agentSize, abilitySize: abilitySize);
      final expectedPosition = getFlippedPosition(
        position: initialPosition,
        scaledSize: expectedSize.scale(
          CoordinateSystem.instance.scaleFactor,
          CoordinateSystem.instance.scaleFactor,
        ),
      );

      expect(flippedUtility.position.dx, closeTo(expectedPosition.dx, 0.0001));
      expect(flippedUtility.position.dy, closeTo(expectedPosition.dy, 0.0001));
    });
  });
}
