// Diagnostic actual Ascent source mesh. No geometry or app asset mutations.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/display_warp.dart';
import 'package:icarus/view_cone/height_cached_renderer.dart';
import 'package:icarus/view_cone/receiver_compositor.dart';
import 'package:icarus/view_cone/receiver_mask.dart';
import 'package:icarus/view_cone/vision_world_projection.dart';

const root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('isolate colored overlay outside actual receiver', () async {
    final output = Directory('$root/receiver-overlay-reproduction-v1');
    await output.create();
    final manifest = jsonDecode(
        await File('$root/ascent-component5-contact-v8/manifest.json')
            .readAsString()) as Map;
    final warp = DisplayWarp.fromJson(jsonDecode(utf8.decode(gzip.decode(
            await File(manifest['displayWarpFile'] as String).readAsBytes())))
        as Map<String, dynamic>);
    final program =
        await ui.FragmentProgram.fromAsset('shaders/world_shadow_radial.frag');
    final reports = <Map<String, dynamic>>[];
    for (final side in ['attack', 'defense']) {
      final row = (manifest['cases'] as List).cast<Map>().singleWhere(
          (r) => r['id'] == 'preserved-opening-15' && r['side'] == side);
      final q =
          (row['query'] as List).map((n) => (n as num).toDouble()).toList();
      final p = (row['projectionRows'] as List)
          .map((r) => (r as List).map((n) => (n as num).toDouble()).toList())
          .toList();
      final projection = VisionWorldProjection(
          origin: ui.Offset(p[0][2], p[1][2]),
          axisU: ui.Offset(p[0][0], p[1][0]),
          axisV: ui.Offset(p[0][1], p[1][1]));
      final bytes = await File('${row['prefix']}-shadow.f32').readAsBytes();
      final mesh = Float32List.view(
          bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
      final svg = await File(
              'assets/maps/ascent_map${side == 'defense' ? '_defense' : ''}.svg')
          .readAsString();
      final receiver = WorldReceiverMask.parse(svg);
      final art = await vg.loadPicture(SvgStringLoader(svg), null);
      final point = side == 'attack'
          ? const ui.Offset(203, 283)
          : const ui.Offset(208, 191);
      expect(receiver.containsReceiver(point), false);
      for (final background in ['none', 'solid', 'art']) {
        for (final style in ['white', 'color', 'falloff', 'rectangle']) {
          final renderer = WorldHeightCachedRenderer();
          final shader = program.fragmentShader();
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder)..scale(8);
          if (background != 'none')
            canvas.drawColor(const ui.Color(0xff101014), ui.BlendMode.src);
          if (background == 'art') canvas.drawPicture(art.picture);
          paintWorldReceiverVisibility(
              canvas: canvas,
              receiver: receiver,
              paintVisibility: (c) {
                if (style == 'rectangle') {
                  c.drawRect(receiver.viewBox,
                      ui.Paint()..color = const ui.Color(0xa000dfba));
                  return;
                }
                renderer.paintCone(
                    c,
                    mesh,
                    projection,
                    projection.toCanvas(ui.Offset(q[0], q[1])),
                    math.atan2(q[4], q[3]),
                    q[5],
                    q[6],
                    8,
                    style == 'white'
                        ? const ui.Color(0xffffffff)
                        : const ui.Color(0xa000dfba),
                    shader,
                    coneId: 'test',
                    meshKey: mesh,
                    viewport: receiver.viewBox,
                    displayWarp: warp,
                    radialFalloff: style == 'falloff' ? 1 : 0);
              });
          final picture = recorder.endRecording();
          final image = await picture.toImage(
              (receiver.viewBox.width * 8).ceil(),
              (receiver.viewBox.height * 8).ceil());
          final data =
              (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
          final pixels =
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
          final offset =
              ((point.dy * 8).toInt() * image.width + (point.dx * 8).toInt()) *
                  4;
          reports.add({
            'side': side,
            'background': background,
            'style': style,
            'point': [point.dx, point.dy],
            'rgba': pixels.sublist(offset, offset + 4)
          });
          image.dispose();
          picture.dispose();
          shader.dispose();
          renderer.dispose();
        }
      }
      art.picture.dispose();
    }
    await File('${output.path}/report.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(reports));
    for (final r in reports) {
      expect(r['rgba'],
          r['background'] == 'none' ? [0, 0, 0, 0] : [16, 16, 20, 255],
          reason: 'An excluded destination must preserve its background: $r');
    }
  });
}
