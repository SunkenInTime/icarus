// Isolated replay of the preserved ten-agent Standing page. No Hive is opened.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/agents.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/const/maps.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_query_queue.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/widgets/canonical_map_artwork.dart';
import 'package:icarus/widgets/dot_painter.dart';
import 'package:icarus/widgets/draggable_widgets/agents/agent_widget.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/height_view_cone.dart';

import 'export_canonical_side_app_test.dart' as shared;

const root = 'E:/IcarusWorldAudit/2026-09-06';
const rev = '$root/tactical-visibility-revision';
const sceneSize = Size(1920, 1080);

class SceneRuntime implements HeightRuntime {
  SceneRuntime(this.assets, this.navigation, this.attack, this.defense,
      this.program, this.worker) {
    queue = HeightQueryQueue((stamp, input) async {
      final frame = await worker.compute(stamp, input);
      for (var i = 0; i < input.length ~/ 7; i++) {
        queries.add(input.sublist(i * 7, i * 7 + 7));
        meshes.add(Float32List.fromList(frame.cone(i)));
      }
      return frame;
    });
  }
  final queries = <List<double>>[];
  final meshes = <Float32List>[];
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

Widget scene(SceneRuntime runtime, String svg, Map frame, Map projection,
    bool attack, GlobalKey key, double ratio,
    {int? selectedIndex, bool maskOnly = false}) {
  final coordinates = CoordinateSystem.instance;
  final cones = <Widget>[];
  final icons = <Widget>[];
  for (var index = 0; index < 10; index++) {
    if (selectedIndex != null && selectedIndex != index) continue;
    final position = frame['positionsCanvas'][index] as List;
    final q = frame['poses'][index] as List;
    final origin = Offset(position[0], position[1]);
    final matrix = projection['nativeToCanvas'];
    final dx = matrix[0][0] * q[3] + matrix[0][1] * q[4];
    final dy = matrix[1][0] * q[3] + matrix[1][1] * q[4];
    final rotation = math.atan2(dy, dx) + math.pi / 2;
    // Matches seed_height_gallery_test.dart and ViewConeWidget conversion.
    final range = coordinates.virtualLengthToWorld(361 * .831);
    final length = coordinates.worldHeightToScreen(range);
    final sideRotation =
        coordinates.rotationForSide(rotation, isAttack: attack);
    final side = coordinates.positionForSide(
        canonicalPosition: origin,
        reflectionOffset: Offset.zero,
        isAttack: attack);
    final anchor = coordinates.coordinateToScreen(side);
    cones.add(Positioned(
        key: ValueKey('placed-cone-$index'),
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
                    key: ValueKey('cone-$index'),
                    runtime: runtime,
                    canonicalOrigin: origin,
                    rotation: sideRotation,
                    range: range,
                    angle: q[6],
                    isAttack: attack,
                    zoom: 1)))));
    final iconSize = coordinates.scale(Settings.agentSize);
    icons.add(Positioned(
        left: anchor.dx - iconSize / 2,
        top: anchor.dy - iconSize / 2,
        child: AgentWidget(
            agent: AgentData.agents[AgentType.values[index]]!,
            id: null,
            isAlly: true,
            isInteractive: false)));
  }
  return ProviderScope(
      child: Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
              data: MediaQueryData(devicePixelRatio: ratio),
              child: Material(
                  color: Settings.tacticalVioletTheme.background,
                  child: Align(
                      alignment: Alignment.topLeft,
                      child: RepaintBoundary(
                          key: key,
                          child: SizedBox.fromSize(
                              size: sceneSize,
                              child: Stack(children: [
                                if (!maskOnly)
                                  Positioned.fill(
                                      child: DecoratedBox(
                                          decoration: BoxDecoration(
                                              gradient: RadialGradient(
                                                  center: Alignment.center,
                                                  radius: 1.5,
                                                  colors: [
                                        const Color(0xff18181b),
                                        Settings.tacticalVioletTheme.background
                                      ])))),
                                if (!maskOnly)
                                  const Positioned.fill(
                                      child: Padding(
                                          padding: EdgeInsets.all(4),
                                          child: DotGrid(isScreenshot: true))),
                                if (!maskOnly)
                                  Positioned(
                                      left: (sceneSize.width -
                                              sceneSize.height * 1.24) /
                                          2,
                                      top: 0,
                                      width: sceneSize.height * 1.24,
                                      height: sceneSize.height,
                                      child: CanonicalMapArtwork(
                                          map: MapValue.split,
                                          isAttack: attack,
                                          child: SvgPicture.string(svg,
                                              fit: BoxFit.contain))),
                                ...cones,
                                if (!maskOnly) ...icons,
                              ]))))))));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('replay exact frozen ten-agent Split page through app classes',
      (tester) async {
    final completed = await tester.runAsync(() async {
      CoordinateSystem(playAreaSize: sceneSize);
      await tester.binding.setSurfaceSize(sceneSize);
      final output = Directory(Platform.environment['ICARUS_SCENE_OUTPUT'] ??
          '$rev/frozen-split-app-scene-v18');
      if (output.existsSync())
        throw StateError('Preserve prior replay output.');
      output.createSync(recursive: true);
      final configPath = Platform.environment['ICARUS_SCENE_CONFIG'] ??
          '$rev/split-wall-family-normalized-candidate-v18/candidate-config.json';
      final configBytes = await File(configPath).readAsBytes();
      final c =
          (jsonDecode(utf8.decode(configBytes)) as Map)['maps']['split'] as Map;
      const fixturePath =
          '$root/compact-prototype/native-walking-fixtures-v1/split/walking-144hz.json';
      final fixtureBytes = await File(fixturePath).readAsBytes();
      final fixture = jsonDecode(utf8.decode(fixtureBytes)) as Map;
      final frame = fixture['frames'][0] as Map;
      expect(frame['frame'], 0);
      final catalog = await loadHeightCatalog();
      final entry = catalog[MapValue.split]!;
      final assets = HeightAssets(
          folder: c['folder'],
          entry: entry,
          groundField: TacticalGroundField.fromJson(
              await shared.compressed(c['groundFieldFile'])),
          displayWarp: DisplayWarp.fromJson(
              await shared.compressed(c['displayWarpFile'])));
      final t = entry.uiTransform;
      Offset native(Offset uv) => Offset(
          (uv.dy - t['YScalarToAdd']!) / (100 * t['YMultiplier']!),
          -(uv.dx - t['XScalarToAdd']!) / (100 * t['XMultiplier']!));
      final navigation = NavigationGeometryMap(
          geometry: NavigationGeometry.fromJson(
              await shared.compressed(c['navigationFile']),
              projectUv: (uv) => assets.projection.toCanvas(native(uv))),
          observerHeightCm: 175,
          defaultFloorElevationCm: entry.defaultFloorElevationCm);
      final artwork = [
        await File('assets/maps/split_map.svg').readAsString(),
        await File('assets/maps/split_map_defense.svg').readAsString()
      ];
      await verifyDisplayWarpArtwork(
          assets.displayWarp!, artwork[0], artwork[1]);
      final runtime = SceneRuntime(
          assets,
          navigation,
          WorldReceiverMask.parse(artwork[0]),
          WorldReceiverMask.parse(artwork[1]),
          await ui.FragmentProgram.fromAsset(
              'shaders/world_shadow_radial.frag'),
          await HeightNativeWorker.open(c['library'], c['folder'], 10));
      final records = <Map<String, dynamic>>[];
      final selections =
          Platform.environment['ICARUS_SCENE_INDIVIDUALS'] == null
              ? <int?>[null]
              : Platform.environment['ICARUS_SCENE_INDIVIDUALS']!
                  .split(',')
                  .map<int?>((s) => int.parse(s))
                  .toList();
      try {
        for (final selectedIndex in selections)
          for (final attack in [true, false]) {
            final key = GlobalKey();
            final previous = runtime.meshes.length;
            final count = selectedIndex == null ? 10 : 1;
            final suffix = selectedIndex == null ? '' : '-agent$selectedIndex';
            await tester.pumpWidget(scene(runtime, artwork[attack ? 0 : 1],
                frame, fixture['projection'], attack, key, 1,
                selectedIndex: selectedIndex));
            await tester.pump();
            for (var n = 0;
                n < 1000 && runtime.meshes.length < previous + count;
                n++) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(runtime.meshes.length, previous + count);
            await tester.pumpAndSettle();
            final viewBox = runtime.attack.viewBox;
            final scale = math.min(sceneSize.height / viewBox.height,
                sceneSize.height * 1.24 / viewBox.width);
            for (final density in selectedIndex == null ? [0, 8] : [8]) {
              final ratio = density == 0 ? 1.0 : density / scale;
              await tester.pumpWidget(scene(runtime, artwork[attack ? 0 : 1],
                  frame, fixture['projection'], attack, key, ratio,
                  selectedIndex: selectedIndex));
              await tester.pumpAndSettle();
              final boundary = key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: ratio);
              late Uint8List bytes;
              try {
                bytes =
                    (await image.toByteData(format: ui.ImageByteFormat.png))!
                        .buffer
                        .asUint8List();
              } finally {
                image.dispose();
              }
              final path =
                  '${output.path}/split-${attack ? 'attack' : 'defense'}$suffix-${density == 0 ? 'full1920' : 'native8x'}.png';
              await File(path).writeAsBytes(bytes);
              final meshPaths = <String>[];
              for (var i = 0; i < count; i++) {
                final mp =
                    '${output.path}/split-${attack ? 'attack' : 'defense'}-agent${selectedIndex ?? i}-shadow.f32';
                await File(mp).writeAsBytes(
                    runtime.meshes[previous + i].buffer.asUint8List());
                meshPaths.add(mp);
              }
              String? maskPath;
              if (selectedIndex != null) {
                await tester.pumpWidget(scene(runtime, artwork[attack ? 0 : 1],
                    frame, fixture['projection'], attack, key, ratio,
                    selectedIndex: selectedIndex, maskOnly: true));
                await tester.pumpAndSettle();
                final maskImage = await (key.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: ratio);
                try {
                  maskPath =
                      '${output.path}/split-${attack ? 'attack' : 'defense'}$suffix-cone-native8x.png';
                  await File(maskPath).writeAsBytes((await maskImage.toByteData(
                          format: ui.ImageByteFormat.png))!
                      .buffer
                      .asUint8List());
                } finally {
                  maskImage.dispose();
                }
              }
              records.add({
                'agentIndex': selectedIndex,
                'sourceMeshFiles': meshPaths,
                'coneImage': maskPath,
                'image': path,
                'sha256': await shared.digest(bytes),
                'side': attack ? 'attack' : 'defense',
                'pixelRatio': ratio,
                'sourceQueries':
                    runtime.queries.sublist(previous, previous + count),
                'sourceMeshSha256': [
                  for (final mesh
                      in runtime.meshes.sublist(previous, previous + count))
                    await shared.digest(mesh.buffer.asUint8List())
                ]
              });
            }
            await tester.pumpWidget(const SizedBox());
          }
        var cursor = 0;
        for (final selectedIndex in selections) {
          final count = selectedIndex == null ? 10 : 1;
          for (var i = 0; i < count; i++)
            for (var j = 0; j < 7; j++) {
              expect(runtime.queries[cursor + count + i][j],
                  closeTo(runtime.queries[cursor + i][j], 1e-9));
            }
          cursor += count * 2;
        }
        await File('${output.path}/manifest.json')
            .writeAsString(const JsonEncoder.withIndent('  ').convert({
          'scope':
              'Exact preserved frame0 saved positions, original icon types and rotations. Actual CanonicalMapArtwork, HeightViewCone, AgentWidget and DotGrid. Automatic standing eye uses provisional candidate navigation/source-floor normalization. No Hive or production asset mutation, no final Split accuracy claim.',
          'fixturePath': fixturePath,
          'fixtureSha256': await shared.digest(fixtureBytes),
          'frozenFrame': frame,
          'configPath': configPath,
          'configSha256': await shared.digest(configBytes),
          'candidatePackSha256': c['candidatePackSha256'],
          'displayWarpSha256': c['displayWarpSha256'],
          'viewport': [sceneSize.width, sceneSize.height],
          'records': records
        }));
      } finally {
        await tester.pumpWidget(const SizedBox());
        await runtime.close();
      }
      await tester.binding.setSurfaceSize(null);
      return true;
    });
    expect(completed, isTrue);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
