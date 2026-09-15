import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:icarus/view_cone/height_native.dart';
import 'package:icarus/view_cone/height_query_queue.dart';

Float64List query(double x) => Float64List.fromList([x, 2, 3, 1, 0, 40, 1]);
HeightFrame frame(int stamp, Float64List queries) => HeightFrame(
    stamp,
    Float32List.fromList([
      for (var i = 0; i < queries.length; i += 7) ...[queries[i], 0, 0, 0, 0, 0]
    ]),
    Uint32List.fromList([for (var i = 0; i <= queries.length ~/ 7; i++) i * 6]),
    {});

void main() {
  test(
      'completed callbacks retain their query after supersession, but stop on removal',
      () async {
    final started = Completer<void>(), release = Completer<void>();
    var calls = 0;
    final recorded = <(String, double)>[];
    final queue = HeightQueryQueue((stamp, queries) async {
      if (++calls == 1) {
        started.complete();
        await release.future;
      }
      return frame(stamp, queries);
    });
    final first = queue.request('retained', query(1),
        onComputed: (mesh) => recorded.add(('first', mesh.first)));
    final removed = queue.request('removed', query(4),
        onComputed: (mesh) => recorded.add(('removed', mesh.first)));
    await started.future;
    final latest = queue.request('retained', query(2),
        onComputed: (mesh) => recorded.add(('latest', mesh.first)));
    queue.remove('removed');
    expect(await first, isNull);
    expect(await removed, isNull);
    release.complete();
    expect((await latest)!.first, 2);
    expect(recorded, [('first', 1.0), ('latest', 2.0)]);
    await queue.close();
  });
  test('continuous updates cannot starve cones beyond the first batch',
      () async {
    final started = Completer<void>(), release = Completer<void>();
    final batches = <List<double>>[];
    final queue = HeightQueryQueue((stamp, queries) async {
      batches.add([for (var i = 0; i < queries.length; i += 7) queries[i]]);
      if (batches.length == 1) {
        started.complete();
        await release.future;
      }
      return frame(stamp, queries);
    });
    final original = [
      for (var i = 0; i < 20; i++) queue.request(i, query(i.toDouble()))
    ];
    await started.future;
    final updates = [
      for (var i = 0; i < 10; i++) queue.request(i, query(100 + i.toDouble()))
    ];
    release.complete();
    await Future.wait([...original, ...updates]);
    expect(batches, [
      [for (var i = 0; i < 10; i++) i.toDouble()],
      [for (var i = 10; i < 20; i++) i.toDouble()],
      [for (var i = 0; i < 10; i++) 100 + i.toDouble()],
    ]);
    await queue.close();
  });
  test('more than ten cones batch, unchanged poses keep exact buffer identity',
      () async {
    final counts = <int>[];
    final queue = HeightQueryQueue((stamp, queries) async {
      counts.add(queries.length ~/ 7);
      return frame(stamp, queries);
    });
    final results = await Future.wait(
        [for (var i = 0; i < 23; i++) queue.request(i, query(i.toDouble()))]);
    expect(counts, [10, 10, 3]);
    for (var i = 0; i < 23; i++) {
      expect(results[i]!.first, i);
      expect(identical(await queue.request(i, query(i.toDouble())), results[i]),
          isTrue);
    }
    expect(counts, [10, 10, 3]);
    await queue.close();
  });

  test(
      'pending poses coalesce and an in-flight obsolete pose never completes as current',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final queried = <double>[];
    final queue = HeightQueryQueue((stamp, queries) async {
      queried.add(queries.first);
      if (queried.length == 1) {
        started.complete();
        await release.future;
      }
      return frame(stamp, queries);
    });
    final first = queue.request('cone', query(1));
    await started.future;
    final second = queue.request('cone', query(2));
    final mutable = query(3);
    final third = queue.request('cone', mutable);
    mutable[0] = 999;
    expect(await first, isNull);
    expect(await second, isNull);
    release.complete();
    expect((await third)!.first, 3);
    expect(queried, [1, 3]);
    await queue.close();
  });

  test('capture barrier waits and propagates a compute failure', () async {
    final release = Completer<void>();
    final queue = HeightQueryQueue((stamp, queries) async {
      await release.future;
      throw StateError('native failure');
    });
    final result = queue.request('cone', query(1));
    final failed = expectLater(result, throwsStateError);
    var settled = false;
    final barrier = expectLater(
        queue.waitIdle().whenComplete(() => settled = true), throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    release.complete();
    await failed;
    await barrier;
    await queue.close();
  });

  test('closing while busy cancels consumers then drains native work',
      () async {
    final started = Completer<void>(), release = Completer<void>();
    final queue = HeightQueryQueue((stamp, queries) async {
      started.complete();
      await release.future;
      return frame(stamp, queries);
    });
    final result = queue.request('cone', query(1));
    await started.future;
    var closed = false;
    final closing = queue.close().then((_) => closed = true);
    expect(await result, isNull);
    expect(closed, isFalse);
    release.complete();
    await closing;
    expect(closed, isTrue);
    await expectLater(queue.request('cone', query(1)), throwsStateError);
  });
}
