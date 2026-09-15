import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'world_height_cached_queries.dart';
import 'world_height_native.dart';

Float64List input(List<double> xs) => Float64List.fromList([
      for (final x in xs) ...[x, 2, 3, 1, 0, 40, 1.8],
    ]);
HeightFrame answer(int stamp, Float64List queries) => HeightFrame(
      stamp,
      Float32List.fromList([
        for (var i = 0; i < queries.length; i += 7) ...[
          queries[i],
          0,
          queries[i] + 1,
          0,
          queries[i],
          1
        ]
      ]),
      Uint32List.fromList(
          [for (var i = 0; i <= queries.length ~/ 7; i++) i * 6]),
      const {'computeWallMicros': 1},
    );

void main() {
  test('only changed cones are computed and unchanged buffers stay reusable',
      () async {
    final batches = <List<double>>[];
    final scene = HeightSceneComputer((stamp, queries) async {
      batches.add(queries.toList());
      return answer(stamp, queries);
    });
    final first = await scene.compute(1, input([10, 20, 30]));
    final second = await scene.compute(2, input([10, 25, 30]));
    expect(batches.map((batch) => batch.length), [21, 7]);
    expect(identical(first.meshes[0], second.meshes[0]), isTrue);
    expect(identical(first.meshes[2], second.meshes[2]), isTrue);
    expect(first.meshes[1].first, 20);
    expect(second.meshes[1].first, 25);
    final third = await scene.compute(3, input([10, 25, 30]));
    expect(third.changedCones, 0);
    expect(third.transferredBytes, 0);
    expect(batches.length, 2);
    final reduced = await scene.compute(4, input([10]));
    expect(reduced.meshes.length, 1);
    expect(reduced.changedCones, 0);
    final expanded = await scene.compute(5, input([10, 45]));
    expect(expanded.meshes.map((mesh) => mesh.first), [10, 45]);
    expect(expanded.changedCones, 1);
  });

  test('in-flight input mutation cannot bind a mesh to the wrong query',
      () async {
    final completed = Completer<void>();
    final scene = HeightSceneComputer((stamp, queries) async {
      await completed.future;
      return answer(stamp, queries);
    });
    final queries = input([10]);
    final pending = scene.compute(1, queries);
    queries[0] = 20;
    completed.complete();
    expect((await pending).meshes.single.first, 10);
    final changed = await scene.compute(2, input([20]));
    expect(changed.changedCones, 1);
    expect(changed.meshes.single.first, 20);
  });

  test('failed replacement preserves the previous valid cache', () async {
    var reject = false;
    final scene = HeightSceneComputer((stamp, queries) async {
      if (reject) throw StateError('Injected native failure.');
      return answer(stamp, queries);
    });
    final first = await scene.compute(1, input([10]));
    reject = true;
    await expectLater(scene.compute(2, input([20])), throwsStateError);
    final previous = await scene.compute(3, input([10]));
    expect(previous.changedCones, 0);
    expect(identical(first.meshes.single, previous.meshes.single), isTrue);
    reject = false;
    expect((await scene.compute(4, input([20]))).changedCones, 1);
  });
}
