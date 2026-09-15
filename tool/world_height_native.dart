import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Isolated prototype ABI. Nothing in lib/ imports this file.
final class HeightQueryNative extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
  @Double()
  external double z;
  @Double()
  external double dx;
  @Double()
  external double dy;
  @Double()
  external double range;
  @Double()
  external double coneRadians;
}

final class HeightBatchNative extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int status;
  @Uint64()
  external int poseStamp;
  @Uint64()
  external int leaseId;
  external Pointer<Float> positions;
  external Pointer<Uint32> coneOffsets;
  @Uint32()
  external int floatCount;
  @Uint32()
  external int coneCount;
  @Double()
  external double queryCpuMicros;
  @Double()
  external double alphaCpuMicros;
  @Double()
  external double meshCpuMicros;
  @Double()
  external double computeWallMicros;
}

final class HeightInfoNative extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int abiVersion;
  @Uint32()
  external int workers;
  @Uint32()
  external int maxCones;
  @Uint64()
  external int rawModelBytes;
  @Uint64()
  external int zBoundsBytes;
  @Uint64()
  external int intermediateCapacityBytes;
  @Uint64()
  external int resultCapacityBytes;
  @Double()
  external double loadMillis;
  @Double()
  external double minimumHeight;
  @Double()
  external double maximumHeight;
}

typedef _OpenC = Pointer<Void> Function(
    Pointer<Utf8>, Uint32, Uint32, Pointer<Utf8>, Uint32);
typedef _OpenD = Pointer<Void> Function(
    Pointer<Utf8>, int, int, Pointer<Utf8>, int);
typedef _ComputeC = Int32 Function(Pointer<Void>, Pointer<HeightQueryNative>,
    Uint32, Uint64, Pointer<HeightBatchNative>);
typedef _ComputeD = int Function(Pointer<Void>, Pointer<HeightQueryNative>, int,
    int, Pointer<HeightBatchNative>);
typedef _ReleaseC = Int32 Function(Pointer<Void>, Uint64);
typedef _ReleaseD = int Function(Pointer<Void>, int);
typedef _CloseC = Int32 Function(Pointer<Void>);
typedef _CloseD = int Function(Pointer<Void>);
typedef _InfoC = Int32 Function(Pointer<Void>, Pointer<HeightInfoNative>);
typedef _InfoD = int Function(Pointer<Void>, Pointer<HeightInfoNative>);
typedef _ErrorC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32);
typedef _ErrorD = int Function(Pointer<Void>, Pointer<Utf8>, int);

/// Owns native memory on one persistent isolate. Each result is copied exactly
/// once into transferable bytes before releasing its native lease.
class HeightNativeWorker {
  HeightNativeWorker._(this._port, this._receive, this._messages, this.info);
  final SendPort _port;
  final ReceivePort _receive;
  final StreamIterator<dynamic> _messages;
  final Map<String, Object?> info;
  bool _busy = false;
  bool _closed = false;

  static Future<HeightNativeWorker> open(
          String dll, String folder, int workers) =>
      _start(_serve, [dll, folder, workers]);

  /// Exercises terminal protocol events without killing a live native model.
  /// Used only by this isolated tool's lifecycle tests.
  static Future<HeightNativeWorker> openProtocolTestWorker(
          void Function(List<Object>) entry) =>
      _start(entry, const []);

  static Future<HeightNativeWorker> _start(
      void Function(List<Object>) entry, List<Object> arguments) async {
    final receive = ReceivePort();
    final messages = StreamIterator(receive);
    try {
      await Isolate.spawn(entry, [receive.sendPort, ...arguments],
          onExit: receive.sendPort, onError: receive.sendPort);
      if (!await messages.moveNext()) {
        throw StateError('Native worker did not start.');
      }
      final message = messages.current;
      if (message is! Map) {
        throw StateError('Native worker stopped during startup: $message');
      }
      if (message['error'] != null) {
        throw StateError(message['error'] as String);
      }
      return HeightNativeWorker._(message['port'] as SendPort, receive,
          messages, Map<String, Object?>.from(message['info'] as Map));
    } catch (_) {
      receive.close();
      await messages.cancel();
      rethrow;
    }
  }

  Future<Map> _nextReply() async {
    final received = await _messages.moveNext();
    final message = received ? _messages.current : null;
    // onExit sends null, and onError sends [error, stack]. Neither leaves the
    // parent waiting on a still-open port after the worker has terminated.
    if (message is! Map || message['fatal'] == true) {
      _closed = true;
      _receive.close();
      await _messages.cancel();
      throw StateError(message is Map
          ? '${message['error']}'
          : 'Native worker terminated: $message');
    }
    return message;
  }

  Future<HeightFrame> compute(int stamp, Float64List queries) async {
    if (_closed || _busy)
      throw StateError('One native frame may be in flight.');
    if (queries.isEmpty || queries.length % 7 != 0 || queries.length > 70) {
      throw ArgumentError('Expected one to ten seven-double queries.');
    }
    _busy = true;
    try {
      _port.send({
        'stamp': stamp,
        'queries': TransferableTypedData.fromList([queries])
      });
      final result = await _nextReply();
      if (result['error'] != null) throw StateError(result['error'] as String);
      if (result['stamp'] != stamp) throw StateError('Mismatched pose stamp.');
      return HeightFrame(
        stamp,
        (result['positions'] as TransferableTypedData)
            .materialize()
            .asFloat32List(),
        Uint32List.fromList((result['offsets'] as List).cast<int>()),
        Map<String, num>.from(result['timings'] as Map),
      );
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    if (_busy) throw StateError('Await the active frame before closing.');
    _closed = true;
    _port.send(null);
    try {
      final reply = await _nextReply();
      if (reply['error'] != null) throw StateError(reply['error'] as String);
      if (reply['closed'] != true)
        throw StateError('No close acknowledgement.');
    } finally {
      _receive.close();
      await _messages.cancel();
    }
  }
}

class HeightFrame {
  HeightFrame(this.stamp, this.positions, this.offsets, this.timings);
  final int stamp;
  final Float32List positions;
  final Uint32List offsets;
  final Map<String, num> timings;
  Float32List cone(int index) =>
      Float32List.sublistView(positions, offsets[index], offsets[index + 1]);
}

void _serve(List<Object> startup) async {
  final destination = startup[0] as SendPort;
  final receive = ReceivePort();
  Pointer<Void> handle = nullptr;
  final queries = calloc<HeightQueryNative>(10);
  final batch = calloc<HeightBatchNative>();
  final info = calloc<HeightInfoNative>();
  final error = calloc<Uint8>(4096).cast<Utf8>();
  _CloseD? close;
  try {
    if (sizeOf<HeightQueryNative>() != 56 ||
        sizeOf<HeightBatchNative>() != 80 ||
        sizeOf<HeightInfoNative>() != 72) {
      throw StateError('Unsupported native ABI layout.');
    }
    final dll = DynamicLibrary.open(startup[1] as String);
    final open = dll.lookupFunction<_OpenC, _OpenD>('ih_open');
    final compute = dll.lookupFunction<_ComputeC, _ComputeD>('ih_compute');
    final release = dll.lookupFunction<_ReleaseC, _ReleaseD>('ih_release');
    final readInfo = dll.lookupFunction<_InfoC, _InfoD>('ih_info');
    final readError = dll.lookupFunction<_ErrorC, _ErrorD>('ih_last_error');
    close = dll.lookupFunction<_CloseC, _CloseD>('ih_close');
    final folder = (startup[2] as String).toNativeUtf8();
    try {
      handle = open(folder, startup[3] as int, 10, error, 4096);
    } finally {
      calloc.free(folder);
    }
    if (handle == nullptr) throw StateError(error.toDartString());
    info.ref.structSize = sizeOf<HeightInfoNative>();
    if (readInfo(handle, info) != 0 || info.ref.abiVersion != 1)
      throw StateError('Native ABI mismatch.');
    destination.send({
      'port': receive.sendPort,
      'info': {
        'workers': info.ref.workers,
        'loadMillis': info.ref.loadMillis,
        'rawModelBytes': info.ref.rawModelBytes,
        'zBoundsBytes': info.ref.zBoundsBytes,
        'minimumHeight': info.ref.minimumHeight,
        'maximumHeight': info.ref.maximumHeight,
      }
    });
    await for (final message in receive) {
      if (message == null) {
        final status = close(handle);
        if (status != 0) throw StateError('Native close failed: $status');
        handle = nullptr;
        destination.send({'closed': true});
        break;
      }
      final stamp = message['stamp'] as int;
      final input = (message['queries'] as TransferableTypedData)
          .materialize()
          .asFloat64List();
      if (input.isEmpty || input.length % 7 != 0 || input.length > 70) {
        throw ArgumentError('Malformed native worker query buffer.');
      }
      final count = input.length ~/ 7;
      queries.cast<Double>().asTypedList(input.length).setAll(0, input);
      batch.ref.structSize = sizeOf<HeightBatchNative>();
      final copyWatch = Stopwatch()..start();
      final status = compute(handle, queries, count, stamp, batch);
      if (status != 0) {
        readError(handle, error, 4096);
        destination
            .send({'error': 'Native compute $status: ${error.toDartString()}'});
        continue;
      }
      final value = batch.ref;
      late Map<String, Object> response;
      try {
        if (value.structSize != sizeOf<HeightBatchNative>() ||
            value.status != 0 ||
            value.leaseId == 0 ||
            value.poseStamp != stamp ||
            value.coneCount != count ||
            value.floatCount > 1 << 24 ||
            value.coneOffsets == nullptr ||
            (value.floatCount > 0 && value.positions == nullptr)) {
          throw StateError('Malformed native result.');
        }
        final offsets = value.coneOffsets.asTypedList(count + 1).toList();
        if (offsets.first != 0 || offsets.last != value.floatCount)
          throw StateError('Invalid mesh offsets.');
        for (var i = 0; i < count; i++) {
          if (offsets[i + 1] < offsets[i] ||
              (offsets[i + 1] - offsets[i]) % 6 != 0)
            throw StateError('Invalid cone triangles.');
        }
        final data = value.floatCount == 0
            ? Float32List(0)
            : value.positions.asTypedList(value.floatCount);
        final transferable = TransferableTypedData.fromList([data]);
        response = {
          'stamp': stamp,
          'positions': transferable,
          'offsets': offsets,
          'timings': {
            'queryCpuMicros': value.queryCpuMicros,
            'alphaCpuMicros': value.alphaCpuMicros,
            'meshCpuMicros': value.meshCpuMicros,
            'computeWallMicros': value.computeWallMicros,
            'computeAndCopyMicros': copyWatch.elapsedMicroseconds,
          }
        };
      } finally {
        if (release(handle, value.leaseId) != 0)
          throw StateError('Native lease release failed.');
      }
      // Success means the transferable owns its bytes and no native lease is
      // outstanding. A release failure cannot be queued after a success reply.
      destination.send(response);
    }
  } catch (error, stack) {
    destination.send({'error': '$error\n$stack', 'fatal': true});
  } finally {
    if (handle != nullptr) close?.call(handle);
    receive.close();
    calloc.free(queries);
    calloc.free(batch);
    calloc.free(info);
    calloc.free(error);
  }
}
