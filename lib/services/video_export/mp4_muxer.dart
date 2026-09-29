import 'dart:typed_data';

/// How a track's decoded samples map to colour, as ISO/IEC 23091-2 code
/// points (the H.264 VUI's): written as the sample entry's `colr` box.
///
/// Players that find no colour description assume limited range. An
/// encoder that writes full-range samples without saying so in its
/// bitstream gets its darks crushed to black unless the container says so.
class Mp4ColorInfo {
  const Mp4ColorInfo({
    required this.primaries,
    required this.transfer,
    required this.matrix,
    required this.fullRange,
  });

  final int primaries;
  final int transfer;
  final int matrix;
  final bool fullRange;
}

/// Builds an MP4 file holding one H.264 video track, entirely in memory.
///
/// The layout is faststart (ftyp, moov, mdat) so browsers and chat apps can
/// start playing before the whole file has arrived. All samples live in a
/// single chunk, so the file needs exactly one chunk offset.
///
/// Samples are stored in the order they are added and presented in that same
/// order: there is no composition offset table, so the stream must not
/// contain B-frames (decode order must equal presentation order).
///
/// Pure Dart and 64-bit values are written as two 32-bit halves, so this runs
/// unchanged on the VM and on the web.
class Mp4H264Muxer {
  Mp4H264Muxer({
    required this.width,
    required this.height,
    this.timescale = 90000,
  }) {
    if (width <= 0 || width > 0xFFFF || height <= 0 || height > 0xFFFF) {
      throw ArgumentError('Video size must be within 1..65535 on each side.');
    }
    if (timescale <= 0 || timescale > _maxUint32) {
      throw ArgumentError.value(timescale, 'timescale', 'must be positive');
    }
  }

  final int width;
  final int height;

  /// Ticks per second for every duration passed to [addSample].
  final int timescale;

  final List<Uint8List> _samples = [];
  final List<int> _durations = [];
  final List<int> _keyFrameNumbers = [];
  int _payloadBytes = 0;
  int _totalDuration = 0;
  bool _finished = false;
  Mp4ColorInfo? _color;

  int get sampleCount => _samples.length;

  /// Total duration of the added samples, in [timescale] ticks.
  int get totalDuration => _totalDuration;

  /// Adds one access unit in AVCC format (length-prefixed NAL units), exactly
  /// as WebCodecs emits it with `avc: {format: 'avc'}`. [duration] is in
  /// [timescale] ticks.
  void addSample(
    Uint8List sample, {
    required int duration,
    required bool isKeyFrame,
  }) {
    if (_finished) throw StateError('The MP4 has already been finished.');
    if (sample.isEmpty) {
      throw ArgumentError('An H.264 sample cannot be empty.');
    }
    if (duration <= 0 || duration > _maxUint32) {
      throw ArgumentError.value(
        duration,
        'duration',
        'must be between 1 and 2^32-1 ticks',
      );
    }
    if (_samples.isEmpty && !isKeyFrame) {
      throw StateError('The first H.264 sample must be a keyframe.');
    }
    _samples.add(sample);
    _durations.add(duration);
    if (isKeyFrame) _keyFrameNumbers.add(_samples.length);
    _payloadBytes += sample.length;
    _totalDuration += duration;
  }

  /// Returns the finished file. [avcDecoderConfig] is the
  /// AVCDecoderConfigurationRecord (the `description` WebCodecs reports in the
  /// first chunk's `metadata.decoderConfig`); [color] is how its samples map
  /// to colour, when known.
  Uint8List finish({
    required Uint8List avcDecoderConfig,
    Mp4ColorInfo? color,
  }) {
    if (_finished) throw StateError('The MP4 has already been finished.');
    if (_samples.isEmpty) {
      throw StateError('Cannot build an MP4 without any video samples.');
    }
    if (avcDecoderConfig.isEmpty || avcDecoderConfig[0] != 1) {
      throw ArgumentError(
        'avcDecoderConfig must be an AVCDecoderConfigurationRecord '
        '(configurationVersion 1).',
      );
    }
    _finished = true;
    _color = color;

    final ftyp = _box('ftyp', [
      _fourCc('isom'),
      _u32(0x200),
      _fourCc('isom'),
      _fourCc('iso2'),
      _fourCc('avc1'),
      _fourCc('mp41'),
    ]);

    // The single chunk offset is known only once moov's size is known, and
    // moov's size does not depend on the offset's value, so build moov twice.
    final largeMdat = _payloadBytes + 8 > _maxUint32;
    final mdatHeaderSize = largeMdat ? 16 : 8;
    final moovSize = _moov(avcDecoderConfig, chunkOffset: 0).length;
    final chunkOffset = ftyp.length + moovSize + mdatHeaderSize;
    final moov = _moov(avcDecoderConfig, chunkOffset: chunkOffset);
    assert(moov.length == moovSize);

    final out = BytesBuilder(copy: false)
      ..add(ftyp)
      ..add(moov);
    if (largeMdat) {
      out
        ..add(_u32(1))
        ..add(_fourCc('mdat'))
        ..add(_u64(_payloadBytes + 16));
    } else {
      out
        ..add(_u32(_payloadBytes + 8))
        ..add(_fourCc('mdat'));
    }
    for (final sample in _samples) {
      out.add(sample);
    }
    return out.takeBytes();
  }

  Uint8List _moov(Uint8List avcC, {required int chunkOffset}) {
    // Durations past 32 bits need the version-1 time boxes.
    final longDuration = _totalDuration > _maxUint32;
    return _box('moov', [
      _mvhd(longDuration),
      _box('trak', [
        _tkhd(longDuration),
        _box('mdia', [
          _mdhd(longDuration),
          _fullBox('hdlr', 0, 0, [
            _u32(0), // pre_defined
            _fourCc('vide'),
            Uint8List(12), // reserved
            Uint8List.fromList([...'VideoHandler'.codeUnits, 0]),
          ]),
          _box('minf', [
            _fullBox('vmhd', 0, 1, [Uint8List(8)]), // graphicsmode, opcolor
            _box('dinf', [
              _fullBox('dref', 0, 0, [
                _u32(1),
                _fullBox('url ', 0, 1, const []), // media is in this file
              ]),
            ]),
            _stbl(avcC, chunkOffset),
          ]),
        ]),
      ]),
    ]);
  }

  Uint8List _mvhd(bool longDuration) =>
      _fullBox('mvhd', longDuration ? 1 : 0, 0, [
        ..._times(longDuration),
        _u32(timescale),
        _duration(longDuration),
        _u32(0x00010000), // rate 1.0
        _u16(0x0100), // volume 1.0
        Uint8List(10), // reserved
        _identityMatrix(),
        Uint8List(24), // pre_defined
        _u32(2), // next_track_ID
      ]);

  Uint8List _tkhd(bool longDuration) =>
      _fullBox('tkhd', longDuration ? 1 : 0, 0x000003, [
        // flags: track enabled | track in movie
        ..._times(longDuration),
        _u32(1), // track_ID
        _u32(0), // reserved
        _duration(longDuration),
        Uint8List(8), // reserved
        _u16(0), // layer
        _u16(0), // alternate_group
        _u16(0), // volume: 0 for video
        _u16(0), // reserved
        _identityMatrix(),
        _u32(width * 0x10000), // 16.16 fixed point
        _u32(height * 0x10000),
      ]);

  Uint8List _mdhd(bool longDuration) =>
      _fullBox('mdhd', longDuration ? 1 : 0, 0, [
        ..._times(longDuration),
        _u32(timescale),
        _duration(longDuration),
        _u16(0x55C4), // language 'und'
        _u16(0), // pre_defined
      ]);

  List<Uint8List> _times(bool longDuration) => longDuration
      ? [Uint8List(8), Uint8List(8)] // creation_time, modification_time
      : [Uint8List(4), Uint8List(4)];

  Uint8List _duration(bool longDuration) =>
      longDuration ? _u64(_totalDuration) : _u32(_totalDuration);

  Uint8List _stbl(Uint8List avcC, int chunkOffset) {
    // Run-length encode the per-sample durations.
    final sttsEntries = <Uint8List>[];
    var runCount = 0;
    var runDelta = _durations.first;
    for (final delta in _durations) {
      if (delta == runDelta) {
        runCount++;
        continue;
      }
      sttsEntries
        ..add(_u32(runCount))
        ..add(_u32(runDelta));
      runDelta = delta;
      runCount = 1;
    }
    sttsEntries
      ..add(_u32(runCount))
      ..add(_u32(runDelta));

    final sizes = ByteData(_samples.length * 4);
    for (var i = 0; i < _samples.length; i++) {
      sizes.setUint32(i * 4, _samples[i].length);
    }

    final allKeyFrames = _keyFrameNumbers.length == _samples.length;
    return _box('stbl', [
      _fullBox('stsd', 0, 0, [_u32(1), _avc1(avcC)]),
      _fullBox('stts', 0, 0, [_u32(sttsEntries.length ~/ 2), ...sttsEntries]),
      // Without stss every sample is a sync sample.
      if (!allKeyFrames)
        _fullBox('stss', 0, 0, [
          _u32(_keyFrameNumbers.length),
          for (final number in _keyFrameNumbers) _u32(number),
        ]),
      _fullBox('stsc', 0, 0, [
        _u32(1),
        _u32(1), // first_chunk
        _u32(_samples.length), // samples_per_chunk
        _u32(1), // sample_description_index
      ]),
      _fullBox('stsz', 0, 0, [
        _u32(0), // sample_size: sizes vary
        _u32(_samples.length),
        sizes.buffer.asUint8List(),
      ]),
      // One chunk, and it starts right after ftyp and moov, so its offset
      // always fits in 32 bits.
      _fullBox('stco', 0, 0, [_u32(1), _u32(chunkOffset)]),
    ]);
  }

  Uint8List _avc1(Uint8List avcC) => _box('avc1', [
        Uint8List(6), // reserved
        _u16(1), // data_reference_index
        Uint8List(16), // pre_defined, reserved, pre_defined[3]
        _u16(width),
        _u16(height),
        _u32(0x00480000), // 72 dpi
        _u32(0x00480000),
        _u32(0), // reserved
        _u16(1), // frame_count
        Uint8List(32), // compressorname
        _u16(0x0018), // depth
        _u16(0xFFFF), // pre_defined = -1
        _box('avcC', [avcC]),
        if (_color case final color?)
          _box('colr', [
            _fourCc('nclx'),
            _u16(color.primaries),
            _u16(color.transfer),
            _u16(color.matrix),
            Uint8List.fromList([color.fullRange ? 0x80 : 0]),
          ]),
      ]);

  static Uint8List _identityMatrix() => Uint8List.fromList([
        ..._u32(0x00010000), ..._u32(0), ..._u32(0), //
        ..._u32(0), ..._u32(0x00010000), ..._u32(0), //
        ..._u32(0), ..._u32(0), ..._u32(0x40000000), //
      ]);
}

const int _maxUint32 = 0xFFFFFFFF;

Uint8List _box(String type, List<Uint8List> children) {
  var size = 8;
  for (final child in children) {
    size += child.length;
  }
  final out = BytesBuilder(copy: false)
    ..add(_u32(size))
    ..add(_fourCc(type));
  for (final child in children) {
    out.add(child);
  }
  return out.takeBytes();
}

Uint8List _fullBox(
  String type,
  int version,
  int flags,
  List<Uint8List> children,
) =>
    _box(type, [
      _u32(version * 0x1000000 + flags),
      ...children,
    ]);

Uint8List _fourCc(String code) {
  assert(code.length == 4);
  return Uint8List.fromList(code.codeUnits);
}

Uint8List _u16(int value) =>
    (ByteData(2)..setUint16(0, value)).buffer.asUint8List();

Uint8List _u32(int value) =>
    (ByteData(4)..setUint32(0, value)).buffer.asUint8List();

/// ByteData.setUint64 is unsupported when compiled to JavaScript.
Uint8List _u64(int value) => (ByteData(8)
      ..setUint32(0, value ~/ 0x100000000)
      ..setUint32(4, value % 0x100000000))
    .buffer
    .asUint8List();
