@Tags(['timing'])
library;

import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:test/test.dart';

import '../store_support.dart';

const _strategies = 700;

const _budget = Duration(milliseconds: 20);

void main() {
  test('the written version of $_strategies strategies is read on SQLite '
      'within ${_budget.inMilliseconds} ms', () async {
    final directory = await Directory.systemTemp.createTemp('icarus-written-');
    addTearDown(() => directory.delete(recursive: true));
    final file = '${directory.path}/library.sqlite';
    final ids = [for (var i = 0; i < _strategies; i++) 'timed-$i'];
    final filling = await openStore(SqliteEngine(file));
    savedValue(
      await filling.editLibrary([
        for (final id in ids)
          AddStrategy(sampleStrategy(id: id, prefix: '$id-'), writtenAt: 40),
      ]),
    );
    await filling.close();

    final store = await openStore(SqliteEngine(file));
    addTearDown(store.close);
    final times = <Duration>[];
    for (var run = 0; run < 5; run++) {
      final watch = Stopwatch()..start();
      final read = await store.writtenOf(ids);
      times.add(watch.elapsed);
      expect(read, isA<Done<Map<String, StrategyWritten>>>());
    }
    times.sort();
    printOnFailure('read times: ${times.map((t) => t.inMicroseconds)} µs');
    print('written versions of $_strategies strategies, fastest of 5: '
        '${times.first.inMicroseconds} µs, median ${times[2].inMicroseconds} µs');
    expect(times[2], lessThan(_budget));
  });
}
