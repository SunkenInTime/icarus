import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:icarus/view_cone/height_native.dart';

void _fatalWorker(List<Object> startup) async {
  final destination = startup.first as SendPort;
  final receive = ReceivePort();
  destination.send({'port': receive.sendPort, 'info': <String, Object>{}});
  await receive.first;
  destination.send({'error': 'intentional terminal failure', 'fatal': true});
  receive.close();
}

void _exitWorker(List<Object> startup) async {
  final destination = startup.first as SendPort;
  final receive = ReceivePort();
  destination.send({'port': receive.sendPort, 'info': <String, Object>{}});
  await receive.first;
  receive.close();
}

void _throwWorker(List<Object> startup) async {
  final destination = startup.first as SendPort;
  final receive = ReceivePort();
  destination.send({'port': receive.sendPort, 'info': <String, Object>{}});
  await receive.first;
  receive.close();
  throw StateError('intentional uncaught worker failure');
}

void _startupFailure(List<Object> startup) {
  throw StateError('intentional startup failure');
}

void _finishingWorker(List<Object> startup) async {
  final destination = startup.first as SendPort;
  final receive = ReceivePort();
  destination.send({'port': receive.sendPort, 'info': <String, Object>{}});
  await for (final message in receive) {
    if (message == null) {
      destination.send({'closed': true});
      receive.close();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    destination.send({
      'stamp': message['stamp'],
      'positions': TransferableTypedData.fromList([Float32List(0)]),
      'offsets': [0, 0],
      'timings': <String, num>{},
    });
  }
}

void main() {
  test('close drains an active frame and rejects new work immediately',
      () async {
    final worker =
        await HeightNativeWorker.openProtocolTestWorker(_finishingWorker);
    final query = Float64List.fromList([0, 0, 1.75, 1, 0, 43, 1.8]);
    final frame = worker.compute(7, query);
    final closing = worker.close();
    expect(identical(closing, worker.close()), isTrue);
    await expectLater(worker.compute(8, query), throwsStateError);
    expect((await frame).stamp, 7);
    await closing.timeout(const Duration(seconds: 2));
  });
  for (final entry in [_fatalWorker, _exitWorker, _throwWorker]) {
    test(
        'terminal worker event makes subsequent calls fail without waiting: $entry',
        () async {
      final worker = await HeightNativeWorker.openProtocolTestWorker(entry);
      final query = Float64List.fromList([0, 0, 1.75, 1, 0, 43, 1.8]);
      await expectLater(
          worker.compute(1, query).timeout(const Duration(seconds: 2)),
          throwsStateError);
      await expectLater(
          worker.compute(2, query).timeout(const Duration(seconds: 2)),
          throwsStateError);
      await worker.close().timeout(const Duration(seconds: 2));
    });
  }
  test('startup failure is reported and closes the parent subscription',
      () async {
    await expectLater(
        HeightNativeWorker.openProtocolTestWorker(_startupFailure)
            .timeout(const Duration(seconds: 2)),
        throwsStateError);
  });
}
