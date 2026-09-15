// Review external or bundled models with the production painter.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

const _revision = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const _dll =
    'C:/Users/shawn/AppData/Local/Temp/icarus-svg-height-native-build/Release/icarus_height.dll';

void main() {
  testWidgets('map model uses production SVG-height painter',
      (tester) async {
    final completed = await tester.runAsync(() async {
      final name = Platform.environment['ICARUS_REVIEW_MAP']!;
      final map = MapValue.values.byName(name);
      final directory = Platform.environment['ICARUS_REVIEW_MODELS'] ??
          '$_revision/all-map-svg-height-reviewed-v1';
      final output = Directory(Platform.environment['ICARUS_REVIEW_OUTPUT']!);
      if (output.existsSync()) throw StateError('Choose a fresh review output');
      output.createSync(recursive: true);
      SvgHeightVisibility load(String side) => SvgHeightVisibility.fromJson(
          jsonDecode(File('$directory/$name-$side.json').readAsStringSync())
              as Map<String, dynamic>);
      final bundled = Platform.environment['ICARUS_REVIEW_BUNDLED'] == '1';
      final container = ProviderContainer();
      final subscription = bundled
          ? container.listen(svgHeightRuntimeProvider(map), (_, __) {})
          : null;
      final runtime = bundled
          ? (await container.read(svgHeightRuntimeProvider(map).future))!
          : SvgHeightRuntime.forMap(map, load('attack'), load('defense'));
      for (final model in [runtime.attack, runtime.defense]) {
        if (!model.enableNativeAcceleration(
            libraryPath:
                Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'] ?? _dll))
          throw StateError('Native library unavailable');
      }
      final fixture = jsonDecode(
          File('$_revision/all-map-svg-frame-fixtures-v1/$name.json')
              .readAsStringSync()) as Map<String, dynamic>;
      final frame = (fixture['frames'] as List).first as Map<String, dynamic>;
      const size = Size(1920, 1080);
      final coord = CoordinateSystem(playAreaSize: size)..setIsScreenshot(true);
      final transform = SvgHeightMapTransform.forMap(map);
      await tester.binding.setSurfaceSize(size);
      final records = <Map<String, dynamic>>[];
      try {
        for (final attack in [true, false]) {
          final cones = <Widget>[];
          final markers = <Widget>[];
          for (var index = 0; index < 10; index++) {
            final xy = (frame['positionsSvg'] as List)[index] as List;
            final direction = (frame['directionsSvg'] as List)[index] as num;
            final canonical = transform.sideWorldFromSource(
                Offset((xy[0] as num).toDouble(), (xy[1] as num).toDouble()),
                isAttack: true);
            final side = coord.positionForSide(
                canonicalPosition: canonical,
                reflectionOffset: Offset.zero,
                isAttack: attack);
            final screen = coord.coordinateToScreen(side);
            final rotation = coord.rotationForSide(
                direction.toDouble() + math.pi / 2,
                isAttack: attack);
            final pose = (frame['poses'] as List)[index] as List;
            final range = (pose[5] as num).toDouble() *
                (fixture['metersToSvg'] as num).toDouble() *
                transform.scale;
            final radius = coord.worldHeightToScreen(range);
            final apex = Offset(radius, radius);
            cones.add(Positioned(
                left: screen.dx - radius,
                top: screen.dy - radius,
                child: Transform.rotate(
                    angle: rotation,
                    alignment: Alignment.topLeft,
                    origin: apex,
                    child: SvgHeightViewCone(
                        runtime: runtime,
                        canonicalOrigin: canonical,
                        rotation: rotation,
                        range: range,
                        angle: math.pi / 2,
                        isAttack: attack))));
            markers.add(Positioned(
                left: screen.dx - 7,
                top: screen.dy - 7,
                child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                        color: Colors.tealAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1)))));
          }
          final key = GlobalKey();
          await tester.pumpWidget(MaterialApp(
              home: Align(
                  alignment: Alignment.topLeft,
                  child: RepaintBoundary(
                      key: key,
                      child: SizedBox.fromSize(
                          size: size,
                          child: ColoredBox(
                              color: Settings.tacticalVioletTheme.background,
                              child: Stack(children: [
                                Positioned(
                                    left: (size.width -
                                            size.height *
                                                CoordinateSystem
                                                    .defaultMapAspectRatio) /
                                        2,
                                    top: 0,
                                    width: size.height *
                                        CoordinateSystem.defaultMapAspectRatio,
                                    height: size.height,
                                    child: CanonicalMapArtwork(
                                        map: map,
                                        isAttack: attack,
                                        child: SvgPicture.asset(
                                            'assets/maps/${name}_map${attack ? '' : '_defense'}.svg',
                                            fit: BoxFit.contain))),
                                ...cones,
                                ...markers
                              ])))))));
          await tester.pumpAndSettle();
          expect(find.byType(SvgHeightViewCone), findsNWidgets(10));
          expect(runtime.cache(attack).observerCount, 10,
              reason: 'Every fixture origin must produce a cone');
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final sideName = attack ? 'attack' : 'defense';
          final scale = math.min(
              size.height *
                  CoordinateSystem.defaultMapAspectRatio /
                  transform.viewBox.width,
              size.height / transform.viewBox.height);
          for (final entry in {'full': 1.0, 'native8x': 8 / scale}.entries) {
            final raster = await boundary.toImage(pixelRatio: entry.value);
            final bytes =
                await raster.toByteData(format: ui.ImageByteFormat.png);
            await File('${output.path}/$name-$sideName-${entry.key}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            raster.dispose();
          }
          records.add({
            'side': sideName,
            'observers': runtime.cache(attack).observerCount,
            'queries': runtime.cache(attack).queryCount
          });
          await tester.pumpWidget(const SizedBox());
        }
        await File('${output.path}/manifest.json').writeAsString(jsonEncode({
          'map': name,
          'scope':
              '${bundled ? 'Bundled production provider' : 'External reviewed models'}, production SvgHeightViewCone and CanonicalMapArtwork. No library access. Ten deterministic stress poses; not complete gameplay certification.',
          'records': records
        }));
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!bundled) runtime.dispose();
        subscription?.close();
        container.dispose();
        await tester.binding.setSurfaceSize(null);
      }
      return true;
    });
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
