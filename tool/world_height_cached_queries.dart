import 'dart:typed_data';

import 'world_height_native.dart';

/// Keeps exactly one result per current cone. An unchanged query reuses the
/// exact mesh, including its buffer identity for the renderer's image cache.
class HeightSceneComputer {
  HeightSceneComputer(this.computeNative);
  final Future<HeightFrame> Function(int, Float64List) computeNative;
  final _inputs = <Uint64List>[];
  final _meshes = <Float32List>[];
  var _busy = false;

  Future<HeightSceneFrame> compute(int stamp, Float64List queries) async {
    if (_busy) throw StateError('A scene computation is already active.');
    if (queries.isEmpty || queries.length % 7 != 0 || queries.length > 70) {
      throw ArgumentError('Expected one to ten complete queries.');
    }
    _busy = true;
    try {
      queries = Float64List.fromList(queries);
      final count = queries.length ~/ 7;
      final bits =
          queries.buffer.asUint64List(queries.offsetInBytes, queries.length);
      final changed = <int>[];
      for (var i = 0; i < count; i++) {
        var same = i < _inputs.length;
        for (var j = 0; same && j < 7; j++) {
          same = _inputs[i][j] == bits[i * 7 + j];
        }
        if (!same) changed.add(i);
      }
      HeightFrame? result;
      if (changed.isNotEmpty) {
        final selected = Float64List(changed.length * 7);
        for (var i = 0; i < changed.length; i++) {
          selected.setRange(i * 7, (i + 1) * 7, queries, changed[i] * 7);
        }
        result = await computeNative(stamp, selected);
        if (result.stamp != stamp ||
            result.offsets.length != changed.length + 1) {
          throw StateError('Native response does not match changed queries.');
        }
      }
      while (_meshes.length > count) {
        _meshes.removeLast();
        _inputs.removeLast();
      }
      for (var i = 0; i < changed.length; i++) {
        final slot = changed[i];
        final input = Uint64List.fromList(bits.sublist(slot * 7, slot * 7 + 7));
        final mesh = result!.cone(i);
        if (slot == _meshes.length) {
          _meshes.add(mesh);
          _inputs.add(input);
        } else {
          _meshes[slot] = mesh;
          _inputs[slot] = input;
        }
      }
      return HeightSceneFrame(
          stamp,
          List.unmodifiable(_meshes),
          changed.length,
          result?.positions.lengthInBytes ?? 0,
          result?.timings ??
              const {
                'queryCpuMicros': 0,
                'alphaCpuMicros': 0,
                'meshCpuMicros': 0,
                'computeWallMicros': 0,
                'computeAndCopyMicros': 0,
              });
    } finally {
      _busy = false;
    }
  }
}

class HeightSceneFrame {
  HeightSceneFrame(this.stamp, this.meshes, this.changedCones,
      this.transferredBytes, this.timings);
  final int stamp;
  final List<Float32List> meshes;
  final int changedCones, transferredBytes;
  final Map<String, num> timings;
  int get meshBytes =>
      meshes.fold(0, (bytes, mesh) => bytes + mesh.lengthInBytes);
}
