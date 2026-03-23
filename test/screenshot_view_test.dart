import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/line_provider.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/providers/ability_provider.dart';
import 'package:icarus/providers/agent_provider.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/image_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/map_theme_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/screenshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_models.dart';
import 'package:icarus/providers/strategy_settings_provider.dart';
import 'package:icarus/providers/text_provider.dart';
import 'package:icarus/providers/utility_provider.dart';
import 'package:icarus/screenshot/screenshot_view.dart';
import 'package:icarus/widgets/drawing_painter.dart';

class _NoopAgentProvider extends AgentProvider {
  @override
  List<PlacedAgentNode> build() => const [];

  @override
  void fromHive(List<PlacedAgentNode> hiveAgents) {}
}

class _NoopAbilityProvider extends AbilityProvider {
  @override
  List<PlacedAbility> build() => const [];

  @override
  void fromHive(List<PlacedAbility> hiveAbilities) {}
}

class _NoopDrawingProvider extends DrawingProvider {
  @override
  DrawingState build() => DrawingState(elements: const []);

  @override
  void fromHive(List<DrawingElement> hiveDrawings) {}

  @override
  void rebuildAllPaths(CoordinateSystem coordinateSystem) {}
}

class _NoopMapProvider extends MapProvider {
  _NoopMapProvider({
    required this.mapValue,
    required this.isAttack,
  });

  final MapValue mapValue;
  final bool isAttack;

  @override
  MapState build() => MapState(currentMap: mapValue, isAttack: isAttack);

  @override
  void fromHive(MapValue map, bool isAttack) {}
}

class _NoopTextProvider extends TextProvider {
  @override
  List<PlacedText> build() => const [];

  @override
  void fromHive(List<PlacedText> hiveText) {}
}

class _NoopPlacedImageProvider extends PlacedImageProvider {
  @override
  ImageState build() => ImageState(images: const []);

  @override
  void fromHive(List<PlacedImage> hiveImages) {}
}

class _NoopStrategyProvider extends StrategyProvider {
  _NoopStrategyProvider(this.initialState);

  final StrategyState initialState;

  @override
  StrategyState build() => initialState;

  @override
  void setFromState(StrategyState newState) {}
}

class _NoopStrategySettingsProvider extends StrategySettingsProvider {
  @override
  StrategySettings build() => StrategySettings();

  @override
  void fromHive(StrategySettings settings) {}
}

class _NoopStrategyThemeProvider extends StrategyThemeProvider {
  @override
  StrategyThemeState build() => const StrategyThemeState();

  @override
  void fromStrategy({
    String? profileId,
    MapThemePalette? overridePalette,
  }) {}
}

class _NoopPenProvider extends PenProvider {
  @override
  PenState build() {
    return PenState(
      listOfColors: const [],
      color: Colors.white,
      hasArrow: false,
      isDotted: false,
      opacity: 1,
      thickness: 1,
      penMode: PenMode.freeDraw,
      traversalTimeEnabled: false,
      activeTraversalSpeedProfile: TraversalSpeedProfile.running,
      drawingCursor: null,
      erasingCursor: null,
    );
  }
}

class _NoopUtilityProvider extends UtilityProvider {
  @override
  List<PlacedUtility> build() => const [];

  @override
  void fromHive(List<PlacedUtility> hiveUtilities) {}
}

class _NoopScreenshotProvider extends ScreenshotProvider {
  @override
  bool build() => false;

  @override
  setIsScreenShot(bool isScreenshot) {}
}

class _NoopLineUpProvider extends LineUpProvider {
  @override
  LineUpState build() => LineUpState(lineUps: const []);

  @override
  void fromHive(List<LineUp> lineUps) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CoordinateSystem(playAreaSize: CoordinateSystem.screenShotSize);
    CoordinateSystem.instance.setIsScreenshot(false);
  });

  Widget buildHarness({required bool isAttack}) {
    final strategyState = StrategyState(
      isSaved: true,
      stratName: 'test strategy',
      id: 'strategy-id',
      storageDirectory: null,
      activePageId: 'page-1',
    );

    return ProviderScope(
      overrides: [
        strategyProvider
            .overrideWith(() => _NoopStrategyProvider(strategyState)),
        agentProvider.overrideWith(_NoopAgentProvider.new),
        screenshotProvider.overrideWith(_NoopScreenshotProvider.new),
        abilityProvider.overrideWith(_NoopAbilityProvider.new),
        drawingProvider.overrideWith(_NoopDrawingProvider.new),
        mapProvider.overrideWith(
          () => _NoopMapProvider(mapValue: MapValue.bind, isAttack: isAttack),
        ),
        textProvider.overrideWith(_NoopTextProvider.new),
        placedImageProvider.overrideWith(_NoopPlacedImageProvider.new),
        strategySettingsProvider
            .overrideWith(_NoopStrategySettingsProvider.new),
        strategyThemeProvider.overrideWith(_NoopStrategyThemeProvider.new),
        penProvider.overrideWith(_NoopPenProvider.new),
        utilityProvider.overrideWith(_NoopUtilityProvider.new),
        lineUpProvider.overrideWith(_NoopLineUpProvider.new),
        effectiveMapThemePaletteProvider.overrideWith(
          (ref) => MapThemeProfilesProvider.immutableDefaultPalette,
        ),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: CoordinateSystem.screenShotSize),
          child: ScreenshotView(
            mapValue: MapValue.bind,
            agents: const [],
            abilities: const [],
            text: const [],
            images: const [],
            drawings: const [],
            utilities: const [],
            strategySettings: StrategySettings(),
            isAttack: isAttack,
            strategyState: strategyState,
            lineUps: const <LineUp>[],
            themeProfileId: null,
            themeOverridePalette: null,
          ),
        ),
      ),
    );
  }

  Transform findPainterTransform(WidgetTester tester) {
    final transformFinder = find.ancestor(
      of: find.byType(InteractivePainter),
      matching: find.byType(Transform),
    );

    expect(transformFinder, findsOneWidget);
    return tester.widget<Transform>(transformFinder);
  }

  testWidgets('defense screenshots flip the painter layer', (tester) async {
    await tester.pumpWidget(buildHarness(isAttack: false));
    await tester.pumpAndSettle();

    final transform = findPainterTransform(tester);

    expect(transform.transform.storage[0], -1);
    expect(transform.transform.storage[5], -1);
  });

  testWidgets('attack screenshots keep the painter layer unflipped',
      (tester) async {
    await tester.pumpWidget(buildHarness(isAttack: true));
    await tester.pumpAndSettle();

    final transform = findPainterTransform(tester);

    expect(transform.transform.storage[0], 1);
    expect(transform.transform.storage[5], 1);
  });
}
