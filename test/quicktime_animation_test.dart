import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/quicktime_animation_sink.dart';

const _width = 300;
const _height = 24;
const _fps = 30;

String? _onPath(String tool) {
  try {
    final result = Process.runSync(
      Platform.isWindows ? 'where' : 'which',
      [tool],
    );
    if (result.exitCode != 0) return null;
    return const LineSplitter().convert(result.stdout as String).first.trim();
  } on ProcessException {
    return null;
  }
}

final String? _ffmpeg = _onPath('ffmpeg');
final String? _ffprobe = _onPath('ffprobe');

Uint8List _frame(void Function(int x, int y, List<int> rgba) paint) {
  final bytes = Uint8List(_width * _height * 4);
  final pixel = [0, 0, 0, 0];
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      paint(x, y, pixel);
      bytes.setRange((y * _width + x) * 4, (y * _width + x + 1) * 4, pixel);
    }
  }
  return bytes;
}

void main() {
  test('a transparent video decodes back to every frame, pixel for pixel',
      () async {
    final random = math.Random(7);
    // Transparent around a half-transparent band and an opaque block.
    final base = _frame((x, y, p) {
      if (y >= 4 && y < 8) {
        p.setAll(0, [255, 171, 64, 100]);
      } else if (y >= 10 && y < 20 && x >= 40 && x < 260) {
        p.setAll(0, [40, 20, 6, 255]);
      } else {
        p.setAll(0, [0, 0, 0, 0]);
      }
    });
    // A few pixels change mid-row, so rows open with and contain skips
    // longer than one skip code holds.
    final touched = Uint8List.fromList(base);
    for (final x in [2, 270, 271, 299]) {
      touched.setAll((12 * _width + x) * 4, [255, 0, 255, 255]);
    }
    // Noise (literal runs past 127) beside one colour (repeats past 128).
    final busy = _frame((x, y, p) {
      if (x < 150) {
        p.setAll(0, [
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        ]);
      } else {
        p.setAll(0, [12, 200, 90, 180]);
      }
    });

    // Each frame and how many ticks it holds: the base holds past the
    // two-second keyframe interval; the second frame of [touched] changes
    // nothing.
    final frames = [
      (base, 70),
      (touched, 1),
      (touched, 1),
      (busy, 3),
      (base, 1),
    ];
    final sink = QuickTimeAnimationSink(fps: _fps);
    await sink.start(
      width: _width,
      height: _height,
      totalFrames: frames.length,
      totalSeconds: 76 / _fps,
    );
    for (final (rgba, ticks) in frames) {
      await sink.addFrame(rgba, ticks / _fps);
    }
    final video = (await sink.finish())!;

    final dir = await Directory.systemTemp.createTemp('icarus_qtrle');
    addTearDown(() => dir.delete(recursive: true));
    final movPath = '${dir.path}${Platform.pathSeparator}out.mov';
    await File(movPath).writeAsBytes(video);
    final decoded = await Process.run(
      _ffmpeg!,
      [
        '-v',
        'error',
        '-i',
        movPath,
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgba',
        '-',
      ],
      stdoutEncoding: null,
    );
    expect(decoded.exitCode, 0, reason: '${decoded.stderr}');

    final expected = BytesBuilder();
    for (final (rgba, ticks) in frames) {
      for (var i = 0; i < ticks; i++) {
        expected.add(rgba);
      }
    }
    // Clipchamp ends a clip at its last keyframe, so the file ends on one.
    final keyFrames = await Process.run(_ffprobe!, [
      '-v',
      'error',
      '-select_streams',
      'v:0',
      '-show_entries',
      'packet=flags',
      '-of',
      'csv=p=0',
      movPath,
    ]);
    final flags = const LineSplitter().convert('${keyFrames.stdout}');
    expect(flags, hasLength(76));
    expect(flags.last, startsWith('K'));

    final actual = Uint8List.fromList(decoded.stdout as List<int>);
    final want = expected.takeBytes();
    expect(actual.length, want.length);
    final frameBytes = _width * _height * 4;
    for (var f = 0; f < want.length ~/ frameBytes; f++) {
      expect(
        actual.sublist(f * frameBytes, (f + 1) * frameBytes),
        want.sublist(f * frameBytes, (f + 1) * frameBytes),
        reason: 'frame $f',
      );
    }
  }, skip: _ffmpeg == null || _ffprobe == null);
}
