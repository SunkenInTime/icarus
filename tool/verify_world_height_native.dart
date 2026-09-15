import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'world_height_native.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4)
    throw ArgumentError('DLL preparedFolder originalPipelineDump outputJson');
  final dump = ByteData.sublistView(File(args[2]).readAsBytesSync());
  var cursor = 0;
  int integer() {
    final value = dump.getUint32(cursor, Endian.little);
    cursor += 4;
    return value;
  }

  void skipSections() {
    final count = integer();
    cursor += count * 40;
  }

  final count = integer();
  final expected = <Float32List>[];
  for (var i = 0; i < count; i++) {
    skipSections();
    skipSections();
    final length = integer();
    expected.add(Float32List.fromList(List.generate(
        length, (j) => dump.getFloat32(cursor + j * 4, Endian.little))));
    cursor += length * 4;
  }
  if (cursor != dump.lengthInBytes)
    throw StateError('Unconsumed reference bytes.');
  final bytes = File('${args[1]}/queries.bin').readAsBytesSync();
  final input = ByteData.sublistView(bytes);
  Float64List queries(int first, int count) => Float64List.fromList([
        for (var i = first; i < first + count; i++) ...[
          for (var j = 0; j < 5; j++)
            input.getFloat64(i * 40 + j * 8, Endian.little),
          65.0,
          103 * math.pi / 180,
        ],
      ]);
  final worker = await HeightNativeWorker.open(args[0], args[1], 4);
  final timings = <Map<String, num>>[];
  var coordinates = 0;
  try {
    for (var first = 0; first < count; first += 10) {
      final n = math.min(10, count - first);
      final result = await worker.compute(first, queries(first, n));
      timings.add(result.timings);
      for (var i = 0; i < n; i++) {
        final actual = result.cone(i), reference = expected[first + i];
        if (actual.length != reference.length)
          throw StateError('Query ${first + i}: mesh length mismatch.');
        for (var j = 0; j < actual.length; j++) {
          if (actual[j] != reference[j])
            throw StateError(
                'Query ${first + i}, coordinate $j: ${actual[j]} != ${reference[j]}');
        }
        coordinates += actual.length;
      }
    }
    final invalid = queries(0, 1)..[3] = 2;
    var invalidRejected = false;
    try {
      await worker.compute(991, invalid);
    } on StateError {
      invalidRejected = true;
    }
    if (!invalidRejected) throw StateError('Invalid direction accepted.');
    final valid = worker.compute(992, queries(0, 1));
    var concurrentRejected = false;
    try {
      await worker.compute(993, queries(1, 1));
    } on StateError {
      concurrentRejected = true;
    }
    if (!concurrentRejected) throw StateError('Concurrent frame accepted.');
    final recovered = await valid;
    if (recovered.stamp != 992) throw StateError('Failure recovery lost pose.');
  } finally {
    await worker.close();
  }
  await worker.close();
  var closedRejected = false;
  try {
    await worker.compute(994, queries(0, 1));
  } on StateError {
    closedRejected = true;
  }
  if (!closedRejected) throw StateError('Closed worker accepted a frame.');
  final report = {
    'status': 'passed',
    'queries': count,
    'exactFloat32Coordinates': coordinates,
    'info': worker.info,
    'timings': timings,
    'invalidQueryRecovery': true,
    'concurrentSubmissionRejected': true,
    'closedWorkerRejected': true,
    'duplicateCloseSafe': true,
    'scope':
        'Dart FFI isolate transfer matches previously independent source/Dart-verified native mesh. No GPU or game proof.',
  };
  File(args[3])
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln(jsonEncode(report));
}
