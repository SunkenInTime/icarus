import 'dart:typed_data';

/// One parsed ISO-BMFF box.
class Mp4Box {
  Mp4Box(this.type, this.start, this.size, this.headerSize);

  final String type;
  final int start;
  final int size;
  final int headerSize;

  int get end => start + size;

  Uint8List payload(Uint8List file) =>
      file.sublist(start + headerSize, start + size);
}

/// Reads back the boxes an MP4 writer produced, for assertions in tests.
/// Pure Dart, so the VM and browser tests share it.
class Mp4Boxes {
  Mp4Boxes(this.file) : _data = ByteData.sublistView(file);

  final Uint8List file;
  final ByteData _data;

  static const _containers = {'moov', 'trak', 'mdia', 'minf', 'dinf', 'stbl'};

  List<String> get topLevelTypes =>
      [for (final box in _parse(0, file.length)) box.type];

  List<Mp4Box> _parse(int start, int end) {
    final boxes = <Mp4Box>[];
    var offset = start;
    while (offset < end) {
      var size = _data.getUint32(offset);
      final type = String.fromCharCodes(file.sublist(offset + 4, offset + 8));
      var headerSize = 8;
      if (size == 1) {
        size = _data.getUint32(offset + 8) * 0x100000000 +
            _data.getUint32(offset + 12);
        headerSize = 16;
      }
      if (size < headerSize || offset + size > end) {
        throw FormatException('Bad $type box size $size at $offset');
      }
      boxes.add(Mp4Box(type, offset, size, headerSize));
      offset += size;
    }
    return boxes;
  }

  /// Follows [path] from the top level, e.g. `['moov', 'trak', 'tkhd']`.
  Mp4Box find(List<String> path) {
    var boxes = _parse(0, file.length);
    late Mp4Box found;
    for (var i = 0; i < path.length; i++) {
      found = boxes.firstWhere(
        (box) => box.type == path[i],
        orElse: () => throw StateError('No ${path.take(i + 1).join('/')}'),
      );
      if (i + 1 < path.length) {
        if (!_containers.contains(found.type)) {
          throw StateError('${found.type} is not a container');
        }
        boxes = _parse(found.start + found.headerSize, found.end);
      }
    }
    return found;
  }

  Mp4Box? _maybeFind(List<String> path) {
    try {
      return find(path);
    } on StateError {
      return null;
    }
  }

  static const _stbl = ['moov', 'trak', 'mdia', 'minf', 'stbl'];

  /// Box payload offset past the version/flags word of a full box.
  int _fullBoxBody(Mp4Box box) => box.start + box.headerSize + 4;

  List<int> _u32Table(Mp4Box box, {required int skip, int stride = 1}) {
    final body = _fullBoxBody(box);
    final count = _data.getUint32(body + skip * 4);
    final first = body + (skip + 1) * 4;
    return [
      for (var i = 0; i < count * stride; i++) _data.getUint32(first + i * 4),
    ];
  }

  List<int> chunkOffsets() => _u32Table(find([..._stbl, 'stco']), skip: 0);

  List<int> sampleSizes() {
    final stsz = find([..._stbl, 'stsz']);
    final fixed = _data.getUint32(_fullBoxBody(stsz));
    if (fixed != 0) throw UnimplementedError('Fixed-size samples');
    return _u32Table(stsz, skip: 1);
  }

  /// `[sample_count, sample_delta]` runs.
  List<List<int>> stts() {
    final flat = _u32Table(find([..._stbl, 'stts']), skip: 0, stride: 2);
    return [
      for (var i = 0; i < flat.length; i += 2) [flat[i], flat[i + 1]],
    ];
  }

  List<int> sampleDurations() => [
        for (final run in stts())
          for (var i = 0; i < run[0]; i++) run[1],
      ];

  /// 1-based keyframe numbers, or null when stss is absent (all sync).
  List<int>? syncSamples() {
    final stss = _maybeFind([..._stbl, 'stss']);
    return stss == null ? null : _u32Table(stss, skip: 0);
  }

  int samplesPerChunk() {
    final stsc = find([..._stbl, 'stsc']);
    final body = _fullBoxBody(stsc);
    if (_data.getUint32(body) != 1) throw UnimplementedError('Several runs');
    return _data.getUint32(body + 8);
  }

  (int, int) _timescaleAndDuration(List<String> path) {
    final box = find(path);
    final body = _fullBoxBody(box);
    final version = file[box.start + box.headerSize];
    if (version == 1) {
      return (
        _data.getUint32(body + 16),
        _data.getUint32(body + 20) * 0x100000000 + _data.getUint32(body + 24),
      );
    }
    return (_data.getUint32(body + 8), _data.getUint32(body + 12));
  }

  int mediaTimescale() =>
      _timescaleAndDuration(['moov', 'trak', 'mdia', 'mdhd']).$1;

  int mediaDuration() =>
      _timescaleAndDuration(['moov', 'trak', 'mdia', 'mdhd']).$2;

  int movieDuration() => _timescaleAndDuration(['moov', 'mvhd']).$2;

  /// tkhd width and height, whole pixels of the 16.16 values.
  (int, int) trackSize() {
    final tkhd = find(['moov', 'trak', 'tkhd']);
    return (
      _data.getUint32(tkhd.end - 8) ~/ 0x10000,
      _data.getUint32(tkhd.end - 4) ~/ 0x10000,
    );
  }

  /// The single entry inside stsd.
  Mp4Box sampleEntry() {
    final stsd = find([..._stbl, 'stsd']);
    final entries = _parse(_fullBoxBody(stsd) + 4, stsd.end);
    return entries.single;
  }

  /// Child boxes of a box whose own fields take [entryHeaderSize] bytes after
  /// its header (78 for a visual sample entry).
  List<Mp4Box> childrenOf(Mp4Box box, {required int entryHeaderSize}) =>
      _parse(box.start + box.headerSize + entryHeaderSize, box.end);
}
