import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

import 'display_warp_fixture.dart';

const _nativeBounds = Rect.fromLTWH(0, 0, 20, 20);
const _shift = Offset(3, -2);
const _width = 290;
const _height = 250;
final _attack = VisionWorldProjection(
    origin: const Offset(25, 25),
    axisU: const Offset(10, 1),
    axisV: const Offset(1, 8));
final _defense = VisionWorldProjection(
    origin: const Offset(265, 225),
    axisU: -_attack.axisU,
    axisV: -_attack.axisV);

/// Independent inverse of the fixture's four affine triangles. The expected
/// pixels never call DisplayWarp.sourceAt, targetAt or createMesh.
Offset _sourceAt(Offset target, Offset shift) {
  const corners = [Offset(0, 0), Offset(20, 0), Offset(20, 20), Offset(0, 20)];
  const center = Offset(10, 10);
  for (var i = 0; i < 4; i++) {
    final a = corners[i], b = corners[(i + 1) % 4];
    final c = center + shift;
    double area(Offset p, Offset q, Offset r) =>
        (q.dx - p.dx) * (r.dy - p.dy) - (q.dy - p.dy) * (r.dx - p.dx);
    final denominator = area(a, b, c);
    final wa = area(target, b, c) / denominator;
    final wb = area(a, target, c) / denominator;
    final wc = area(a, b, target) / denominator;
    if (wa >= -1e-10 && wb >= -1e-10 && wc >= -1e-10) {
      return a * wa + b * wb + center * wc;
    }
  }
  return target;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FragmentProgram program;
  setUpAll(() async {
    program =
        await FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  });

  for (final side in [('attack', _attack), ('defense', _defense)]) {
    test(
        '${side.$1} nonlinear display preserves source visibility and receiver holes',
        () async {
      final fixture = _Scene(program, side.$2);
      final renderer = WorldHeightCachedRenderer();
      addTearDown(fixture.dispose);
      addTearDown(renderer.dispose);
      for (final state in [
        (range: 7.2, facing: .18, cone: 1.75, scale: 1.0),
        (range: 9.1, facing: -.35, cone: 2.7, scale: 1.65),
        (range: 8.4, facing: 0.0, cone: 2 * math.pi, scale: 1.0),
      ]) {
        fixture
          ..range = state.range
          ..facing = state.facing
          ..cone = state.cone
          ..scale = state.scale;
        final pixels = await fixture.render(renderer);
        fixture.checkAgainstOracle(pixels);
        final misses = renderer.cacheMisses;
        expect(await fixture.render(renderer), orderedEquals(pixels),
            reason: 'A cached repeated frame must preserve every channel.');
        expect(renderer.cacheMisses, misses);
      }
      expect(renderer.cacheMisses, 3);
      expect(renderer.cacheHits, 3);
    });
  }

  test('changing display warp reuses source shadow and refreshes target pixels',
      () async {
    final fixture = _Scene(program, _attack);
    final renderer = WorldHeightCachedRenderer();
    addTearDown(fixture.dispose);
    addTearDown(renderer.dispose);
    final before = await fixture.render(renderer);
    fixture.shift = const Offset(-2, 2);
    fixture.warp = fixture.makeWarp();
    final after = await fixture.render(renderer);
    expect(after, isNot(orderedEquals(before)));
    expect(renderer.cacheMisses, 1);
    expect(renderer.cacheHits, 1);
    fixture.checkAgainstOracle(after);
    renderer.clear();
    expect(renderer.residentImages, 0);
    expect(renderer.disposedImages, 1);
    expect(await fixture.render(renderer), orderedEquals(after));
    renderer.dispose();
    renderer.dispose();
    expect(renderer.residentImages, 0);
    expect(renderer.estimatedRgbaBytes, 0);
    expect(renderer.disposedImages, renderer.cacheMisses);
    await expectLater(fixture.render(renderer), throwsStateError);
  });
}

class _Scene {
  _Scene(FragmentProgram program, this.projection)
      : shader = program.fragmentShader() {
    warp = makeWarp();
  }
  final VisionWorldProjection projection;
  final FragmentShader shader;
  late DisplayWarp warp;
  Offset shift = _shift;
  Offset origin = const Offset(6, 8);
  double range = 7.2, facing = .18, cone = 1.75, scale = 1;
  // Shadow of the finite wall x=2, -0.8 <= y <=1.2, relative to origin.
  // The CPU oracle instead intersects a ray with that wall segment.
  Float32List mesh = Float32List.fromList([
    2,
    -.8,
    20,
    -8,
    20,
    12,
    2,
    -.8,
    20,
    12,
    2,
    1.2,
  ]);
  final Object meshKey = Object();
  Rect get hole => identical(projection, _attack)
      ? const Rect.fromLTRB(131, 82, 151, 112)
      : const Rect.fromLTRB(139, 138, 159, 168);
  Rect get receiverBounds => const Rect.fromLTWH(3, 3, 284, 244);
  WorldReceiverMask get receiver {
    final h = hole, b = receiverBounds;
    return WorldReceiverMask.parse('''<svg viewBox="0 0 $_width $_height">
      <path fill="#271406" fill-rule="evenodd" d="M${b.left} ${b.top}H${b.right}V${b.bottom}H${b.left}Z M${h.left} ${h.top}H${h.right}V${h.bottom}H${h.left}Z"/>
    </svg>''');
  }

  DisplayWarp makeWarp() => DisplayWarp.fromJson(displayWarpFixture(
      projection: _attack, bounds: _nativeBounds, shift: shift));

  Future<Uint8List> render(WorldHeightCachedRenderer renderer) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder)..scale(scale);
    try {
      paintWorldReceiverVisibility(
          canvas: canvas,
          receiver: receiver,
          paintVisibility: (canvas) => renderer.paintCone(
              canvas,
              mesh,
              projection,
              projection.toCanvas(origin),
              facing,
              range,
              cone,
              scale,
              const Color(0xffffffff),
              shader,
              coneId: 'one',
              meshKey: meshKey,
              viewport: const Rect.fromLTWH(0, 0, 290, 250),
              displayWarp: warp));
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(
            (_width * scale).ceil(), (_height * scale).ceil());
        try {
          return (await image.toByteData(format: ImageByteFormat.rawRgba))!
              .buffer
              .asUint8List();
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } catch (_) {
      if (recorder.isRecording) recorder.endRecording().dispose();
      rethrow;
    }
  }

  void checkAgainstOracle(Uint8List pixels) {
    final width = (_width * scale).ceil(), height = (_height * scale).ceil();
    var visible = 0, blocked = 0, outsideRange = 0, outsideFov = 0, holes = 0;
    var checked = 0, mismatches = 0;
    final examples = <String>[];
    for (var y = 2; y < height - 2; y += 2) {
      for (var x = 2; x < width - 2; x += 2) {
        final display = Offset((x + .5) / scale, (y + .5) / scale);
        final native = projection.toMeters(display);
        // Boundary coverage is antialiased. Check interior pixels away from
        // source metric discontinuities and the actual SVG receiver outline.
        if (!_nativeBounds.deflate(.25).contains(native)) continue;
        if (!receiverBounds.deflate(2 / scale).contains(display)) continue;
        final inHole = hole.deflate(2 / scale).contains(display);
        if (hole.inflate(2 / scale).contains(display) && !inHole) continue;
        final source = _sourceAt(native, shift), d = source - origin;
        final radius = d.distance;
        if (radius < .3 || (radius - range).abs() < .25) continue;
        final angle = math
            .atan2(math.sin(math.atan2(d.dy, d.dx) - facing),
                math.cos(math.atan2(d.dy, d.dx) - facing))
            .abs();
        if (cone < 2 * math.pi && (angle - cone / 2).abs() * radius < .25)
          continue;
        final wallY = d.dx.abs() > 1e-10 ? d.dy * 2 / d.dx : double.infinity;
        if ((d.dx - 2).abs() < .25 ||
            (d.dx > 2 &&
                ((wallY + .8).abs() < .12 || (wallY - 1.2).abs() < .12)))
          continue;
        final shadow = d.dx > 2 && wallY > -.8 && wallY < 1.2;
        final inRange = radius < range, inFov = angle < cone / 2;
        final expected = !inHole && inRange && inFov && !shadow;
        final alpha = pixels[(y * width + x) * 4 + 3];
        if ((expected && alpha < 250) || (!expected && alpha > 5)) {
          mismatches++;
          if (examples.length < 8)
            examples.add(
                'pixel($x,$y), source=$source alpha=$alpha expected=$expected');
        }
        checked++;
        if (expected) visible++;
        if (inHole && inRange && inFov && !shadow) holes++;
        if (!inHole && inRange && inFov && shadow) blocked++;
        if (!inHole && !inRange) outsideRange++;
        if (!inHole && inRange && !inFov) outsideFov++;
      }
    }
    expect(checked, greaterThan(1000));
    expect(visible, greaterThan(30));
    expect(blocked, greaterThan(15));
    expect(outsideRange, greaterThan(100));
    if (cone < 2 * math.pi) expect(outsideFov, greaterThan(20));
    // Hole placement is fixed in artwork, not warped with source geometry.
    // Some directional cones miss it; the full circle must exercise it.
    if (cone == 2 * math.pi) expect(holes, greaterThan(5));
    expect(mismatches, 0, reason: examples.join('\n'));
  }

  void dispose() => shader.dispose();
}
