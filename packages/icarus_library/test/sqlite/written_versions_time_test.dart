@Tags(['timing'])
library;

import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:test/test.dart';

import '../store_support.dart';

const _strategies = 700;

const _tripwire = Duration(milliseconds: 60);

void main() {
  test('once warm, the written version of $_strategies strategies is read '
      'on SQLite within ${_tripwire.inMilliseconds} ms, a tripwire for a '
      'tenfold regression, not a tuned target', () async {
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
    await store.writtenOf(ids);
    final times = <Duration>[];
    for (var run = 0; run < 5; run++) {
      final watch = Stopwatch()..start();
      final read = await store.writtenOf(ids);
      times.add(watch.elapsed);
      expect(
        read,
        isA<Done<Map<String, StrategyWritten>>>().having(
          (done) => done.value.values.whereType<WrittenAt>().map(
            (written) => written.version,
          ),
          'versions',
          List.filled(_strategies, 40),
        ),
      );
    }
    times.sort();
    printOnFailure('read times: ${times.map((t) => t.inMicroseconds)} µs');
    expect(times[2], lessThan(_tripwire));
  });
}
