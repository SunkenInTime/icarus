// Detailed crops use the production cone painter and unchanged SVG artwork.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:cryptography_plus/cryptography_plus.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

const _root = 'E:/IcarusWorldAudit/2026-09-06/tactical-visibility-revision';
const _dll =
    'C:/Users/shawn/AppData/Local/Temp/icarus-svg-height-native-build/Release/icarus_height.dll';

Path pathFor(List<List<Offset>> rings, bool evenOdd) {
  final path = Path()
    ..fillType = evenOdd ? PathFillType.evenOdd : PathFillType.nonZero;
  for (final ring in rings) {
    path.addPolygon(ring, true);
  }
  return path;
}

double boundaryDistance(List<Offset> a, List<Offset> b) {
  double directed(List<Offset> first, List<Offset> second) {
    var maximum = 0.0;
    for (final p in first) {
      var nearest = double.infinity;
      for (var i = 0; i < second.length; i++) {
        final start = second[i],
            delta = second[(i + 1) % second.length] - start;
        final length = delta.distanceSquared;
        final t = length == 0
            ? 0.0
            : (((p - start).dx * delta.dx + (p - start).dy * delta.dy) / length)
                .clamp(0.0, 1.0);
        nearest = math.min(nearest, (p - start - delta * t).distance);
      }
      maximum = math.max(maximum, nearest);
    }
    return maximum;
  }

  return math.max(directed(a, b), directed(b, a));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('review every wall and explicit top through native and reference cones',
      () async {
    final selection = Platform.environment['ICARUS_REVIEW_MAP']!;
    final names = selection == 'all'
        ? 'abyss ascent bind breeze corrode fracture haven icebox lotus pearl split summit sunset'
            .split(' ')
        : [selection];
    for (final name in names) {
      final models = Platform.environment['ICARUS_REVIEW_MODELS'] ??
          '$_root/all-map-svg-height-reviewed-v1';
      final casesPath = Platform.environment['ICARUS_REVIEW_CASES']
              ?.replaceAll('{map}', name) ??
          '$_root/all-map-svg-review-cases-v1/$name.json';
      final output = Directory(
          '${Platform.environment['ICARUS_REVIEW_OUTPUT']!}${selection == 'all' ? '/$name' : ''}');
      if (output.existsSync()) throw StateError('Choose a fresh case output');
      output.createSync(recursive: true);
      final cases =
          (jsonDecode(File(casesPath).readAsStringSync())['cases'] as List)
              .cast<Map<String, dynamic>>();
      final records = <Map<String, dynamic>>[];
      for (final side in ['attack', 'defense']) {
        final data =
            jsonDecode(File('$models/$name-$side.json').readAsStringSync())
                as Map<String, dynamic>;
        final model = SvgHeightVisibility.fromJson(data),
            reference = SvgHeightVisibility.fromJson(data);
        expect(
            model.enableNativeAcceleration(
                libraryPath:
                    Platform.environment['ICARUS_SVG_NATIVE_LIBRARY'] ?? _dll),
            isTrue);
        final artwork = await vg.loadPicture(
            SvgStringLoader(File(
                    'assets/maps/${name}_map${side == 'defense' ? '_defense' : ''}.svg')
                .readAsStringSync()),
            null);
        Path? receiver;
        for (final row in model.receivers) {
          final next = pathFor(row.rings, row.evenOdd);
          receiver = receiver == null
              ? next
              : Path.combine(PathOperation.union, receiver, next);
        }
        try {
          for (final row in cases.where((r) => r['side'] == side)) {
            if (row['status'] != null) {
              records.add(row);
              continue;
            }
            Offset point(String key) {
              final xy = row[key] as List;
              return Offset(
                  (xy[0] as num).toDouble(), (xy[1] as num).toDouble());
            }

            final origin = point('originSvg'), center = point('centerSvg');
            SvgVisibilityCone query(SvgHeightVisibility engine) => engine.cone(
                origin: origin,
                directionRadians: (row['directionRadians'] as num).toDouble(),
                range: (row['rangeSvg'] as num).toDouble(),
                apertureRadians: (row['apertureRadians'] as num).toDouble(),
                absoluteEyeElevationMeters:
                    (row['absoluteEyeElevationMeters'] as num?)?.toDouble(),
                supportId: row['automatic'] == true
                    ? engine.automaticSupportAt(origin)?.id
                    : row['supportId'] as String?);
            final queryTimer = Stopwatch()..start();
            final cone = query(model);
            queryTimer.stop();
            final expected = query(reference);
            final difference = boundaryDistance(cone.polygon, expected.polygon);
            expect(difference, lessThan(1e-6), reason: row['id'] as String);
            if (row['expectedEyeElevationMeters'] != null)
              expect(
                  cone.eyeElevationMeters,
                  closeTo((row['expectedEyeElevationMeters'] as num).toDouble(),
                      1e-6));
            if (row['render'] == false) {
              records.add({
                ...row,
                'map': name,
                'polygonSvg': [
                  for (final p in cone.polygon) [p.dx, p.dy]
                ],
                'activeWallIds': [
                  for (final wall in model.walls)
                    if (wall.blocks(cone.eyeElevationMeters!)) wall.id
                ],
                'eyeElevationMeters': cone.eyeElevationMeters,
                'nativeReferenceBoundaryDifferenceSvg': difference,
                'nativeQueryMicroseconds': cone.stats.nativeMicros,
                'queryWithStandingMicroseconds': queryTimer.elapsedMicroseconds,
                'vertices': cone.polygon.length,
                'status': 'verified'
              });
              continue;
            }
            final recorder = ui.PictureRecorder();
            final canvas = Canvas(recorder);
            final crop = (row['cropSizeSvg'] as num).toDouble();
            const pixels = 400;
            canvas.drawColor(
                Settings.tacticalVioletTheme.background, BlendMode.src);
            canvas.scale(pixels / crop);
            canvas.translate(crop / 2 - center.dx, crop / 2 - center.dy);
            canvas.drawPicture(artwork.picture);
            SvgHeightViewConePainter.fromPaths(
                    visibility: pathFor([cone.polygon], false),
                    receiver: receiver!,
                    apex: origin,
                    radius: (row['rangeSvg'] as num).toDouble())
                .paint(canvas, artwork.size);
            canvas.drawCircle(origin, .9, Paint()..color = Colors.tealAccent);
            final picture = recorder.endRecording();
            final image = await picture.toImage(pixels, pixels);
            final bytes =
                await image.toByteData(format: ui.ImageByteFormat.png);
            final filename = '${row['id']}.png';
            await File('${output.path}/$filename')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
            picture.dispose();
            records.add({
              ...row,
              'map': name,
              'activeWallIds': [
                for (final wall in model.walls)
                  if (wall.blocks(cone.eyeElevationMeters!)) wall.id
              ],
              'polygonSvg': [
                for (final p in cone.polygon) [p.dx, p.dy]
              ],
              'image': filename,
              'nativeReferenceBoundaryDifferenceSvg': difference,
              'eyeElevationMeters': cone.eyeElevationMeters,
              'vertices': cone.polygon.length,
              'nativeQueryMicroseconds': cone.stats.nativeMicros,
              'queryWithStandingMicroseconds': queryTimer.elapsedMicroseconds,
              'receiverContainsOrigin': model.receiverContains(origin),
              'status': cone.polygon.length < 3
                  ? 'empty-cone-needs-review'
                  : 'rendered'
            });
          }
        } finally {
          artwork.picture.dispose();
          model.closeNativeAcceleration();
          reference.closeNativeAcceleration();
        }
      }
      final sourceHash = await Sha256().hash(
          await File('lib/view_cone/svg_height_visibility.dart').readAsBytes());
      await File('${output.path}/manifest.json').writeAsString(jsonEncode({
        'map': name,
        'runtimeSourceSha256': sourceHash.bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(),
        'scope':
            'Per-wall and explicit-top crops with production cone painter. Native/reference agreement checks computation, not live-game truth.',
        'records': records
      }));
      expect(records.where((r) => r['image'] != null), isNotEmpty);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
