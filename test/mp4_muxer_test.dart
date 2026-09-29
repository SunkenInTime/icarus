import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/services/video_export/mp4_muxer.dart';

import 'mp4_box_test_support.dart';

void main() {
  group('Mp4H264Muxer box structure', () {
    // Fake AVCC samples: the muxer never looks inside them.
    Uint8List sample(int seed, int length) => Uint8List.fromList(
        List.generate(length, (i) => (seed * 31 + i) & 0xFF));
    final avcC = Uint8List.fromList(
      [1, 0x64, 0x00, 0x28, 0xFF, 0xE1, 0, 2, 0x67, 0x64, 1, 0, 2, 0x68, 0xEE],
    );

    test('lays out ftyp, moov, mdat with the chunk offset on sample one', () {
      final muxer = Mp4H264Muxer(width: 1920, height: 1080);
      final samples = [
        sample(1, 100),
        sample(2, 37),
        sample(3, 51),
        sample(4, 9),
        sample(5, 64),
      ];
      final durations = [270000, 3000, 3000, 1500, 3000];
      final keys = [true, false, false, true, false];
      for (var i = 0; i < samples.length; i++) {
        muxer.addSample(samples[i],
            duration: durations[i], isKeyFrame: keys[i]);
      }
      final file = muxer.finish(avcDecoderConfig: avcC);
      final mp4 = Mp4Boxes(file);

      expect(mp4.topLevelTypes, ['ftyp', 'moov', 'mdat']);

      final ftyp = mp4.find(['ftyp']);
      expect(String.fromCharCodes(ftyp.payload(file).sublist(0, 4)), 'isom');

      final offsets = mp4.chunkOffsets();
      expect(offsets, hasLength(1));
      final mdat = mp4.find(['mdat']);
      expect(offsets.single, mdat.start + mdat.headerSize);
      var cursor = offsets.single;
      final sizes = mp4.sampleSizes();
      expect(sizes, [for (final s in samples) s.length]);
      for (var i = 0; i < samples.length; i++) {
        expect(file.sublist(cursor, cursor + sizes[i]), samples[i]);
        cursor += sizes[i];
      }
      expect(cursor, file.length);

      expect(mp4.sampleDurations(), durations);
      expect(mp4.stts(), [
        [1, 270000],
        [2, 3000],
        [1, 1500],
        [1, 3000],
      ]);
      expect(mp4.syncSamples(), [1, 4]);
      expect(mp4.mediaTimescale(), 90000);
      expect(mp4.mediaDuration(), 280500);
      expect(mp4.movieDuration(), 280500);
      expect(mp4.trackSize(), (1920, 1080));
      expect(mp4.samplesPerChunk(), samples.length);
      expect(
        mp4.find(['moov', 'trak', 'mdia', 'hdlr']).payload(file).sublist(8, 12),
        'vide'.codeUnits,
      );

      final avc1 = mp4.sampleEntry();
      expect(avc1.type, 'avc1');
      final avcCBox = mp4.childrenOf(avc1, entryHeaderSize: 78).single;
      expect(avcCBox.type, 'avcC');
      expect(avcCBox.payload(file), avcC);
    });

    test('describes the samples\' colour after avcC when told it', () {
      final muxer = Mp4H264Muxer(width: 640, height: 360)
        ..addSample(sample(1, 10), duration: 1000, isKeyFrame: true);
      final file = muxer.finish(
        avcDecoderConfig: avcC,
        color: const Mp4ColorInfo(
          primaries: 1,
          transfer: 13,
          matrix: 1,
          fullRange: true,
        ),
      );
      final mp4 = Mp4Boxes(file);
      final children = mp4.childrenOf(mp4.sampleEntry(), entryHeaderSize: 78);
      expect([for (final box in children) box.type], ['avcC', 'colr']);
      expect(
        children.last.payload(file),
        [...'nclx'.codeUnits, 0, 1, 0, 13, 0, 1, 0x80],
      );

      final undescribed = Mp4Boxes(
        (Mp4H264Muxer(width: 640, height: 360)
              ..addSample(sample(1, 10), duration: 1000, isKeyFrame: true))
            .finish(avcDecoderConfig: avcC),
      );
      expect(
        [
          for (final box in undescribed.childrenOf(
            undescribed.sampleEntry(),
            entryHeaderSize: 78,
          ))
            box.type,
        ],
        ['avcC'],
      );
    });

    test('omits stss when every sample is a keyframe', () {
      final muxer = Mp4H264Muxer(width: 640, height: 360, timescale: 30000)
        ..addSample(sample(1, 10), duration: 1000, isKeyFrame: true)
        ..addSample(sample(2, 10), duration: 1000, isKeyFrame: true);
      final mp4 = Mp4Boxes(muxer.finish(avcDecoderConfig: avcC));
      expect(mp4.syncSamples(), isNull);
      expect(mp4.stts(), [
        [2, 1000],
      ]);
    });

    test('refuses an empty file and a non-keyframe start', () {
      expect(
        () => Mp4H264Muxer(width: 640, height: 360)
            .finish(avcDecoderConfig: avcC),
        throwsStateError,
      );
      expect(
        () => Mp4H264Muxer(width: 640, height: 360)
            .addSample(sample(1, 10), duration: 1, isKeyFrame: false),
        throwsStateError,
      );
      expect(
        () => Mp4H264Muxer(width: 640, height: 360)
            .addSample(sample(1, 10), duration: 0, isKeyFrame: true),
        throwsArgumentError,
      );
    });
  });

  group('Mp4H264Muxer with a real H.264 stream', () {
    final ffmpegMissing = _ffmpegMissingReason();

    test(
      'produces a file ffprobe and ffmpeg read back exactly',
      () async {
        final dir = await Directory.systemTemp.createTemp('icarus_mp4_muxer_');
        addTearDown(() => dir.delete(recursive: true));
        final annexBPath = '${dir.path}${Platform.pathSeparator}in.h264';
        final outPath = '${dir.path}${Platform.pathSeparator}out.mp4';

        // No B-frames (the muxer writes no composition offsets), an access
        // unit delimiter before every frame so the stream splits cleanly, and
        // an IDR every 5 frames so stss has several entries.
        final encode = await Process.run('ffmpeg', [
          '-v', 'error', '-y', //
          '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10',
          '-frames:v', '20',
          '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
          '-x264-params', 'aud=1:bframes=0:keyint=5:min-keyint=5:scenecut=0',
          '-bsf:v', 'h264_mp4toannexb',
          '-f', 'h264', annexBPath,
        ]);
        expect(encode.exitCode, 0, reason: '${encode.stderr}');

        final stream = _AnnexBStream.parse(
          await File(annexBPath).readAsBytes(),
        );
        expect(stream.accessUnits, hasLength(20));

        final muxer = Mp4H264Muxer(width: 320, height: 240);
        // First frame held for 3 s, the rest at 1/10 s: 3 + 19 * 0.1 = 4.9 s.
        for (var i = 0; i < stream.accessUnits.length; i++) {
          final unit = stream.accessUnits[i];
          muxer.addSample(
            unit.avcc,
            duration: i == 0 ? 270000 : 9000,
            isKeyFrame: unit.isKeyFrame,
          );
        }
        // libx264 writes no colour description; the container says the
        // samples are full range, and players must believe it.
        final bytes = muxer.finish(
          avcDecoderConfig: stream.avcDecoderConfig,
          color: const Mp4ColorInfo(
            primaries: 1,
            transfer: 1,
            matrix: 1,
            fullRange: true,
          ),
        );
        await File(outPath).writeAsBytes(bytes);

        expect(Mp4Boxes(bytes).syncSamples(), [1, 6, 11, 16]);

        final probe = await Process.run('ffprobe', [
          '-v', 'error', //
          '-count_frames',
          '-show_streams', '-show_format',
          outPath,
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        final fields = _probeFields(probe.stdout as String);
        expect(fields['codec_name'], 'h264');
        expect(fields['color_range'], 'pc');
        expect(fields['color_space'], 'bt709');
        expect(fields['width'], '320');
        expect(fields['height'], '240');
        expect(fields['nb_read_frames'], '20');
        expect(fields['nb_frames'], '20');
        expect(double.parse(fields['format.duration']!), closeTo(4.9, 0.001));
        expect(double.parse(fields['stream.duration']!), closeTo(4.9, 0.001));

        final decode = await Process.run('ffmpeg', [
          '-v', 'error', '-i', outPath, '-f', 'null', '-', //
        ]);
        expect(decode.exitCode, 0);
        expect((decode.stderr as String).trim(), isEmpty);
      },
      skip: ffmpegMissing,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

/// Null when ffmpeg (with libx264) and ffprobe both run, otherwise why the
/// test is skipped.
String? _ffmpegMissingReason() {
  for (final tool in ['ffmpeg', 'ffprobe']) {
    try {
      final result = Process.runSync(tool, ['-version']);
      if (result.exitCode != 0) return '$tool -version failed';
    } on ProcessException {
      return '$tool is not on PATH';
    }
  }
  final encoders = Process.runSync('ffmpeg', ['-hide_banner', '-encoders']);
  if (!'${encoders.stdout}'.contains('libx264')) {
    return 'ffmpeg has no libx264 encoder';
  }
  return null;
}

/// Parses ffprobe's default output into `key` (stream fields) plus
/// `stream.duration` / `format.duration`, which share a name.
Map<String, String> _probeFields(String output) {
  final fields = <String, String>{};
  var section = '';
  for (final raw in output.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line == '[STREAM]') section = 'stream';
    if (line == '[FORMAT]') section = 'format';
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    final key = line.substring(0, eq);
    final value = line.substring(eq + 1);
    if (key == 'duration') {
      fields['$section.duration'] = value;
    } else {
      fields.putIfAbsent(key, () => value);
    }
  }
  return fields;
}

class _AccessUnit {
  _AccessUnit(this.avcc, this.isKeyFrame);
  final Uint8List avcc;
  final bool isKeyFrame;
}

/// An Annex-B H.264 stream split on its access unit delimiters.
class _AnnexBStream {
  _AnnexBStream(this.accessUnits, this.avcDecoderConfig);

  final List<_AccessUnit> accessUnits;
  final Uint8List avcDecoderConfig;

  static _AnnexBStream parse(Uint8List bytes) {
    final nals = _splitNalUnits(bytes);
    Uint8List? sps;
    Uint8List? pps;
    final units = <_AccessUnit>[];
    List<Uint8List>? current;
    var currentIsKey = false;

    void close() {
      final nalsInUnit = current;
      if (nalsInUnit == null || nalsInUnit.isEmpty) return;
      final out = BytesBuilder();
      for (final nal in nalsInUnit) {
        out
          ..add((ByteData(4)..setUint32(0, nal.length)).buffer.asUint8List())
          ..add(nal);
      }
      units.add(_AccessUnit(out.takeBytes(), currentIsKey));
    }

    for (final nal in nals) {
      final type = nal[0] & 0x1F;
      switch (type) {
        case 9: // access unit delimiter
          close();
          current = [];
          currentIsKey = false;
        case 7:
          sps ??= nal;
        case 8:
          pps ??= nal;
        default:
          if (type == 5) currentIsKey = true;
          (current ??= []).add(nal);
      }
    }
    close();

    final s = sps!;
    final p = pps!;
    final config = BytesBuilder()
      ..add([1, s[1], s[2], s[3], 0xFF, 0xE1])
      ..add([s.length >> 8, s.length & 0xFF])
      ..add(s)
      ..add([1, p.length >> 8, p.length & 0xFF])
      ..add(p);
    return _AnnexBStream(units, config.takeBytes());
  }

  static List<Uint8List> _splitNalUnits(Uint8List bytes) {
    final starts = <int>[]; // index of the first byte after each start code
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1) {
        starts.add(i + 3);
        i += 2;
      }
    }
    final nals = <Uint8List>[];
    for (var n = 0; n < starts.length; n++) {
      var end = n + 1 < starts.length ? starts[n + 1] - 3 : bytes.length;
      // A 4-byte start code leaves a zero byte on the previous NAL.
      while (end > starts[n] && bytes[end - 1] == 0) {
        end--;
      }
      nals.add(Uint8List.sublistView(bytes, starts[n], end));
    }
    return nals;
  }
}
