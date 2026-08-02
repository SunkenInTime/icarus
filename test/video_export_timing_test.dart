import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/video_exporter.dart';

void main() {
  group('VideoExporter frame schedule', () {
    test('derives transition duration from its representable frame count', () {
      expect(VideoExporter.transitionFrameCount, 25);
      expect(
        VideoExporter.encodedTransitionSeconds,
        closeTo(25 / 60, 1e-12),
      );
    });

    test('plans two-page duration from holds and scheduled transition frames',
        () {
      expect(
        VideoExporter.plannedDurationSeconds(
          pageCount: 2,
          stepSeconds: 3,
        ),
        closeTo(6 + 25 / 60, 1e-12),
      );
    });

    test('does not accumulate transition rounding in the final hold', () {
      expect(
        VideoExporter.plannedDurationSeconds(
          pageCount: 3,
          stepSeconds: 3,
        ),
        closeTo(9 + 50 / 60, 1e-12),
      );
    });
  });
}
