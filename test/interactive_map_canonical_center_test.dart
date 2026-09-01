import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/traversal_speed.dart';
import 'package:icarus/interactive_map.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/pen_provider.dart';
import 'package:icarus/providers/placement_center_provider.dart';
import 'package:icarus/providers/user_preferences_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FixedMapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

class _EmptyDrawingProvider extends DrawingProvider {
  @override
  DrawingState build() => DrawingState(elements: const []);

  @override
  void rebuildAllPaths(CoordinateSystem coordinateSystem) {}
}

class _FixedPenProvider extends PenProvider {
  @override
  PenState build() => PenState(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('side changes refresh the canonical placement center',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1500, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final container = ProviderContainer(
      overrides: [
        mapProvider.overrideWith(_FixedMapProvider.new),
        drawingProvider.overrideWith(_EmptyDrawingProvider.new),
        penProvider.overrideWith(_FixedPenProvider.new),
        effectiveMapThemePaletteProvider.overrideWith(
          (ref) => MapThemeProfilesProvider.immutableDefaultPalette,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
          home: Scaffold(body: InteractiveMap()),
        ),
      ),
    );
    await tester.pump();

    final attackCenter = container.read(placementCenterProvider);
    final coordinates = CoordinateSystem.instance;

    container.read(mapProvider.notifier).switchSide();
    await tester.pump();
    await tester.pump();

    final defenseCenter = container.read(placementCenterProvider);
    expect(
      defenseCenter.dx,
      closeTo(coordinates.worldNormalizedWidth - attackCenter.dx, 0.0001),
    );
    expect(
      defenseCenter.dy,
      closeTo(coordinates.normalizedHeight - attackCenter.dy, 0.0001),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
