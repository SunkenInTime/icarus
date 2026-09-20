import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/widgets/draggable_widgets/utilities/view_cone_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
