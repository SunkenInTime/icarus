import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/view_cone_geometry_provider.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _MapProvider extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.ascent, isAttack: true);
}

SvgHeightRuntime _runtime() {
  final model = SvgHeightVisibility.fromJson({
    'version': 1,
    'coordinateSpace': 'svg',
    'verticalSpace': 'meters-above-local-floor',
    'walls': [],
    'supports': [],
    'receiver': [
      {
        'rings': [
          [-100, -100, 600, -100, 600, 600, -100, 600]
        ],
        'fillRule': 'evenodd',
      }
    ],
  });
  return SplitSvgHeightRuntime.forMap(MapValue.ascent, model, model);
}

void main() {
  for (final fails in [false, true]) {
    testWidgets(
        'SVG sightlines stay hidden while loading${fails ? ' and after an error' : ', then appear when ready'}',
        (tester) async {
      CoordinateSystem(playAreaSize: const Size(1920, 1080));
      final completion = Completer<SvgHeightRuntime?>();
      var legacyLoads = 0;
      final container = ProviderContainer(
        overrides: [
          mapProvider.overrideWith(_MapProvider.new),
          worldGeometryEnabledProvider.overrideWith((ref, map) => true),
          svgHeightRuntimeProvider
              .overrideWith((ref, map) => completion.future),
          viewConeGeometryProvider.overrideWith((ref, map) async {
            legacyLoads++;
            return null;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const ShadApp(
            home: Scaffold(
                body: ViewConeWidget(
                    id: null,
                    angle: 90,
                    length: 60,
                    worldOrigin: Offset(500, 500)))),
      ));
      ViewConePainter painter() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter)
          .whereType<ViewConePainter>()
          .single;
      expect(painter().visibilityPolygon, hasLength(1));
      expect(find.byType(SvgHeightViewCone), findsNothing);
      expect(legacyLoads, 0);
      final eye = find.byWidgetPredicate((widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName == 'assets/eye.webp');
      expect(eye, findsOneWidget);
      if (fails) {
        completion
            .completeError(const FormatException('Invalid world test asset'));
      } else {
        completion.complete(_runtime());
      }
      await tester.pump();
      await tester.pump();
      if (fails) {
        expect(painter().visibilityPolygon, hasLength(1));
      } else {
        expect(
            tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .whereType<ViewConePainter>(),
            isEmpty);
      }
      expect(find.byType(SvgHeightViewCone),
          fails ? findsNothing : findsOneWidget);
      expect(
          find.byWidgetPredicate((widget) =>
              widget is CustomPaint &&
              widget.painter is SvgHeightViewConePainter),
          fails ? findsNothing : findsOneWidget);
      expect(legacyLoads, 0);
      expect(eye, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
    });
  }
}
