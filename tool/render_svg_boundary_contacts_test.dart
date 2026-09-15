// Actual Flutter SVG + production painter, from frozen before/after polygons.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

Path ringsPath(List<List<Offset>> rings, bool evenOdd) {
  final p = Path()
    ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
  for (final r in rings) {
    p.addPolygon(r, true);
  }
  return p;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('render before and after contacts with the production painter',
      () async {
    final root = Platform.environment['ICARUS_BOUNDARY_AUDIT']!;
    final rows =
        jsonDecode(File('$root/raster-cases.json').readAsStringSync()) as List;
    final out = Directory('$root/raster')..createSync(recursive: true);
    for (final row in rows) {
      final name = row['map'], side = row['side'];
      final model = SvgHeightVisibility.fromJson(jsonDecode(utf8.decode(
          gzip.decode(File('assets/maps/${name}_svg_height_$side.json.gz')
              .readAsBytesSync()))));
      final artwork = await vg.loadPicture(
          SvgStringLoader(File(
                  'assets/maps/${name}_map${side == 'defense' ? '_defense' : ''}.svg')
              .readAsStringSync()),
          null);
      final receiver = ringsPath(
          model.receivers.single.rings, model.receivers.single.evenOdd);
      final origin = Offset((row['originSvg'][0] as num).toDouble(),
          (row['originSvg'][1] as num).toDouble());
      final center = Offset((row['centerSvg'][0] as num).toDouble(),
          (row['centerSvg'][1] as num).toDouble());
      final width = (row['widthSvg'] as num?)?.toDouble() ?? 24;
      final pixels = (row['pixels'] as num?)?.toInt() ?? 768;
      for (final version in ['before', 'current']) {
        final points = [
          for (final p in row[version])
            Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
        ];
        for (final mask in [false, true]) {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          if (!mask) canvas.drawColor(const Color(0xff101014), BlendMode.src);
          canvas.scale(pixels / width);
          canvas.translate(width / 2 - center.dx, width / 2 - center.dy);
          if (mask) {
            canvas.clipPath(receiver);
            canvas.drawPath(
                ringsPath([points], false), Paint()..color = Colors.white);
          } else {
            canvas.drawPicture(artwork.picture);
            SvgHeightViewConePainter.fromPaths(
                    visibility: ringsPath([points], false),
                    receiver: receiver,
                    apex: origin,
                    radius: (row['range'] as num?)?.toDouble() ?? 90)
                .paint(canvas, artwork.size);
            if (row['markOrigin'] == true) {
              canvas.drawCircle(
                  origin, width / 100, Paint()..color = Colors.white);
            }
          }
          final picture = recorder.endRecording();
          final image = await picture.toImage(pixels, pixels);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
                  '${out.path}/${row['id']}-$version${mask ? '-coverage' : ''}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
        }
      }
      artwork.picture.dispose();
    }
    expect(rows, isNotEmpty);
  });
}
