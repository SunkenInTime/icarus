import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/svg_height_visibility.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/svg_height_view_cone.dart';

SvgHeightVisibility loadModel(String side) {
  final folder = const bool.fromEnvironment('ICARUS_VERIFY_BUNDLED_GAMEPLAY')
      ? null
      : Platform.environment['ICARUS_ICEBOX_WINDOW_MODELS'];
  final path = folder == null
      ? 'assets/maps/icebox_svg_height_$side.json.gz'
      : '$folder/candidate-$side.json.gz';
  return SvgHeightVisibility.fromJson(
      jsonDecode(utf8.decode(gzip.decode(File(path).readAsBytesSync()))));
}

ui.Offset paired(String side, ui.Offset p) =>
    side == 'attack' ? p : const ui.Offset(387.459, 473) - p;
ui.Offset offset(List p) =>
    ui.Offset((p[0] as num).toDouble(), (p[1] as num).toDouble());
ui.Path visibility(SvgVisibilityCone cone) =>
    cone.visibilityPath ?? (ui.Path()..addPolygon(cone.polygon, true));

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/icebox_front_window.json').readAsStringSync());
  final rows = fixture['rays'] as List;
  for (final side in ['attack', 'defense']) {
    test(
        'Icebox $side front window projects all 36 independently checked target rays',
        () {
      final model = loadModel(side);
      expect(model.sightlineFloors.map((s) => s.id),
          contains('icebox-measured-volume-129-0'));
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final origin = paired(side, offset(row['start']));
        final target = paired(side, offset(row['target']));
        final support = model.automaticSupportAt(origin)!;
        expect(support.surfaceElevationAt(origin), closeTo(5.75, .00001));
        final direction = target - origin;
        late SvgVisibilityCone cone;
        try {
          cone = model.cone(
              origin: origin,
              directionRadians: math.atan2(direction.dy, direction.dx),
              range: 60,
              apertureRadians: math.pi / 3,
              supportId: support.id);
        } catch (error, stack) {
          fail(
              '$side ray $index origin=$origin target=$target: $error\n$stack');
        }
        // Source XY and SVG artwork differ at the jamb and front facade.
        // Fixture keeps original source booleans and exact analytic authored
        // volume expectations separately; these are never treated as identical.
        expect(visibility(cone).contains(target), row['authoredClear'],
            reason: 'ray $index');
      }
      expect(rows.where((r) => r['clear'] == true).length, 18);
      expect(rows.where((r) => r['clear'] != r['authoredClear']).length, 10);
    });

    test('Icebox $side front window keeps base, header, and both thick jambs',
        () {
      final model = loadModel(side);
      for (final x in [322.2, 324.2, 326.2, 328.2]) {
        final origin = paired(side, ui.Offset(x, 151.3));
        final target = paired(side, ui.Offset(x, 165.7));
        final delta = target - origin;
        for (final eye in [6.0, 7.5, 8.1, 18.9]) {
          final hit = model.castRay(
              origin: origin,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: delta.distance,
              absoluteEyeElevationMeters: eye);
          expect(hit == null, eye == 7.5, reason: 'x=$x eye=$eye');
        }
      }
      for (final x in [321.69, 330.1]) {
        final origin = paired(side, ui.Offset(x, 151.3));
        final target = paired(side, ui.Offset(x, 165.7));
        final delta = target - origin;
        expect(
            model.castRay(
                origin: origin,
                directionRadians: math.atan2(delta.dy, delta.dx),
                range: delta.distance,
                absoluteEyeElevationMeters: 7.5),
            isNotNull);
      }
    });

    test('Icebox $side moving past the jamb keeps projected paths valid', () {
      final model = loadModel(side);
      // The original defense pose threw in Path.combine when four thin
      // projected faces overlapped. Exercise both sides of that exact pose.
      for (final shift in [-.1, -.01, -.0001, 0.0, .0001, .01, .1]) {
        final origin = paired(
            side, ui.Offset(321.6931000000001 + shift, 151.29513753901537));
        final support = model.automaticSupportAt(origin)!;
        for (final y in [160.23, 166.23]) {
          final target = paired(side, ui.Offset(321.6930999999999, y));
          final delta = target - origin;
          final cone = model.cone(
              origin: origin,
              directionRadians: math.atan2(delta.dy, delta.dx),
              range: 60,
              apertureRadians: math.pi / 3,
              supportId: support.id);
          final bounds = visibility(cone).getBounds();
          expect(bounds.isFinite, isTrue);
        }
      }
    });

    test(
        'Icebox $side production painter sees farther while sill hides near floor',
        () async {
      final model = loadModel(side);
      final origin =
          paired(side, const ui.Offset(326.1215, 151.29513753901537));
      final near = paired(side, const ui.Offset(326.1215, 159.73));
      final far = paired(side, const ui.Offset(326.1215, 165.73));
      final support = model.automaticSupportAt(origin)!;
      final delta = far - origin;
      final cone = model.cone(
          origin: origin,
          directionRadians: math.atan2(delta.dy, delta.dx),
          range: 60,
          apertureRadians: math.pi / 3,
          supportId: support.id);
      final receiver = ui.Path()..fillType = ui.PathFillType.evenOdd;
      for (final region in model.receivers) {
        for (final ring in region.rings) {
          receiver.addPolygon(ring, true);
        }
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..scale(4);
      SvgHeightViewConePainter.fromPaths(
              visibility: visibility(cone),
              receiver: receiver,
              apex: origin,
              radius: 60)
          .paint(canvas, const ui.Size(387.459, 473));
      final picture = recorder.endRecording();
      final image = await picture.toImage(1550, 1892);
      final pixels =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      int alpha(ui.Offset p) => pixels
          .getUint8(((p.dy * 4).floor() * 1550 + (p.dx * 4).floor()) * 4 + 3);
      expect(alpha(near), 0, reason: 'The sill occludes the near lower floor.');
      expect(alpha(far), greaterThan(0),
          reason: 'The farther lower floor is visible through the window.');
      final output = Platform.environment['ICARUS_ICEBOX_WINDOW_OUTPUT'];
      if (output != null) {
        Directory(output).createSync(recursive: true);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        File('$output/painter-$side.png')
            .writeAsBytesSync(png.buffer.asUint8List());
      }
      image.dispose();
      picture.dispose();
    });
  }
}
