import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

import 'world_height_cached_renderer.dart';
import 'world_height_render.dart';
import 'world_receiver_compositor.dart';
import 'world_receiver_mask.dart';

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
    expect(() => WorldHeightCachedRenderer(maxImages: 11), throwsRangeError);
    fixture.dispose();
  });
}

class _Fixture {
  _Fixture(FragmentProgram program)
      : freshShaders = List.generate(10, (_) => program.fragmentShader()),
        cachedShaders = List.generate(10, (_) => program.fragmentShader());
  final List<FragmentShader> freshShaders;
  final List<FragmentShader> cachedShaders;
  final fresh = WorldHeightRenderer();
  final meshes = List.generate(
      10,
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
  final keys = List<Object>.generate(10, (_) => Object());
  final origins =
      List.generate(10, (i) => Offset(30 + (i % 5) * 56, 40 + (i ~/ 5) * 146));
  final facings = List.generate(10, (i) => i * .47);
  final ranges = List<double>.filled(10, 40);
  final cones = List<double>.filled(10, 103 * math.pi / 180);
  var projection = VisionWorldProjection(
      origin: Offset.zero,
      axisU: const Offset(3.4, .5),
      axisV: const Offset(-.3, 2.9));
  var scale = 1.25;
  var viewport = const Rect.fromLTWH(0, 0, 450, 360);
  var color = const Color(0x806bd43d);
  var clearanceMeters = 0.0;
  var background = true;
  final receiver = WorldReceiverMask.parse('''<svg viewBox="0 0 340 260">
    <path fill="#271406" fill-rule="evenodd" d="M0 0H310V260H0Z M110 90H200V155H110Z"/>
    <path fill="#271406" d="M320 20H339V100H320Z"/>
  </svg>''');

  Future<Uint8List> render({WorldHeightCachedRenderer? cache}) async {
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    if (background) canvas.drawColor(const Color(0xff24313b), BlendMode.src);
    canvas.translate(6.23, 7.47);
    canvas.scale(scale);
    try {
      paintWorldReceiverVisibility(
          canvas: canvas,
          receiver: receiver,
          paintVisibility: (canvas) {
            for (var i = 0; i < 10; i++) {
              if (cache == null) {
                fresh.paintCone(
                    canvas,
                    meshes[i],
                    projection,
                    origins[i],
                    facings[i],
                    ranges[i],
                    cones[i],
                    scale,
                    color,
                    freshShaders[i],
                    clearanceMeters: clearanceMeters);
              } else {
                cache.paintCone(
                    canvas,
                    meshes[i],
                    projection,
                    origins[i],
                    facings[i],
                    ranges[i],
                    cones[i],
                    scale,
                    color,
                    cachedShaders[i],
                    coneId: i,
                    meshKey: keys[i],
                    viewport: viewport,
                    clearanceMeters: clearanceMeters);
              }
            }
          });
      final picture = recorder.endRecording();
      final image = await picture.toImage(470, 375);
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
