@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../crash_harness.dart';
import '../store_support.dart';
import '../support.dart';
import 'library_process.dart';

final class FileHarness implements EngineHarness {
  FileHarness(this.path);

  final String path;

  @override
  Future<StorageEngine> open() async => SqliteEngine(path);

  @override
  Future<void> close(StorageEngine engine) => (engine as SqliteEngine).close();

  @override
  Future<void> crash(StorageEngine engine) => (engine as SqliteEngine).close();

  @override
  PendingWrite holdNextWrite(StorageEngine engine) =>
      (engine as SqliteEngine).holdNextCommit();
}

Future<String> _refusal(String path) async {
  final engine = SqliteEngine(path);
  final leasing = await engine.lease();
  await engine.close();
  return switch (leasing) {
    Leased() => 'leased',
    HeldByAnotherWriter() => 'held',
    LeaseFailed(:final failure) => '$failure',
  };
}

Future<(String, int, int)> _holdBriefly(String path) async {
  final engine = SqliteEngine(path);
  final leasing = await engine.lease();
  final start = DateTime.now().microsecondsSinceEpoch;
  await Future<void>.delayed(const Duration(milliseconds: 150));
  final end = DateTime.now().microsecondsSinceEpoch;
  await engine.close();
  return switch (leasing) {
    Leased() => ('leased', start, end),
    HeldByAnotherWriter() => ('held', 0, 0),
    LeaseFailed(:final failure) => ('failed: $failure', 0, 0),
  };
}

Future<Process> _start(String mode, String path) => Process.start(
  Platform.resolvedExecutable,
  ['run', 'test/sqlite/library_process.dart', mode, path],
);

Future<int> _probeGeneration(StorageLease lease, String where) async {
  final generations = <String>{};
  for (final area in probeAreas.take(2)) {
    final entries = stored(await lease.entries(area, ''));
    expect(
      entries.length,
      anyOf(0, probeAreaKeys),
      reason: '$where: $area holds part of a commit',
    );
    generations.addAll(entries.map((entry) => entry.value.split('-').first));
  }
  if (generations.isEmpty) {
    expect(stored(await lease.keys('probe/c', '')), isEmpty, reason: where);
    return 0;
  }
  expect(generations, hasLength(1), reason: '$where: areas from two commits');
  final generation = generations.single;
  expect(
    stored(await lease.keys('probe/c', '')),
    [for (var key = 0; key < probeAreaKeys; key++) 'c-$generation-$key']
      ..sort(),
    reason: '$where: the area clear did not land with its puts',
  );
  return int.parse(generation);
}

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-sqlite-');
    path = '${directory.path}/library.sqlite';
  });

  tearDown(() => directory.delete(recursive: true));

  group('the engine contract on library files', () {
    for (final check in engineContract) {
      test(check.name, () async {
        final result = await check.run(FileHarness(path));
        expect(result, isA<Passed>(), reason: '$result');
      });
    }
  });

  test('the store saves and reopens on a library file', () async {
    final engine = SqliteEngine(path);
    final store = await openStore(engine);
    savedValue(await store.editLibrary([AddStrategy(sampleStrategy())]));
    final moved = savedValue(
      await store.commit(
        strategyId,
        everyOpType()['element.patch to another page']!,
      ),
    );
    await store.close();
    await engine.close();

    final reopened = await openStore(SqliteEngine(path));
    expect(listOf(reopened).strategies.single, moved.change.summary);
    final pageB = pageOf(await reopened.readPage(strategyId, 'page-b'));
    expect(elementOn(pageB, 'jett').pagePublicId, 'page-b');
    await reopened.close();
  });

  test('one library file, one writer: another isolate or process is refused '
      'until the holder lets go', () async {
    final first = SqliteEngine(path);
    await leaseOf(first);
    final file = path;
    expect(await Isolate.run(() => _refusal(file)), 'held');
    await first.close();

    final holder = await _start('hold', path);
    final held = Completer<void>();
    final listening = holder.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line == 'held') held.complete();
        });
    await held.future.timeout(const Duration(minutes: 2));
    expect(await _refusal(path), 'held');
    await holder.stdin.close();
    expect(await holder.exitCode, 0);
    await listening.cancel();
    expect(await _refusal(path), 'leased');
  });

  test('writes in flight when a process releases its lease land whole before '
      'another process is granted one', () async {
    final first = await _start('handoff', path);
    final lines = <String>[];
    final reading = first.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add);
    while (!lines.contains('ready')) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    first.stdin.writeln('go');
    await first.stdin.flush();
    final engine = SqliteEngine(path);
    late StorageLease lease;
    while (true) {
      switch (await engine.lease()) {
        case Leased(lease: final granted):
          lease = granted;
        case HeldByAnotherWriter():
          continue;
        case LeaseFailed(:final failure):
          fail('$failure');
      }
      break;
    }
    final generations = <String>{};
    for (var key = 0; key < probeKeys; key++) {
      final value = valueOf(await lease.read(probeArea, 'k$key'));
      generations.add(value!.split('-').first);
    }
    expect(generations, {'$handoffBatches'});
    await first.stdin.close();
    expect(await first.exitCode, 0);
    await reading.cancel();
    expect(lines, contains('released $handoffBatches written'));
    await engine.close();
  });

  for (final existing in [true, false]) {
    test(
      'four isolates asking at once for a library that '
      '${existing ? 'exists' : 'does not exist yet'}: never two holding it '
      'at the same time, one always gets it, and it opens afterwards',
      () async {
        for (var round = 0; round < 20; round++) {
          final file = '${directory.path}/at-once-$round.sqlite';
          if (existing) await SqliteEngine(file).close();
          if (existing) expect(await _refusal(file), 'leased');
          final outcomes = await Future.wait([
            for (var i = 0; i < 4; i++) Isolate.run(() => _holdBriefly(file)),
          ]);
          final held = [
            for (final (outcome, start, end) in outcomes)
              if (outcome == 'leased') (start, end),
          ]..sort((a, b) => a.$1.compareTo(b.$1));
          expect(held, isNotEmpty, reason: 'round $round: $outcomes');
          for (var i = 1; i < held.length; i++) {
            expect(
              held[i].$1,
              greaterThanOrEqualTo(held[i - 1].$2),
              reason: 'round $round: two leases overlapped',
            );
          }
          expect(
            [for (final (outcome, _, _) in outcomes) outcome],
            everyElement(anyOf('leased', 'held')),
            reason: 'round $round',
          );
          expect(await _refusal(file), 'leased', reason: 'round $round');
        }
      },
    );
  }

  test('a process stopped at a random moment while it creates the library '
      'leaves a library that the next open makes or opens', () async {
    final random = Random(11);
    for (var round = 0; round < 12; round++) {
      final file = '${directory.path}/stopped-$round.sqlite';
      final creator = await _start('create', file);
      final lines = <String>[];
      final reading = creator.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      while (!lines.contains('starting')) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(80)));
      creator.kill(ProcessSignal.sigkill);
      await creator.exitCode;
      await reading.cancel();
      expect(await _refusal(file), 'leased', reason: 'round $round: $lines');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'a file that is not a library is refused, never opened empty; an empty '
    'file is a library whose creation was cut short, and is created',
    () async {
      await File(path).writeAsString('notes from a user');
      expect(await _refusal(path), contains('not an Icarus library'));
      await File(path).writeAsBytes(const []);
      expect(await _refusal(path), 'leased');
      await File(path).delete();

      sqlite3.open(path)
        ..execute('CREATE TABLE t (x)')
        ..close();
      expect(await _refusal(path), contains('not an Icarus library'));
      await File(path).delete();

      expect(await _refusal(path), 'leased');
      sqlite3.open(path)
        ..execute('PRAGMA user_version = 2')
        ..close();
      expect(await _refusal(path), contains('newer build'));
    },
  );

  test('a library whose file is gone but whose log is there is refused, not '
      'made new', () async {
    await File('$path-wal').writeAsString('frames');
    expect(await _refusal(path), contains('-wal is still there'));
  });

  test('a path that is a folder and a missing folder are failures, and the '
      'next open recovers', () async {
    await Directory(path).create();
    expect(await _refusal(path), contains('SQLite'));
    await Directory(path).delete();
    expect(await _refusal(path), 'leased');
    expect(
      await _refusal('${directory.path}/missing/library.sqlite'),
      contains('SQLite'),
    );
  });

  test('a process killed at random points loses no saved edit, and a commit '
      'across three areas with an area clear in flight is wholly there or '
      'wholly absent', () async {
    final seeding = await _start('seed', path);
    expect(await seeding.exitCode, 0);
    final random = Random(7);
    var kills = 0;
    var probeBefore = 0;
    for (var run = 0; run < 24; run++) {
      final writer = await _start('write', path);
      final lines = <String>[];
      final reading = writer.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
      final started = Stopwatch()..start();
      while (!lines.any((line) => line.startsWith('saved'))) {
        if (started.elapsed > const Duration(minutes: 2)) {
          fail('the writer did not start');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(Duration(milliseconds: random.nextInt(400)));
      writer.kill(ProcessSignal.sigkill);
      await writer.exitCode;
      await reading.cancel();
      kills++;

      int last(String word) => lines
          .where((line) => line.startsWith('$word '))
          .map((line) => int.parse(line.split(' ').last))
          .fold(0, max);
      final engine = SqliteEngine(path);
      final store = await openStore(engine);
      final (x, _) = await jettPosition(store);
      expect(
        [last('saved'), last('saved') + 1],
        contains(x),
        reason: 'run $run',
      );
      expect(x, lessThanOrEqualTo(last('moving')), reason: 'run $run');
      await store.close();
      final lease = await leaseOf(engine);
      final probe = await _probeGeneration(lease, 'run $run');
      final acknowledged = max(probeBefore, last('wrote'));
      expect(
        [acknowledged, acknowledged + 1],
        contains(probe),
        reason: 'run $run',
      );
      probeBefore = probe;
      await engine.close();
    }
    expect(kills, 24);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
