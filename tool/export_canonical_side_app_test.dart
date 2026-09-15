// Actual app artwork/HeightViewCone replay. No Hive or user library is opened.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography_plus/cryptography_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_query_queue.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/height_view_cone.dart';

const rev = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const size = Size(800, 450);
Future<String> digest(List<int> bytes) async => (await Sha256().hash(bytes))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
Future<Map<String, dynamic>> compressed(String path) async =>
    jsonDecode(utf8.decode(gzip.decode(await File(path).readAsBytes())))
        as Map<String, dynamic>;

class AuditRuntime implements HeightRuntime {
  AuditRuntime(this.assets, this.navigation, this.attack, this.defense,
      this.program, this.worker) {
    queue = HeightQueryQueue((stamp, q) async {
      queries.add(q.toList());
      final frame = await worker.compute(stamp, q);
      meshes.add(Float32List.fromList(frame.cone(0)));
      return frame;
    });
  }
  final List<List<double>> queries = [];
  final List<Float32List> meshes = [];
  @override
  final HeightAssets assets;
  @override
  final NavigationGeometryMap navigation;
  @override
  final WorldReceiverMask attack, defense;
  @override
  final ui.FragmentProgram program;
  @override
  final HeightNativeWorker worker;
  @override
  late final HeightQueryQueue queue;
  @override
  final renderer = WorldHeightCachedRenderer();
  @override
  final variants = <HeightRuntime>[];
  @override
  Future<void> close() async {
    await queue.close();
    renderer.dispose();
    await worker.close();
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget scene(
    AuditRuntime runtime,
    MapValue map,
    String svg,
    Offset origin,
    double rotation,
    double range,
    double angle,
    bool attack,
    GlobalKey key,
    double ratio) {
  final coord = CoordinateSystem.instance;
  final side = coord.positionForSide(
      canonicalPosition: origin,
      reflectionOffset: Offset.zero,
      isAttack: attack);
  final anchor = coord.coordinateToScreen(side);
  final length = coord.worldHeightToScreen(range);
  final sideRotation = coord.rotationForSide(rotation, isAttack: attack);
  return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: ratio),
          child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                  key: key,
                  child: SizedBox.fromSize(
                      size: size,
                      child: ColoredBox(
                          color: const Color(0xff101014),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned(
                                left: (size.width - size.height * 1.24) / 2,
                                top: 0,
                                width: size.height * 1.24,
                                height: size.height,
                                child: CanonicalMapArtwork(
                                    map: map,
                                    isAttack: attack,
                                    child: SvgPicture.string(svg,
                                        fit: BoxFit.contain))),
                            Positioned(
                                left: anchor.dx - length,
                                top: anchor.dy - length,
                                child: Transform.rotate(
                                    angle: sideRotation,
                                    alignment: Alignment.topLeft,
                                    origin: Offset(length, length),
                                    child: SizedBox(
                                        width: length * 2,
                                        height: length,
                                        child: HeightViewCone(
                                            runtime: runtime,
                                            canonicalOrigin: origin,
                                            rotation: sideRotation,
                                            range: range,
                                            angle: angle,
                                            isAttack: attack,
                                            zoom: 1)))),
                            Positioned(
                                left: anchor.dx - 2,
                                top: anchor.dy - 2,
                                child: const SizedBox(
                                    width: 4,
                                    height: 4,
                                    child: DecoratedBox(
                                        decoration: BoxDecoration(
                                            color: Colors.white,
                                            shape: BoxShape.circle))))
                          ])))))));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'actual app classes keep physical pose across canonical side flips',
      (tester) async {
    final completed = await tester.runAsync(() async {
      CoordinateSystem(playAreaSize: size);
      await tester.binding.setSurfaceSize(size);
      final output = Directory(Platform.environment['ICARUS_APP_SIDE_OUTPUT'] ??
          '$rev/app-canonical-side-replay-v1');
      if (output.existsSync())
        throw StateError('Preserve prior replay; use a fresh folder.');
      output.createSync(recursive: true);
      final catalog = await loadHeightCatalog();
      final config = jsonDecode(
          await File('$rev/display-all-candidate-config-v1.json')
              .readAsString()) as Map;
      final splitConfig = jsonDecode(await File(
              '$rev/split-wall-family-normalized-candidate-v9/candidate-config.json')
          .readAsString()) as Map;
      final boundedConfig = jsonDecode(await File(
              '$rev/gallery-reviewed-wall-interiors-v1/candidate-config.json')
          .readAsString()) as Map;
      final program = await ui.FragmentProgram.fromAsset(
          'shaders/world_shadow_radial.frag');
      final records = <Map<String, dynamic>>[];
      for (final map in [MapValue.split, MapValue.icebox, MapValue.lotus]) {
        final c = (map == MapValue.split
            ? splitConfig
            : map == MapValue.icebox
                ? boundedConfig
                : config)['maps'][map.name] as Map;
        final entry = catalog[map]!;
        final assets = HeightAssets(
            folder: c['folder'],
            entry: entry,
            groundField: TacticalGroundField.fromJson(
                await compressed(c['groundFieldFile'])),
            displayWarp:
                DisplayWarp.fromJson(await compressed(c['displayWarpFile'])));
        final t = entry.uiTransform;
        Offset native(Offset uv) => Offset(
            (uv.dy - t['YScalarToAdd']!) / (100 * t['YMultiplier']!),
            -(uv.dx - t['XScalarToAdd']!) / (100 * t['XMultiplier']!));
        final navigation = NavigationGeometryMap(
            geometry: NavigationGeometry.fromJson(
                await compressed(c['navigationFile']),
                projectUv: (uv) => assets.projection.toCanvas(native(uv))),
            observerHeightCm: 175,
            defaultFloorElevationCm: entry.defaultFloorElevationCm);
        final artwork = [
          await File('assets/maps/${map.name}_map.svg').readAsString(),
          await File('assets/maps/${map.name}_map_defense.svg').readAsString()
        ];
        await verifyDisplayWarpArtwork(
            assets.displayWarp!, artwork[0], artwork[1]);
        final runtime = AuditRuntime(
            assets,
            navigation,
            WorldReceiverMask.parse(artwork[0]),
            WorldReceiverMask.parse(artwork[1]),
            program,
            await HeightNativeWorker.open(c['library'], c['folder'], 1));
        final fixturePath = map == MapValue.icebox
            ? '$rev/gallery-reviewed-wall-interiors-v1/icebox-fixtures.json'
            : '$rev/gallery-display-all-v1/${map.name}-fixtures.json';
        final fixtures =
            jsonDecode(await File(fixturePath).readAsString()) as Map;
        final id =
            map == MapValue.icebox ? 'wall-115-center' : 'ramp-0-forward';
        final fixture = (fixtures['cases'] as List)
            .cast<Map>()
            .singleWhere((x) => x['id'] == id);
        final q = (fixture['query'] as List)
            .map((v) => (v as num).toDouble())
            .toList();
        final origin = assets.projection.toCanvas(Offset(q[0], q[1]));
        final displayDirection =
            assets.projection.axisU * q[3] + assets.projection.axisV * q[4];
        final rotation =
            math.atan2(displayDirection.dy, displayDirection.dx) + math.pi / 2;
        final range = q[5] * displayDirection.distance;
        try {
          for (final attack in [true, false]) {
            final key = GlobalKey();
            final previous = runtime.meshes.length;
            final svg = artwork[attack ? 0 : 1];
            final viewBox = (attack ? runtime.attack : runtime.defense).viewBox;
            final svgScale = math.min(size.height / viewBox.height,
                size.height * 1.24 / viewBox.width);
            await tester.pumpWidget(scene(runtime, map, svg, origin, rotation,
                range, q[6], attack, key, 1));
            await tester.pump();
            for (var i = 0; i < 500 && runtime.meshes.length == previous; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(runtime.meshes.length, greaterThan(previous));
            await tester.pumpAndSettle();
            final query = runtime.queries.last;
            for (final density in [2, 8]) {
              final ratio = density / svgScale;
              await tester.pumpWidget(scene(runtime, map, svg, origin, rotation,
                  range, q[6], attack, key, ratio));
              await tester.pumpAndSettle();
              final bytes = await (() async {
                final boundary = key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
                final image = await boundary.toImage(pixelRatio: ratio);
                try {
                  return (await image.toByteData(
                          format: ui.ImageByteFormat.png))!
                      .buffer
                      .asUint8List();
                } finally {
                  image.dispose();
                }
              })();
              final path =
                  '${output.path}/${map.name}-${attack ? 'attack' : 'defense'}-${density}x.png';
              await File(path).writeAsBytes(bytes);
              records.add({
                'map': map.name,
                'id': id,
                'side': attack ? 'attack' : 'defense',
                'density': density,
                'image': path,
                'sha256': await digest(bytes),
                'query': query,
                'canonicalOrigin': [origin.dx, origin.dy],
                'canonicalRotation': rotation,
                'sourceMeshSha256':
                    await digest(runtime.meshes.last.buffer.asUint8List()),
                'displayWarpSha256': c['displayWarpSha256'],
                'candidatePackSha256': c['candidatePackSha256'],
                'pixelRatio': ratio,
                'viewport': [size.width, size.height]
              });
            }
            await tester.pumpWidget(const SizedBox());
          }
          final a = runtime.queries.first, b = runtime.queries.last;
          for (var i = 0; i < 7; i++) {
            expect(b[i], closeTo(a[i], 1e-9),
                reason:
                    '${map.name} source query index$i changed during side flip');
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await runtime.close();
        }
      }
      await File('${output.path}/manifest.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert({
        'scope':
            'Actual CanonicalMapArtwork plus HeightViewCone, actual SVGs and native workers. Same saved marker/rotation, transformed by app side APIs. Isolated widget composition; no user library. Provisional source/floor packs do not constitute game accuracy acceptance.',
        'records': records
      }));
      await tester.binding.setSurfaceSize(null);
      expect(records, hasLength(12));
      return true;
    });
    expect(completed, isTrue,
        reason:
            'Real-I/O replay must complete rather than return after a captured exception.');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
