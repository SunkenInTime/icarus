import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';

import '../crash_harness.dart';
import '../store_support.dart';
import '../support.dart';

const probeArea = 'probe';

const probeKeys = 24;

const probeAreas = ['probe/a', 'probe/b', 'probe/c'];

const probeAreaKeys = 8;

List<Change> probeCommit(int generation) => [
  const ClearArea('probe/c'),
  for (final area in probeAreas.take(2))
    for (var key = 0; key < probeAreaKeys; key++)
      Put(area, 'k$key', '$generation-${'x' * (key * 409)}'),
  for (var key = 0; key < probeAreaKeys; key++)
    Put('probe/c', 'c-$generation-$key', '$generation'),
];

const handoffBatches = 20;

Map<String, String> handoffBatch(int batch) => {
  for (var key = 0; key < probeKeys; key++)
    'k$key': '$batch-${'x' * (key * 211)}',
};

ElementPatchOp moveJett(int move, int revision) => ElementPatchOp(
  opId: 'kill-move-$move',
  elementPublicId: 'jett',
  expectedElementRevision: revision,
  payload: agentPayload('jett', {
    'type': 'jett',
    'position': {'dx': move, 'dy': 0},
  }),
  merge: FieldMerge(fields: ['position']),
);

Future<(int, int)> jettPosition(LibraryStore store) async {
  final page = pageOf(await store.readPage(strategyId, 'page-a'));
  final jett = page.elements.whereType<LiveElement>().singleWhere(
    (row) => row.publicId == 'jett',
  );
  return switch (jett.payload.data['position']) {
    {'dx': final int x} => (x, jett.revision),
    {'dx': final num x} => (x.toInt(), jett.revision),
    final other => throw StateError('jett has no position: $other'),
  };
}

final class ProbingEngine implements StorageEngine {
  ProbingEngine(this.inner);

  final StorageEngine inner;

  StorageLease? granted;

  @override
  Future<Leasing> lease() async {
    final leasing = await inner.lease();
    if (leasing case Leased(:final lease)) granted = lease;
    return leasing;
  }
}

Future<void> main(List<String> arguments) async {
  final [mode, path] = arguments;
  final engine = SqliteEngine(path);
  if (mode == 'hold') {
    if (await engine.lease() case Leased()) stdout.writeln('held');
    await stdin.drain<void>();
    await engine.close();
    return;
  }
  if (mode == 'handoff') {
    final lease = switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => throw StateError('$other'),
    };
    committed(await put(lease, probeArea, handoffBatch(0)));
    stdout.writeln('ready');
    stdin.readLineSync();
    final writes = [
      for (var batch = 1; batch <= handoffBatches; batch++)
        put(lease, probeArea, handoffBatch(batch)),
    ];
    await lease.release();
    final results = await Future.wait(writes);
    stdout.writeln(
      'released ${results.whereType<CommitApplied>().length} written',
    );
    while (stdin.readLineSync() != null) {}
    return;
  }
  if (mode == 'seed') {
    final lease = switch (await engine.lease()) {
      Leased(:final lease) => lease,
      final other => throw StateError('$other'),
    };
    for (final MapEntry(key: area, value: values)
        in (await seededContents()).entries) {
      committed(await put(lease, area, values));
    }
    await engine.close();
    stdout.writeln('seeded');
    return;
  }
  final probing = ProbingEngine(engine);
  final store = await openStore(probing);
  var (move, revision) = await jettPosition(store);
  final lease = probing.granted!;
  var probe = switch (await lease.read('probe/a', 'k0')) {
    KeyHeld(:final value) => int.parse(value.split('-').first),
    KeyMissing() || KeyNotRead() => 0,
  };
  while (true) {
    move++;
    stdout.writeln('moving $move');
    switch (await store.commit(strategyId, moveJett(move, revision))) {
      case Saved():
        revision++;
        stdout.writeln('saved $move');
      case final other:
        throw StateError('not saved: ${describeSaving(other)}');
    }
    probe++;
    stdout.writeln('writing $probe');
    switch (await lease.commit(probeCommit(probe))) {
      case CommitApplied():
        stdout.writeln('wrote $probe');
      case final other:
        throw StateError('not written: $other');
    }
  }
}
