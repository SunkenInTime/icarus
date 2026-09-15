import 'dart:async';
import 'dart:typed_data';

import 'height_native.dart';

/// One pending pose and one completed mesh per mounted cone. Native batches
/// stay bounded while the editor can contain any number of cones.
class HeightQueryQueue {
  HeightQueryQueue(this.computeNative, {this.onError});
  final void Function(Object, StackTrace)? onError;
  final Future<HeightFrame> Function(int, Float64List) computeNative;

  /// Optional profiling observer. Queries and frame bytes must not be mutated.
  void Function(HeightFrame frame, Float64List queries, int elapsedMicros)?
      onComputed;
  final _slots = <Object, _Slot>{};
  // Set literals preserve insertion order. Requeued cones go behind work that
  // was already waiting, including scenes larger than one native batch.
  final _pending = <_Slot>{};
  Future<void>? _active;
  var _stamp = 0;
  var _closed = false;
  Object? _failure;

  Future<Float32List?> request(Object id, Float64List input,
      {void Function(Float32List mesh)? onComputed}) {
    if (_closed) return Future.error(StateError('Sightline queue is closed.'));
    if (input.length != 7) throw ArgumentError('Expected seven query values.');
    final slot = _slots.putIfAbsent(id, _Slot.new);
    if (_same(slot.query, input)) {
      if (onComputed != null) {
        unawaited(slot.result!.future.then<void>((mesh) {
          if (mesh != null && slot.active && !_closed) onComputed(mesh);
        }, onError: (Object _, StackTrace __) {}));
      }
      return slot.result!.future;
    }
    if (!(slot.result?.isCompleted ?? true)) slot.result!.complete(null);
    slot.query = Float64List.fromList(input);
    slot.result = Completer<Float32List?>();
    slot.onComputed = onComputed;
    _pending.add(slot);
    _active ??= Future<void>.microtask(_drain);
    return slot.result!.future;
  }

  void remove(Object id) {
    final slot = _slots.remove(id);
    _pending.remove(slot);
    if (slot != null) slot.active = false;
    if (slot != null && !(slot.result?.isCompleted ?? true)) {
      slot.result!.complete(null);
    }
  }

  Future<void> _drain() async {
    try {
      while (!_closed) {
        final selected = _pending.take(10).toList();
        if (selected.isEmpty) break;
        final completions = [for (final slot in selected) slot.result!];
        final callbacks = [for (final slot in selected) slot.onComputed];
        final queries = Float64List(selected.length * 7);
        for (var i = 0; i < selected.length; i++) {
          queries.setRange(i * 7, i * 7 + 7, selected[i].query!);
          _pending.remove(selected[i]);
        }
        try {
          final stamp = ++_stamp;
          final watch = onComputed == null ? null : (Stopwatch()..start());
          final frame = await computeNative(stamp, queries);
          if (frame.stamp != stamp ||
              frame.offsets.length != selected.length + 1) {
            throw StateError('Sightline response does not match its poses.');
          }
          if (watch != null)
            onComputed?.call(frame, queries, watch.elapsedMicroseconds);
          for (var i = 0; i < selected.length; i++) {
            if (selected[i].active && !_closed)
              callbacks[i]?.call(frame.cone(i));
            if (!completions[i].isCompleted)
              completions[i].complete(frame.cone(i));
          }
        } catch (error, stack) {
          if (_failure == null) onError?.call(error, stack);
          _failure = error;
          for (final completion in completions) {
            if (!completion.isCompleted) completion.completeError(error, stack);
          }
        }
      }
    } finally {
      _active = null;
    }
  }

  /// Exports call this after mounting their exact frame, before reading pixels.
  Future<void> waitIdle() async {
    while (_active != null) {
      await _active;
    }
    if (_failure case final error?) throw error;
  }

  Future<void> close() async {
    _closed = true;
    for (final id in _slots.keys.toList()) {
      remove(id);
    }
    await _active;
  }

  static bool _same(Float64List? a, Float64List b) {
    if (a == null) return false;
    final aa = a.buffer.asUint64List(a.offsetInBytes, 7);
    final bb = b.buffer.asUint64List(b.offsetInBytes, 7);
    for (var i = 0; i < 7; i++) {
      if (aa[i] != bb[i]) return false;
    }
    return true;
  }
}

class _Slot {
  bool active = true;
  void Function(Float32List mesh)? onComputed;
  Float64List? query;
  Completer<Float32List?>? result;
}
