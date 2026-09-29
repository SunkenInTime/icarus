import 'package:icarus/services/video_export/video_export_quality.dart';
import 'package:icarus/services/video_export/video_frame_sink.dart';

/// Whether this browser can encode a [totalSeconds] video at [quality].
/// Never, off the web.
Future<bool> browserCanEncodeVideo(
  VideoExportQuality quality, {
  required double totalSeconds,
}) async =>
    false;

/// Encodes in the browser. Off the web there is no browser to encode in.
VideoFrameSink createBrowserVideoSink(VideoExportQuality quality) =>
    throw UnsupportedError('Browser video encoding exists only on the web.');
