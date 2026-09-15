import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/coordinate_system.dart';
import 'package:icarus/page_transition/navigation_geometry.dart';
import 'package:icarus/page_transition/navigation_geometry_map.dart';
import 'package:icarus/providers/height_runtime_provider.dart';
import 'package:icarus/view_cone/height_assets.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_query_queue.dart';
import 'package:icarus/view_cone/height_render.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/tactical_ground_field.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/height_view_cone.dart';

import 'display_warp_fixture.dart';

const _size = Size(800, 450);
const _origin = Offset(700, 500);
const _range = 220.0;
const _angle = 103 * math.pi / 180;
final _boundary = GlobalKey();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ui.FragmentProgram program;
  setUpAll(() async {
    program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  });

  testWidgets(
      'display correction inverses observer without changing heading or range',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    for (final attack in [true, false]) {
      final runtime = _Runtime(program);
      final assets = runtime.assets as _Assets;
      assets.defenseOffset = const Offset(-1.7, -.4);
      assets.groundField = TacticalGroundField.fromJson({
        'version': 1,
        'coordinateSpace': 'native-meters',
        'vertices': [0, 0, 0, 100, 0, 1, 100, 100, 1, 0, 100, 0],
        'triangles': [0, 1, 2, 0, 2, 3],
      });
      final warp = assets.displayWarp = DisplayWarp.fromJson(displayWarpFixture(
          projection: assets.projection, shift: const Offset(2, -1)));
      for (final origin in [_origin, _origin + const Offset(.01, .02)]) {
        await tester
            .pumpWidget(_widget(runtime, attack: attack, origin: origin));
        await tester.pumpAndSettle();
        final source = warp.sourceAt(assets.projection.toMeters(origin));
        final query = runtime.queries.last;
        expect(query[0], closeTo(source.dx, 1e-10));
        expect(query[1], closeTo(source.dy, 1e-10));
        expect(query[2], closeTo(2.98 - source.dx / 100, 1e-10),
            reason: 'Ground is sampled at the physical source location.');
        final sign = attack ? 1 : -1;
        expect(query[3], closeTo(sign * math.cos(.73 - math.pi / 2), 1e-12));
        expect(query[4], closeTo(sign * math.sin(.73 - math.pi / 2), 1e-12));
        expect(query[5], closeTo(_range / 8, 1e-12));
        expect(query[6], _angle);
        expect(
            ((runtime.navigation.geometry as _Floor).lastPosition! - origin)
                .distance,
            lessThan(1e-10));
        expect((await _capture(tester, 1)).any((v) => v != 0), isTrue);
      }
      await tester.pumpWidget(const SizedBox());
      await runtime.close();
    }
  });

  testWidgets(
      'defense artwork translation keeps the same physical origin and floor',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program);
    const shift = Offset(-1.7, -.4);
    (runtime.assets as _Assets).defenseOffset = shift;
    await tester.pumpWidget(_widget(runtime, attack: false));
    await tester.pumpAndSettle();
    final expectedNative = runtime.assets.projection.toMeters(_origin);
    expect(runtime.queries.single[0], closeTo(expectedNative.dx, 1e-12));
    expect(runtime.queries.single[1], closeTo(expectedNative.dy, 1e-12));
    expect((runtime.navigation.geometry as _Floor).lastPosition!.dx,
        closeTo(_origin.dx, 1e-10));
    expect((runtime.navigation.geometry as _Floor).lastPosition!.dy,
        closeTo(_origin.dy, 1e-10));
    expect(await _capture(tester, 1),
        await tester.runAsync(() => _reference(runtime, attack: false)));
    await tester.pumpWidget(const SizedBox());
    await runtime.close();
  });

  testWidgets('ground reference adjusts query height and rejects outside poses',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program);
    (runtime.assets as _Assets).groundField = TacticalGroundField.fromJson({
      'version': 1,
      'coordinateSpace': 'native-meters',
      'vertices': [0, 0, 1, 100, 0, 1, 100, 100, 1, 0, 100, 1],
      'triangles': [0, 1, 2, 0, 2, 3],
    });
    await tester.pumpWidget(_widget(runtime));
    await tester.pumpAndSettle();
    expect(runtime.queries.single[2], closeTo(1.98, 1e-12));
    expect((await _capture(tester, 1)).any((byte) => byte != 0), isTrue);
    await tester.pumpWidget(_widget(runtime, origin: const Offset(1300, 500)));
    await tester.pumpAndSettle();
    expect(runtime.queries, hasLength(1));
    expect((await _capture(tester, 1)).every((byte) => byte == 0), isTrue);
    await tester.pumpWidget(_widget(runtime));
    await tester.pumpAndSettle();
    expect(runtime.queries, hasLength(2));
    (runtime.navigation.geometry as _Floor).admitted = false;
    await tester.pumpWidget(_widget(runtime, origin: const Offset(701, 500)));
    await tester.pumpAndSettle();
    expect(runtime.queries.last[2], 1.75,
        reason:
            'Painted edge outside nav inset uses the local ground reference');
    await tester.pumpWidget(const SizedBox());
    await runtime.close();
  });

  testWidgets('off-map origins need a painted receiver or a native floor',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program);
    (runtime.navigation.geometry as _Floor).admitted = false;
    await tester.pumpWidget(_widget(runtime));
    await tester.pumpAndSettle();
    expect(runtime.queries, hasLength(1));
    await tester.pumpWidget(_widget(runtime, origin: const Offset(100, 500)));
    await tester.pumpAndSettle();
    expect(runtime.queries, hasLength(1));
    expect((await _capture(tester, 1)).every((byte) => byte == 0), isTrue);
    await tester.pumpWidget(const SizedBox());
    await runtime.close();
  });

  testWidgets('changing floor charts cancels the old worker pose',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program)..defer = true;
    final upper = _Runtime(program)..defer = true;
    runtime.variants.add(upper);
    (upper.assets as _Assets).groundField = TacticalGroundField.fromJson({
      'version': 1,
      'coordinateSpace': 'native-meters',
      'vertices': [0, 0, 2, 100, 0, 2, 100, 100, 2, 0, 100, 2],
      'triangles': [0, 1, 2, 0, 2, 3],
    });
    await tester.pumpWidget(_widget(runtime));
    await tester.pump();
    expect(runtime.queries, hasLength(1));
    (runtime.navigation.geometry as _Floor).chart = 1;
    await tester.pumpWidget(_widget(runtime, rotation: .74));
    await tester.pump();
    expect(upper.queries.single[2], closeTo(.98, 1e-12));
    runtime.finish();
    await tester.pumpAndSettle();
    expect((await _capture(tester, 1)).every((byte) => byte == 0), isTrue);
    upper.finish();
    await tester.pumpAndSettle();
    expect((await _capture(tester, 1)).any((byte) => byte != 0), isTrue);
    await tester.pumpWidget(const SizedBox());
    await runtime.close();
    await upper.close();
  });

  testWidgets(
      'draggable rotation and side projection match direct map rendering',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program);
    for (final (attack, rotation, zoom, ratio) in [
      (true, .73, 1.0, 1.0),
      (false, .73 + math.pi, 1.0, 1.0),
      (true, 1.19, 1.4, 2.0),
      (false, 1.19 + math.pi, 1.4, 2.0),
    ]) {
      await tester.pumpWidget(_widget(runtime,
          attack: attack, rotation: rotation, zoom: zoom, ratio: ratio));
      await tester.pumpAndSettle();
      final actual = await _capture(tester, ratio);
      final expected = await tester.runAsync(() => _reference(runtime,
          attack: attack, rotation: rotation, zoom: zoom, ratio: ratio));
      if (attack || ratio == 1) {
        expect(actual, expected,
            reason: '$attack / $rotation / $zoom / $ratio');
      } else {
        // Flutter's outer draggable rotation and inverse local rotation leave
        // float transform error below 0.0001 SVG units. On this exact vertical
        // shadow boundary that can choose the adjacent 2x coverage cell. The
        // difference must remain in one antialiased pixel column; no interior
        // visibility or receiver destination may change.
        final width = (_size.width * ratio).round();
        var nonCoverageDifferences = 0;
        for (var i = 0; i < actual.length; i += 4) {
          if (actual[i + 3] == expected![i + 3]) {
            for (var channel = 0; channel < 3; channel++) {
              if (actual[i + channel] != expected[i + channel]) {
                nonCoverageDifferences++;
              }
            }
          }
        }
        expect(nonCoverageDifferences, 0);
        final changed = <int>[
          for (var i = 0; i < actual.length; i += 4)
            if (actual[i + 3] != expected![i + 3]) i ~/ 4
        ];
        expect(changed.map((pixel) => pixel % width).toSet().length,
            lessThanOrEqualTo(1));
        for (final pixel in changed) {
          final i = pixel * 4;
          final a = actual[i + 3], e = expected![i + 3];
          expect((a - e).abs(), lessThanOrEqualTo(64));
          final neighbors = [
            for (final dy in [-1, 0, 1])
              for (final dx in [-1, 0, 1])
                if (i + (dy * width + dx) * 4 + 3 >= 0 &&
                    i + (dy * width + dx) * 4 + 3 < expected.length)
                  expected[i + (dy * width + dx) * 4 + 3]
          ];
          expect(neighbors, contains(0));
          expect(neighbors.any((value) => value >= math.max(a, e) - 2), isTrue);
        }
      }
      final query = runtime.queries.last;
      final nativeOrigin = runtime.assets.projection.toMeters(_origin);
      expect(query[0], nativeOrigin.dx);
      expect(query[1], nativeOrigin.dy);
      expect(query[2], 2.98);
      final displayDirection = (attack
              ? runtime.assets.projection
              : runtime.assets.projection.defense)
          .vectorToMeters(Offset(math.cos(rotation - math.pi / 2),
              math.sin(rotation - math.pi / 2)));
      expect(query[3],
          closeTo(displayDirection.dx / displayDirection.distance, 1e-12));
      expect(query[4],
          closeTo(displayDirection.dy / displayDirection.distance, 1e-12));
      expect(query[5], closeTo(_range * displayDirection.distance, 1e-12));
    }
    await tester.pumpWidget(const SizedBox());
    expect(runtime.renderer.residentImages, 0);
    await runtime.close();
  });

  testWidgets(
      'pending poses keep completed meshes at their original world position',
      (tester) async {
    CoordinateSystem(playAreaSize: _size);
    final runtime = _Runtime(program)..defer = true;
    await tester.pumpWidget(_widget(runtime));
    await tester.pump();
    expect((await _capture(tester, 1)).every((byte) => byte == 0), isTrue);
    runtime.finish();
    await tester.pumpAndSettle();
    final original = await _capture(tester, 1);
    expect(original.any((byte) => byte != 0), isTrue);
    await tester.pumpWidget(
        _widget(runtime, rotation: .8, origin: const Offset(750, 530)));
    await tester.pump();
    expect(await _capture(tester, 1), original);
    // Replace an in-flight pose. Completing it must not display its geometry
    // at the newer anchor or facing.
    await tester.pumpWidget(
        _widget(runtime, rotation: 1.2, origin: const Offset(800, 550)));
    await tester.pump();
    runtime.finish();
    await tester.pumpAndSettle();
    expect(
        await _capture(tester, 1),
        await tester.runAsync(() =>
            _reference(runtime, rotation: .8, origin: const Offset(750, 530))));
    runtime.finish();
    await tester.pumpAndSettle();
    expect(
        await _capture(tester, 1),
        await tester.runAsync(() => _reference(runtime,
            rotation: 1.2, origin: const Offset(800, 550))));
    final replacement = _Runtime(program)..defer = true;
    await tester.pumpWidget(_widget(replacement, rotation: 1.2));
    await tester.pump();
    expect(runtime.renderer.residentImages, 0);
    expect((await _capture(tester, 1)).every((byte) => byte == 0), isTrue);
    replacement.finish();
    await tester.pumpAndSettle();
    expect((await _capture(tester, 1)).any((byte) => byte != 0), isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(replacement.renderer.residentImages, 0);
    await runtime.close();
    await replacement.close();
  });
}

Widget _widget(_Runtime runtime,
    {bool attack = true,
    double rotation = .73,
    double zoom = 1,
    double ratio = 1,
    Offset origin = _origin}) {
  final coord = CoordinateSystem.instance;
  final side = coord.positionForSide(
      canonicalPosition: origin,
      reflectionOffset: Offset.zero,
      isAttack: attack);
  final screenOrigin = coord.coordinateToScreen(side);
  final length = coord.worldHeightToScreen(_range);
  return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
          data: MediaQueryData(devicePixelRatio: ratio),
          child: Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                  key: _boundary,
                  child: SizedBox.fromSize(
                      size: _size,
                      child: Transform.scale(
                          scale: zoom,
                          alignment: Alignment.topLeft,
                          child: Stack(clipBehavior: Clip.none, children: [
                            Positioned(
                                left: screenOrigin.dx - length,
                                top: screenOrigin.dy - length,
                                child: Transform.rotate(
                                    angle: rotation,
                                    alignment: Alignment.topLeft,
                                    origin: Offset(length, length),
                                    child: SizedBox(
                                        width: length * 2,
                                        height: length,
                                        child: HeightViewCone(
                                            runtime: runtime,
                                            canonicalOrigin: origin,
                                            rotation: rotation,
                                            range: _range,
                                            angle: _angle,
                                            isAttack: attack,
                                            zoom: zoom))))
                          ])))))));
}

Future<Uint8List> _capture(WidgetTester tester, double ratio) async =>
    (await tester.runAsync(() async {
      final boundary = _boundary.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: ratio);
      final bytes =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List();
      image.dispose();
      return bytes;
    }))!;

Future<Uint8List> _reference(_Runtime runtime,
    {bool attack = true,
    double rotation = .73,
    double zoom = 1,
    double ratio = 1,
    Offset origin = _origin}) async {
  final receiver = attack ? runtime.attack : runtime.defense;
  final mapRect = Rect.fromCenter(
      center: _size.center(Offset.zero),
      width: _size.height * 1.24,
      height: _size.height);
  final fitted =
      applyBoxFit(BoxFit.contain, receiver.viewBox.size, mapRect.size);
  final destination = Alignment.center.inscribe(fitted.destination, mapRect);
  final svgScreenScale = destination.width / receiver.viewBox.width;
  final screenScale = _size.height / 1000;
  final artworkTranslation = attack
      ? Offset.zero
      : runtime.assets.projection.defense.origin -
          runtime.assets.defenseProjection.origin;
  final worldOffset = destination.topLeft / screenScale -
      receiver.viewBox.topLeft * (svgScreenScale / screenScale) +
      artworkTranslation;
  final svgWorldScale = svgScreenScale / screenScale;
  final sideProjection =
      attack ? runtime.assets.projection : runtime.assets.projection.defense;
  final svgProjection = VisionWorldProjection(
      origin: (sideProjection.origin - worldOffset) / svgWorldScale,
      axisU: sideProjection.axisU / svgWorldScale,
      axisV: sideProjection.axisV / svgWorldScale);
  final sideOrigin =
      attack ? origin : Offset(1000 * 16 / 9 - origin.dx, 1000 - origin.dy);
  final direction = sideProjection.vectorToMeters(Offset(
      math.cos(rotation - math.pi / 2), math.sin(rotation - math.pi / 2)));
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..scale(ratio * zoom)
    ..translate(destination.left + artworkTranslation.dx * screenScale,
        destination.top + artworkTranslation.dy * screenScale)
    ..scale(svgScreenScale)
    ..translate(-receiver.viewBox.left, -receiver.viewBox.top);
  final shader = runtime.program.fragmentShader();
  paintWorldReceiverVisibility(
      canvas: canvas,
      receiver: receiver,
      paintVisibility: (canvas) => WorldHeightRenderer().paintCone(
          canvas,
          runtime.mesh,
          svgProjection,
          (sideOrigin - worldOffset) / svgWorldScale,
          math.atan2(direction.dy, direction.dx),
          _range * direction.distance,
          _angle,
          svgScreenScale * zoom * ratio,
          const Color.fromARGB(128, 147, 147, 147),
          shader,
          radialFalloff: 1));
  final picture = recorder.endRecording();
  final image = await picture.toImage(
      (_size.width * ratio).round(), (_size.height * ratio).round());
  picture.dispose();
  shader.dispose();
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  image.dispose();
  return bytes;
}

class _Runtime implements HeightRuntime {
  @override
  final variants = <HeightRuntime>[];
  _Runtime(this.program) {
    queue = HeightQueryQueue((stamp, query) {
      queries.add(Float64List.fromList(query));
      final result =
          HeightFrame(stamp, mesh, Uint32List.fromList([0, mesh.length]), {});
      if (!defer) return Future.value(result);
      final completer = Completer<HeightFrame>();
      pending.add((completer, result));
      return completer.future;
    });
  }
  bool defer = false;
  final queries = <Float64List>[];
  final pending = <(Completer<HeightFrame>, HeightFrame)>[];
  void finish() {
    final (completion, result) = pending.removeAt(0);
    completion.complete(result);
  }

  final mesh = Float32List.fromList(
      [8, -100, 100, -100, 100, 100, 8, -100, 100, 100, 8, 100]);
  @override
  final ui.FragmentProgram program;
  @override
  late final HeightQueryQueue queue;
  @override
  final renderer = WorldHeightCachedRenderer();
  @override
  final HeightAssets assets = _Assets();
  @override
  final navigation = NavigationGeometryMap(
      geometry: _Floor(), observerHeightCm: 175, defaultFloorElevationCm: 100);
  @override
  final attack = WorldReceiverMask.parse(
      '<svg viewBox="0 0 1000 1000"><path fill="#271406" d="M0 0H1000V1000H0Z M450 400V600H480V400Z"/></svg>');
  @override
  final defense = WorldReceiverMask.parse(
      '<svg viewBox="0 0 1000 1000"><path fill="#271406" d="M.824 0H1000V1000H.824Z M520 400V600H550V400Z"/></svg>');
  @override
  Future<void> close() async {
    await queue.close();
    renderer.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Assets implements HeightAssets {
  @override
  DisplayWarp? displayWarp;
  @override
  List<HeightAssets> get variants => const [];
  Offset defenseOffset = Offset.zero;
  @override
  VisionWorldProjection get defenseProjection {
    final p = projection.defense;
    return VisionWorldProjection(
        origin: p.origin + defenseOffset, axisU: p.axisU, axisV: p.axisV);
  }

  @override
  TacticalGroundField? groundField;
  @override
  final projection = VisionWorldProjection(
      origin: const Offset(388.8888888888889, 0),
      axisU: const Offset(8, 0),
      axisV: const Offset(0, 8));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Floor implements NavigationGeometry {
  int chart = 0;
  @override
  int groundChartAt(Offset position, {double? preferredElevation}) => chart;
  Offset? lastPosition;
  bool admitted = true;
  @override
  double? floorHeightAt(Offset position, {double? preferredElevation}) {
    lastPosition = position;
    return admitted ? 123 : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
