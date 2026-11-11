import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/widgets/dialogs/export_video_dialog.dart';

void main() {
  group('videoExportQualityCaption', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    test('states each option\'s distinguishing fact, no encoder vocabulary',
        () {
      expect(
          videoExportQualityCaption(l10n, VideoExportQuality.potato), '~10 MB');
      expect(
          videoExportQualityCaption(l10n, VideoExportQuality.social), '~20 MB');
      expect(
        videoExportQualityCaption(l10n, VideoExportQuality.max),
        '60 fps, no size cap',
      );
    });
  });
}
