import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:ffi/ffi.dart';

String svgHeightNativeLibraryPath() {
  final executable = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows) return '${executable.path}/icarus_height.dll';
  if (Platform.isLinux) return '${executable.path}/lib/libicarus_height.so';
  if (Platform.isMacOS) {
    return '${executable.parent.path}/Frameworks/libicarus_height.dylib';
  }
  throw UnsupportedError('SVG height visibility requires a desktop build.');
}

final class SvgHeightNativeResult extends Struct {
  @Uint32()
  external int structSize;

  @Uint32()
  external int status;

  external Pointer<Double> points;

  @Uint32()
  external int pointCount;

  @Uint32()
  external int rayCount;

  @Uint64()
  external int edgeTests;

  @Uint64()
  external int spatialNodes;

  @Uint32()
  external int candidateEdges;

  @Uint32()
  external int reserved;

  @Double()
  external double preparationMicros;

  @Double()
  external double candidateMicros;

  @Double()
  external double queryMicros;
}

typedef _OpenC = Pointer<Void> Function(
    Pointer<Double>, Uint32, Uint32, Pointer<Utf8>, Uint32);
typedef _OpenD = Pointer<Void> Function(
    Pointer<Double>, int, int, Pointer<Utf8>, int);
typedef _QueryC = Int32 Function(Pointer<Void>, Double, Double, Double, Double,
    Double, Uint32, Pointer<Uint8>, Uint32, Pointer<SvgHeightNativeResult>);
typedef _QueryD = int Function(Pointer<Void>, double, double, double, double,
    double, int, Pointer<Uint8>, int, Pointer<SvgHeightNativeResult>);
typedef _ErrorC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _ErrorD = int Function(Pointer<Void>, Pointer<Utf8>, int);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _CloseD = int Function(Pointer<Void>);
typedef _FinalizeC = Void Function(Pointer<Void>);
typedef _MaskBufferC = Pointer<Uint8> Function(Pointer<Void>);
typedef _MaskBufferD = Pointer<Uint8> Function(Pointer<Void>);
typedef _ResultBufferC = Pointer<SvgHeightNativeResult> Function(Pointer<Void>);
typedef _ResultBufferD = Pointer<SvgHeightNativeResult> Function(Pointer<Void>);

class SvgHeightNativeStats {
  const SvgHeightNativeStats({
    required this.rayCount,
    required this.edgeTests,
    required this.spatialNodes,
    required this.candidateEdges,
    required this.preparationMicros,
    required this.candidateMicros,
    required this.queryMicros,
  });

  final int rayCount;
  final int edgeTests;
  final int spatialNodes;
  final int candidateEdges;
  final double preparationMicros;
  final double candidateMicros;
  final double queryMicros;
}

class SvgHeightNativeCone {
  const SvgHeightNativeCone(this.xy, this.stats);

  /// Copied XY doubles. The first pair is the origin.
  final Float64List xy;
  final SvgHeightNativeStats stats;

  int get rayCount => stats.rayCount;
  int get edgeTests => stats.edgeTests;
  int get spatialNodes => stats.spatialNodes;
  int get candidateEdges => stats.candidateEdges;
  double get preparationMicros => stats.preparationMicros;
  double get candidateMicros => stats.candidateMicros;
  double get queryMicros => stats.queryMicros;
}

/// An immutable SVG edge index with one context-owned native result buffer.
/// Query calls are synchronous. Each call copies its points before returning.
class SvgHeightNative implements Finalizable {
  SvgHeightNative._(this.wallIds, this._handle, this._mask, this._result,
      this._query, this._readError, this._close, this._finalizer) {
    _finalizer.attach(this, _handle, detach: this);
  }

  static const int _maximumPointCount = 1 << 22;

  factory SvgHeightNative.open({
    required List<String> wallIds,
    required Float64List edgeRecords,
    String? libraryPath,
  }) {
    final edgeCount = edgeRecords.length ~/ 5;
    if (edgeRecords.length % 5 != 0 ||
        wallIds.length > 1 << 20 ||
        edgeCount > 1 << 19) {
      throw ArgumentError('SVG native geometry exceeds its bounded capacity.');
    }
    final ids = List<String>.unmodifiable(wallIds);
    if (ids.any((id) => id.isEmpty) || ids.toSet().length != ids.length) {
      throw ArgumentError('Wall IDs must be non-empty and unique.');
    }
    for (var index = 0; index < edgeRecords.length; index += 5) {
      final ax = edgeRecords[index];
      final ay = edgeRecords[index + 1];
      final bx = edgeRecords[index + 2];
      final by = edgeRecords[index + 3];
      final wall = edgeRecords[index + 4];
      if (![ax, ay, bx, by, wall].every((value) => value.isFinite) ||
          (ax == bx && ay == by) ||
          wall < 0 ||
          wall >= ids.length ||
          wall.truncateToDouble() != wall) {
        throw ArgumentError('Invalid SVG native edge.');
      }
    }
    final library =
        DynamicLibrary.open(libraryPath ?? svgHeightNativeLibraryPath());
    final open = library.lookupFunction<_OpenC, _OpenD>('ish_open');
    final query = library.lookupFunction<_QueryC, _QueryD>('ish_query');
    final readError =
        library.lookupFunction<_ErrorC, _ErrorD>('ish_last_error');
    final close = library.lookupFunction<_CloseC, _CloseD>('ish_close');
    final maskBuffer = library
        .lookupFunction<_MaskBufferC, _MaskBufferD>('ish_active_wall_buffer');
    final resultBuffer = library
        .lookupFunction<_ResultBufferC, _ResultBufferD>('ish_result_buffer');
    final finalizer = NativeFinalizer(
        library.lookup<NativeFunction<_FinalizeC>>('ish_close_finalizer'));
    final records = calloc<Double>(math.max(1, edgeRecords.length));
    final error = calloc<Uint8>(4096).cast<Utf8>();
    try {
      records.asTypedList(edgeRecords.length).setAll(0, edgeRecords);
      final handle = open(records, edgeCount, ids.length, error, 4096);
      if (handle == nullptr) {
        throw StateError(
            'Could not open SVG native geometry: ${error.toDartString()}');
      }
      final mask = maskBuffer(handle);
      final result = resultBuffer(handle);
      if (mask == nullptr || result == nullptr) {
        close(handle);
        throw StateError('SVG native context has no query buffers.');
      }
      return SvgHeightNative._(
          ids, handle, mask, result, query, readError, close, finalizer);
    } finally {
      calloc.free(error);
      calloc.free(records);
    }
  }

  /// Returns null when the shared library or SVG ABI is not installed.
  /// Geometry validation errors still fail loudly before the library load.
  static SvgHeightNative? tryOpen({
    required List<String> wallIds,
    required Float64List edgeRecords,
    String? libraryPath,
  }) {
    // Validate through the public constructor. DynamicLibrary.open and symbol
    // lookup both report unavailable native code as ArgumentError.
    try {
      return SvgHeightNative.open(
          wallIds: wallIds, edgeRecords: edgeRecords, libraryPath: libraryPath);
    } on UnsupportedError {
      return null;
    } on ArgumentError catch (error) {
      final message = '$error';
      if (message.contains('Invalid SVG native edge') ||
          message.contains('Wall IDs') ||
          message.contains('bounded capacity')) {
        rethrow;
      }
      return null;
    }
  }

  final List<String> wallIds;
  Pointer<Void> _handle;
  final Pointer<Uint8> _mask;
  final Pointer<SvgHeightNativeResult> _result;
  final _QueryD _query;
  final _ErrorD _readError;
  final _CloseD _close;
  final NativeFinalizer _finalizer;
  bool _closed = false;

  SvgHeightNativeCone query({
    required Offset origin,
    required double directionRadians,
    required double range,
    required double apertureRadians,
    required List<bool> activeWalls,
    int arcSteps = 96,
  }) {
    if (_closed) throw StateError('SVG native geometry is closed.');
    if (!origin.dx.isFinite ||
        !origin.dy.isFinite ||
        !directionRadians.isFinite ||
        !range.isFinite ||
        range < 0 ||
        !apertureRadians.isFinite ||
        apertureRadians <= 0 ||
        apertureRadians > math.pi * 2 ||
        arcSteps < 1 ||
        arcSteps > 4096 ||
        activeWalls.length != wallIds.length) {
      throw ArgumentError('Invalid SVG native visibility query.');
    }
    for (var index = 0; index < activeWalls.length; index++) {
      _mask[index] = activeWalls[index] ? 1 : 0;
    }
    _result.ref.structSize = sizeOf<SvgHeightNativeResult>();
    final status = _query(_handle, origin.dx, origin.dy, directionRadians,
        range, apertureRadians, arcSteps, _mask, activeWalls.length, _result);
    if (status != 0) {
      final error = calloc<Uint8>(4096).cast<Utf8>();
      try {
        _readError(_handle, error, 4096);
        throw StateError('SVG native query $status: ${error.toDartString()}');
      } finally {
        calloc.free(error);
      }
    }
    final value = _result.ref;
    if (value.structSize != sizeOf<SvgHeightNativeResult>() ||
        value.status != 0 ||
        value.pointCount == 0 ||
        value.pointCount > _maximumPointCount ||
        value.pointCount > value.rayCount + 1 ||
        value.points == nullptr ||
        !value.preparationMicros.isFinite ||
        !value.candidateMicros.isFinite ||
        !value.queryMicros.isFinite) {
      throw StateError('Malformed SVG native result.');
    }
    final points =
        Float64List.fromList(value.points.asTypedList(value.pointCount * 2));
    return SvgHeightNativeCone(
        points,
        SvgHeightNativeStats(
          rayCount: value.rayCount,
          edgeTests: value.edgeTests,
          spatialNodes: value.spatialNodes,
          candidateEdges: value.candidateEdges,
          preparationMicros: value.preparationMicros,
          candidateMicros: value.candidateMicros,
          queryMicros: value.queryMicros,
        ));
  }

  void close() {
    if (_closed) return;
    final status = _close(_handle);
    if (status != 0) {
      throw StateError('Could not close SVG native geometry: status $status.');
    }
    _finalizer.detach(this);
    _handle = nullptr;
    _closed = true;
  }
}
