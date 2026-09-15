// Frozen Split replay through the production SVG-height widget path. No Hive
// or user library is opened.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/map_provider.dart';
import 'package:icarus/providers/svg_height_runtime_provider.dart';
import 'package:icarus/providers/world_geometry_source_provider.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';
import 'package:image/image.dart' as image;

const _revision = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const _fixturePath = 'E:/IcarusWorldAudit/2026-09-06/compact-prototype/'
    'native-walking-fixtures-v1/split/walking-144hz.json';
const _nativeLibrary =
    'C:/Users/shawn/AppData/Local/Temp/icarus-svg-height-native-build/'
    'Release/icarus_height.dll';
const _sceneSize = Size(1920, 1080);

class _SplitMap extends MapProvider {
  @override
  MapState build() => MapState(currentMap: MapValue.split, isAttack: true);
}

Future<String> _digest(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((value) => value.toRadixString(16).padLeft(2, '0'))
    .join();

class _Scene extends StatelessWidget {
  const _Scene({
    required this.frame,
    required this.isAttack,
    required this.boundary,
  });

  final Map<String, dynamic> frame;
  final bool isAttack;
  final GlobalKey boundary;

  @override
  Widget build(BuildContext context) {
    final coordinates = CoordinateSystem.instance;
    final cones = <Widget>[];
    final icons = <Widget>[];
    for (var index = 0; index < 10; index++) {
      final point = (frame['positionsSvg'] as List<dynamic>)[index] as List;
      final pose = (frame['poses'] as List<dynamic>)[index] as List;
      final source = Offset(
        (point[0] as num).toDouble(),
        (point[1] as num).toDouble(),
      );
      final canonicalWorld =
          SplitSvgMapTransform.sideWorldFromSource(source, isAttack: true);
      final sideWorld = coordinates.positionForSide(
        canonicalPosition: canonicalWorld,
        reflectionOffset: Offset.zero,
        isAttack: isAttack,
      );
      final canonicalDirection = math.atan2(
        -(pose[4] as num).toDouble(),
        (pose[3] as num).toDouble(),
      );
      final canonicalRotation = canonicalDirection + math.pi / 2;
      final sideRotation = coordinates.rotationForSide(
        canonicalRotation,
        isAttack: isAttack,
      );
      final sourceRange = (pose[5] as num).toDouble() * 3.9096202760784;
      final worldRange = sourceRange * SplitSvgMapTransform.scale;
      final length = worldRange / coordinates.virtualLengthToWorld(1);
      final anchor =
          ViewConeWidget.anchorPointVirtual * coordinates.scaleFactor;
      final screen = coordinates.coordinateToScreen(sideWorld);
      cones.add(Positioned(
        key: ValueKey('cone-position-$index'),
        left: screen.dx - anchor.dx,
        top: screen.dy - anchor.dy,
        child: Transform.rotate(
          angle: sideRotation,
          alignment: Alignment.topLeft,
          origin: anchor,
          child: ViewConeWidget(
            key: ValueKey('cone-$index'),
            id: null,
            worldOrigin: canonicalWorld,
            angle: (pose[6] as num).toDouble() * 180 / math.pi,
            rotation: sideRotation,
            length: length,
            showCenterMarker: false,
          ),
        ),
      ));
      final iconSize = coordinates.scale(Settings.agentSize);
      icons.add(Positioned(
        key: ValueKey('agent-position-$index'),
        left: screen.dx - iconSize / 2,
        top: screen.dy - iconSize / 2,
        child: AgentWidget(
          key: ValueKey('agent-$index'),
          agent: AgentData.agents[AgentType.values[index]]!,
          id: null,
          isAlly: true,
          isInteractive: false,
        ),
      ));
    }
    return MaterialApp(
      home: ColoredBox(
        color: Settings.tacticalVioletTheme.background,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox.fromSize(
              size: _sceneSize,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned(
                    left: (_sceneSize.width -
                            _sceneSize.height *
                                CoordinateSystem.defaultMapAspectRatio) /
                        2,
                    top: 0,
                    width: _sceneSize.height *
                        CoordinateSystem.defaultMapAspectRatio,
                    height: _sceneSize.height,
                    child: CanonicalMapArtwork(
                      map: MapValue.split,
                      isAttack: isAttack,
                      child: SvgPicture.asset(
                        'assets/maps/split_map${isAttack ? '' : '_defense'}.svg',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  ...cones,
                  ...icons,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('render frozen Split through the production SVG-height widgets',
      (tester) async {
    final completed = await tester.runAsync(() async {
      final output = Directory(
        Platform.environment['ICARUS_SPLIT_SVG_APP_OUTPUT'] ??
            '$_revision/split-svg-app-preview-v1',
      );
      if (output.existsSync()) {
        throw StateError('Preserve prior app preview; use a fresh folder.');
      }
      output.createSync(recursive: true);
      final fixtureBytes = await File(_fixturePath).readAsBytes();
      final fixture =
          jsonDecode(utf8.decode(fixtureBytes)) as Map<String, dynamic>;
      if (fixture['map'] != 'split' || fixture['agentCount'] != 10) {
        throw const FormatException(
            'Expected the frozen ten-agent Split fixture.');
      }
      final frame =
          (fixture['frames'] as List<dynamic>).first as Map<String, dynamic>;
      if (frame['frame'] != 0) {
        throw const FormatException('Expected frozen frame zero.');
      }
      final dll = File(_nativeLibrary);
      if (!dll.existsSync()) throw StateError('Missing $_nativeLibrary');

      CoordinateSystem(playAreaSize: _sceneSize).setIsScreenshot(true);
      await tester.binding.setSurfaceSize(_sceneSize);
      final container = ProviderContainer(overrides: [
        mapProvider.overrideWith(_SplitMap.new),
        worldGeometryEnabledProvider.overrideWith((ref, map) => true),
      ]);
      final subscription = container.listen(
          svgHeightRuntimeProvider(MapValue.split), (_, __) {});
      final runtime =
          await container.read(svgHeightRuntimeProvider(MapValue.split).future);
      if (runtime == null) throw StateError('Split SVG runtime did not load.');
      for (final model in [runtime.attack, runtime.defense]) {
        final enabled = model.usesNativeAcceleration ||
            model.enableNativeAcceleration(libraryPath: _nativeLibrary);
        if (!enabled || !model.usesNativeAcceleration) {
          throw StateError('The explicit SVG-height native DLL did not load.');
        }
      }

      // Image.asset decoding can outlive pumpAndSettle in flutter_tester. Seed
      // the same paths AgentWidget uses before either side is captured so the
      // first side retains the original portraits as well as their frames.
      final preloadKey = GlobalKey();
      await tester.pumpWidget(MaterialApp(home: SizedBox(key: preloadKey)));
      await Future.wait([
        for (var index = 0; index < 10; index++)
          precacheImage(
            AssetImage(AgentData.agents[AgentType.values[index]]!.iconPath),
            preloadKey.currentContext!,
          ),
      ]);

      final viewBox = Maps.mapViewBox[MapValue.split]!;
      final mapViewport = Size(
        _sceneSize.height * CoordinateSystem.defaultMapAspectRatio,
        _sceneSize.height,
      );
      final svgScreenScale = math.min(
        mapViewport.width / viewBox.width,
        mapViewport.height / viewBox.height,
      );
      final nativePixelRatio = 8 / svgScreenScale;
      final records = <Map<String, dynamic>>[];
      try {
        for (final isAttack in [true, false]) {
          container.read(mapProvider.notifier).setAttack(isAttack);
          final boundary = GlobalKey();
          await tester.pumpWidget(UncontrolledProviderScope(
            container: container,
            child: _Scene(
              frame: frame,
              isAttack: isAttack,
              boundary: boundary,
            ),
          ));
          await tester.pumpAndSettle();
          expect(find.byType(ViewConeWidget), findsNWidgets(10));
          expect(find.byType(SvgHeightViewCone), findsNWidgets(10));
          expect(find.byType(AgentWidget), findsNWidgets(10));
          final cache = runtime.cache(isAttack);
          expect(cache.observerCount, 10);
          final renderBoundary = boundary.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
          final side = isAttack ? 'attack' : 'defense';
          final full = await _capture(renderBoundary, 1);
          final fullPath = '${output.path}/split-$side-full1920x1080.png';
          await File(fullPath).writeAsBytes(full);
          final native = await _capture(renderBoundary, nativePixelRatio);
          final nativePath = '${output.path}/split-$side-native8x.png';
          await File(nativePath).writeAsBytes(native);
          final decoded = image.decodePng(native);
          if (decoded == null) throw StateError('Could not decode $nativePath');
          final model = runtime.model(isAttack);
          final cropRecords = <Map<String, dynamic>>[];
          for (var index = 0; index < 10; index++) {
            final point =
                (frame['positionsSvg'] as List<dynamic>)[index] as List;
            final pose = (frame['poses'] as List<dynamic>)[index] as List;
            final attackSource = Offset(
              (point[0] as num).toDouble(),
              (point[1] as num).toDouble(),
            );
            final canonicalWorld = SplitSvgMapTransform.sideWorldFromSource(
              attackSource,
              isAttack: true,
            );
            final sideWorld = CoordinateSystem.instance.positionForSide(
              canonicalPosition: canonicalWorld,
              reflectionOffset: Offset.zero,
              isAttack: isAttack,
            );
            final sourceOrigin = SplitSvgMapTransform.sourceFromSideWorld(
              sideWorld,
              isAttack: isAttack,
            );
            final canonicalDirection = math.atan2(
              -(pose[4] as num).toDouble(),
              (pose[3] as num).toDouble(),
            );
            final direction = canonicalDirection + (isAttack ? 0 : math.pi);
            final sourceRange = (pose[5] as num).toDouble() * 3.9096202760784;
            final hit = model.castRay(
              origin: sourceOrigin,
              directionRadians: direction,
              range: sourceRange,
            );
            final focusSource = hit?.point ?? sourceOrigin;
            final focusWorld = SplitSvgMapTransform.sideWorldFromSource(
              focusSource,
              isAttack: isAttack,
            );
            final focusScreen =
                CoordinateSystem.instance.coordinateToScreen(focusWorld);
            final centerX = (focusScreen.dx * nativePixelRatio).round();
            final centerY = (focusScreen.dy * nativePixelRatio).round();
            final left = (centerX - 300).clamp(0, decoded.width - 600);
            final top = (centerY - 300).clamp(0, decoded.height - 600);
            final crop = image.copyCrop(
              decoded,
              x: left,
              y: top,
              width: 600,
              height: 600,
            );
            final cropBytes = Uint8List.fromList(image.encodePng(crop));
            final cropPath =
                '${output.path}/split-$side-agent$index-contact-native8x-crop600.png';
            await File(cropPath).writeAsBytes(cropBytes);
            cropRecords.add({
              'agentIndex': index,
              'image': cropPath,
              'sha256': await _digest(cropBytes),
              'cropPixels': [left, top, 600, 600],
              'focus':
                  hit == null ? 'origin-no-central-hit' : 'central-ray-hit',
              'sourceOrigin': [sourceOrigin.dx, sourceOrigin.dy],
              'sourceFocus': [focusSource.dx, focusSource.dy],
              'wallId': hit?.wallId,
              'distanceSvg': hit?.distance,
            });
          }
          records.add({
            'side': side,
            'fullImage': fullPath,
            'fullImageSha256': await _digest(full),
            'fullPixels': [1920, 1080],
            'native8xImage': nativePath,
            'native8xImageSha256': await _digest(native),
            'native8xPixels': [decoded.width, decoded.height],
            'native8xPixelRatio': nativePixelRatio,
            'computedCones': cache.queryCount,
            'nativeQueryMicroseconds': cache.totalNativeQueryMicroseconds,
            'crops': cropRecords,
          });
          await tester.pumpWidget(const SizedBox());
        }
        await File('${output.path}/manifest.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'scope':
                'Frozen frame0 rendered with bundled Split v18 gzip assets, '
                    'the actual CanonicalMapArtwork, ViewConeWidget, '
                    'SvgHeightViewCone and AgentWidget path. World geometry is '
                    'explicitly enabled; no Hive or legacy height cone is used.',
            'viewport': [1920, 1080],
            'fixture': _fixturePath,
            'fixtureSha256': await _digest(fixtureBytes),
            'frozenFrame': frame,
            'nativeLibrary': _nativeLibrary,
            'nativeLibrarySha256': await _digest(await dll.readAsBytes()),
            'nativeAcceleration': runtime.attack.usesNativeAcceleration &&
                runtime.defense.usesNativeAcceleration,
            'records': records,
          }),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        subscription.close();
        container.dispose();
        await tester.binding.setSurfaceSize(null);
      }
      return true;
    });
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

Future<Uint8List> _capture(
    RenderRepaintBoundary boundary, double pixelRatio) async {
  final captured = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final bytes = await captured.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Could not encode scene PNG.');
    return bytes.buffer.asUint8List();
  } finally {
    captured.dispose();
  }
}
