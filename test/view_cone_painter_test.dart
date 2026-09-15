import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('physical cone paints its projected FOV beyond the screen-space wedge',
      () async {
    Future<ByteData> render({required bool physical}) async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      ViewConePainter(
        angle: 90,
        length: 50,
        visibilityPolygon: const [
          ui.Offset(100, 100),
          ui.Offset(29.289, 64.644),
          ui.Offset(100, 50),
          ui.Offset(170.711, 64.644),
        ],
        rangeEllipseAxes:
            physical ? const [ui.Offset(100, 0), ui.Offset(0, 50)] : null,
      ).paint(canvas, const ui.Size(200, 100));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 100);
      final data =
          (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      image.dispose();
      picture.dispose();
      return data;
    }

    final physical = await render(physical: true);
    final legacy = await render(physical: false);
    int alpha(ByteData data, int x, int y) =>
        data.getUint8((y * 200 + x) * 4 + 3);
    expect(alpha(physical, 140, 70), greaterThan(0));
    expect(alpha(legacy, 140, 70), 0);
    expect(alpha(physical, 170, 70), 0,
        reason: 'The polygon still clips points outside physical FOV.');
  });

  test('degenerate clipped polygons paint no cone pixels', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    ViewConePainter(
      angle: 60,
      length: 50,
      visibilityPolygon: const [ui.Offset(50, 100)],
    ).paint(canvas, const ui.Size(100, 100));

    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 100);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    for (var index = 3; index < bytes!.lengthInBytes; index += 4) {
      expect(bytes.getUint8(index), 0, reason: 'alpha byte $index');
    }
    image.dispose();
    picture.dispose();
  });
}
