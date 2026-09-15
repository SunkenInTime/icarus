import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/height_render.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FragmentProgram program;
  setUpAll(() async {
    program =
        await FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
  });

  test('same shadow images preserve pixels and refresh shader-only values',
      () async {
    final cache = WorldHeightCachedRenderer();
    final fixture = _Fixture(program);
    final rows = <Map<String, Object>>[];
    Future<void> compare(String label) async {
      final fresh = await fixture.render();
      final reused = await fixture.render(cache: cache);
      var changed = 0, maximum = 0;
      for (var i = 0; i < fresh.length; i++) {
        final error = (fresh[i] - reused[i]).abs();
        if (error > 0) changed++;
        maximum = math.max(maximum, error);
      }
      rows.add({
        'case': label,
        'changedChannels': changed,
        'maximumChannelDifference': maximum,
        'cacheHits': cache.cacheHits,
        'cacheMisses': cache.cacheMisses,
        'residentImages': cache.residentImages,
        'estimatedRgbaBytes': cache.estimatedRgbaBytes,
        'disposedImages': cache.disposedImages,
      });
      expect(changed, 0, reason: label);
      expect(cache.disposedImages + cache.residentImages, cache.cacheMisses);
    }

    await compare('first ten cones');
    expect(cache.cacheMisses, 10);
    expect(cache.cacheHits, 0);
    await compare('identical repeated frame');
    expect(cache.cacheHits, 10);
    expect(cache.cacheMisses, 10);
    fixture.color = const Color(0x963dbed4);
    fixture.clearanceMeters = .025;
    await compare('color and clearance change through fresh shader uniforms');
    expect(cache.cacheMisses, 10);
    expect(cache.cacheHits, 20);
    fixture.background = false;
    await compare('same cache onto transparent destination');
    expect(cache.cacheMisses, 10);
    expect(cache.cacheHits, 30);
    fixture.background = true;
    fixture.meshes[3] = Float32List.fromList(fixture.meshes[3]);
    await compare('one replaced mesh list with unchanged explicit revision');
    expect(cache.cacheMisses, 11);
    expect(cache.cacheHits, 39);
    fixture.keys[4] = Object();
    await compare('one new query revision with the same mesh list');
    expect(cache.cacheMisses, 12);
    expect(cache.cacheHits, 48);
    fixture.origins[2] += const Offset(.37, -.19);
    await compare('one changed origin');
    expect(cache.cacheMisses, 13);
    fixture.facings[5] += .07;
    await compare('one changed facing');
    expect(cache.cacheMisses, 14);
    fixture.ranges[6] += .2;
    await compare('one changed range');
    expect(cache.cacheMisses, 15);
    fixture.cones[7] += .015;
    await compare('one changed cone angle');
    expect(cache.cacheMisses, 16);
    fixture.projection = VisionWorldProjection(
        origin: const Offset(.3, -.4),
        axisU: fixture.projection.axisU,
        axisV: fixture.projection.axisV);
    await compare('changed projection origin');
    expect(cache.cacheMisses, 26);
    fixture.projection = VisionWorldProjection(
        origin: fixture.projection.origin,
        axisU: const Offset(3.2, .61),
        axisV: const Offset(-.23, 2.9));
    await compare('changed anisotropic projection axes');
    expect(cache.cacheMisses, 36);
    fixture.scale = 1.31;
    await compare('changed viewport scale');
    expect(cache.cacheMisses, 46);
    fixture.viewport = const Rect.fromLTWH(2, 3, 452, 362);
    await compare('changed viewport bounds');
    expect(cache.cacheMisses, 56);
    await compare('repeated final state');
    expect(cache.cacheMisses, 56);
    expect(cache.residentImages, 10);
    final missesBeforeFalloff = cache.cacheMisses;
    final hitsBeforeFalloff = cache.cacheHits;
    fixture.radialFalloff = 1;
    await compare('radial opacity falloff reuses the same shadow images');
    expect(cache.cacheMisses, missesBeforeFalloff);
    expect(cache.cacheHits, hitsBeforeFalloff + 10);
    fixture.devicePixelRatio = 2;
    await compare('DPR 2 with fractional fit scale');
    fixture.zoom = 1.73;
    await compare('DPR 2 and fractional zoom');
    fixture.projection = VisionWorldProjection(
        origin: const Offset(340, 260),
        axisU: -fixture.projection.axisU,
        axisV: -fixture.projection.axisV);
    await compare('defense reflection with DPR 2 and zoom');
    await compare('repeated reflected DPR 2 zoom');
    cache.dispose();
    cache.dispose();
    expect(cache.residentImages, 0);
    expect(cache.estimatedRgbaBytes, 0);
    expect(cache.disposedImages, cache.cacheMisses);
    fixture.dispose();
    const directory = String.fromEnvironment('HEIGHT_CACHE_AUDIT_DIR',
        defaultValue: 'build/height_cache_audit');
    Directory(directory).createSync(recursive: true);
    File('$directory/pixel-comparison.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'status': 'all-cached-and-fresh-frames-bit-identical',
      'shader': 'Existing world_shadow_radial.frag compiled shader',
      'reference': 'Unchanged WorldHeightRenderer, new shadow image each draw',
      'receiver': 'Existing two-layer dstIn compositor with holes and islands',
      'cases': rows,
    }));
  });

  test('accepts more than ten cones and respects the retained byte budget',
      () async {
    final fixture = _Fixture(program, coneCount: 20);
    final cache = WorldHeightCachedRenderer(maxImages: 20);
    expect(await fixture.render(cache: cache), await fixture.render());
    expect(cache.residentImages, 20);
    expect(cache.estimatedRgbaBytes, lessThanOrEqualTo(cache.maxBytes));
    final oneImageBytes = cache.estimatedRgbaBytes ~/ 20;
    final limited = WorldHeightCachedRenderer(maxBytes: oneImageBytes * 2);
    expect(await fixture.render(cache: limited), await fixture.render());
    expect(limited.residentImages, 2);
    expect(limited.evictions, 18);
    expect(limited.estimatedRgbaBytes, lessThanOrEqualTo(limited.maxBytes));
    final transient = WorldHeightCachedRenderer(maxBytes: 1);
    expect(await fixture.render(cache: transient), await fixture.render());
    expect(transient.residentImages, 0);
    expect(transient.disposedImages, 20);
    for (final renderer in [cache, limited, transient]) {
      renderer.dispose();
      expect(renderer.disposedImages, renderer.cacheMisses);
    }
    fixture.dispose();
  });

  test('caps resident images and disposes replacements, removals and teardown',
      () async {
    final cache = WorldHeightCachedRenderer(maxImages: 2);
    final fixture = _Fixture(program);
    await fixture.render(cache: cache);
    expect(cache.residentImages, 2);
    expect(cache.evictions, 8);
    expect(cache.disposedImages, 8);
    cache.removeCone(8);
    expect(cache.residentImages, 1);
    expect(cache.disposedImages, 9);
    cache.clear();
    expect(cache.residentImages, 0);
    expect(cache.estimatedRgbaBytes, 0);
    expect(cache.disposedImages, 10);
    await fixture.render(cache: cache);
    expect(cache.residentImages, 2);
    cache.dispose();
    expect(cache.disposedImages, cache.cacheMisses);
    await expectLater(fixture.render(cache: cache), throwsStateError);
    expect(() => WorldHeightCachedRenderer(maxImages: 0), throwsRangeError);
    expect(() => WorldHeightCachedRenderer(maxBytes: 0), throwsRangeError);
    fixture.dispose();
  });
}

class _Fixture {
  _Fixture(FragmentProgram program, {this.coneCount = 10})
      : freshShaders =
            List.generate(coneCount, (_) => program.fragmentShader()),
        cachedShaders =
            List.generate(coneCount, (_) => program.fragmentShader());
  final int coneCount;
  final List<FragmentShader> freshShaders;
  final List<FragmentShader> cachedShaders;
  final fresh = WorldHeightRenderer();
  late final meshes = List.generate(
      coneCount,
      (i) => Float32List.fromList([
            8 + i * .13,
            -70,
            100,
            -70,
            100,
            70,
            8 + i * .13,
            -70,
            100,
            70,
            8 + i * .13,
            70,
            -60,
            21 + i * .17,
            3,
            21 + i * .17,
            -15,
            90,
          ]));
  late final keys = List<Object>.generate(coneCount, (_) => Object());
  late final origins = List.generate(
      coneCount, (i) => Offset(30 + (i % 5) * 56, 40 + (i ~/ 5) * 146));
  late final facings = List.generate(coneCount, (i) => i * .47);
  late final ranges = List<double>.filled(coneCount, 40);
  late final cones = List<double>.filled(coneCount, 103 * math.pi / 180);
  var projection = VisionWorldProjection(
      origin: Offset.zero,
      axisU: const Offset(3.4, .5),
      axisV: const Offset(-.3, 2.9));
  var scale = 1.25;
  var devicePixelRatio = 1.0;
  var zoom = 1.0;
  var viewport = const Rect.fromLTWH(0, 0, 450, 360);
  var color = const Color(0x806bd43d);
  var clearanceMeters = 0.0;
  var radialFalloff = 0.0;
  var background = true;
  final receiver = WorldReceiverMask.parse('''<svg viewBox="0 0 340 260">
    <path fill="#271406" fill-rule="evenodd" d="M0 0H310V260H0Z M110 90H200V155H110Z"/>
    <path fill="#271406" d="M320 20H339V100H320Z"/>
  </svg>''');

  Future<Uint8List> render({WorldHeightCachedRenderer? cache}) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    if (background) canvas.drawColor(const Color(0xff24313b), BlendMode.src);
    canvas.scale(devicePixelRatio);
    canvas.translate(6.23, 7.47);
    canvas.scale(scale * zoom);
    try {
      paintWorldReceiverVisibility(
          canvas: canvas,
          receiver: receiver,
          paintVisibility: (canvas) {
            for (var i = 0; i < coneCount; i++) {
              if (cache == null) {
                fresh.paintCone(
                    canvas,
                    meshes[i],
                    projection,
                    origins[i],
                    facings[i],
                    ranges[i],
                    cones[i],
                    scale * zoom * devicePixelRatio,
                    color,
                    freshShaders[i],
                    clearanceMeters: clearanceMeters,
                    radialFalloff: radialFalloff);
              } else {
                cache.paintCone(
                    canvas,
                    meshes[i],
                    projection,
                    origins[i],
                    facings[i],
                    ranges[i],
                    cones[i],
                    scale * zoom * devicePixelRatio,
                    color,
                    cachedShaders[i],
                    coneId: i,
                    meshKey: keys[i],
                    viewport: viewport,
                    clearanceMeters: clearanceMeters,
                    radialFalloff: radialFalloff);
              }
            }
          });
      final picture = recorder.endRecording();
      final image = await picture.toImage(
          (470 * devicePixelRatio).ceil(), (375 * devicePixelRatio).ceil());
      picture.dispose();
      final bytes = (await image.toByteData(format: ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      image.dispose();
      return bytes;
    } catch (_) {
      if (recorder.isRecording) recorder.endRecording().dispose();
      rethrow;
    }
  }

  void dispose() {
    for (final shader in [...freshShaders, ...cachedShaders]) {
      shader.dispose();
    }
  }
}
