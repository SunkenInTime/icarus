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

Future<Process> _start(String mode, String path) => Process.start(
  Platform.resolvedExecutable,
  ['run', 'test/sqlite/library_process.dart', mode, path],
);

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
    expect(reopened.library.strategies.single, moved.change.summary);
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
    var refusals = 0;
    final engine = SqliteEngine(path);
    late StorageLease lease;
    while (true) {
      switch (await engine.lease()) {
        case Leased(lease: final granted):
          lease = granted;
        case HeldByAnotherWriter():
          refusals++;
          continue;
        case LeaseFailed(:final failure):
          fail('$failure');
      }
      break;
    }
    final generations = <String>{};
    for (var key = 0; key < probeKeys; key++) {
      final value = stored<String?>(await lease.read(probeArea, 'k$key'));
      generations.add(value!.split('-').first);
    }
    expect(refusals, greaterThan(0));
    expect(generations, {'$handoffBatches'});
    await first.stdin.close();
    expect(await first.exitCode, 0);
    await reading.cancel();
    expect(lines, contains('released $handoffBatches written'));
    await engine.close();
  });

  test('a file that is not a library is refused, never opened empty', () async {
    await File(path).writeAsString('notes from a user');
    expect(await _refusal(path), contains('not an Icarus library'));
    await File(path).writeAsBytes(const []);
    expect(await _refusal(path), contains('not an Icarus library'));
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
  });

  test('a library whose file is gone but whose log is there is refused, not '
      'made new', () async {
    await File('$path-wal').writeAsString('frames');
    expect(await _refusal(path), contains('log is still there'));
  });

  test('a rename that fails and a missing folder are failures, and the next '
      'open recovers', () async {
    await Directory(path).create();
    expect(await _refusal(path), contains('FileSystemException'));
    await Directory(path).delete();
    expect(await _refusal(path), 'leased');
    expect(File('$path.creating').existsSync(), isFalse);
    expect(
      await _refusal('${directory.path}/missing/library.sqlite'),
      contains('SQLite'),
    );
  });

  test('a process killed at random points loses no saved edit, and the write '
      'in flight is wholly there or wholly absent', () async {
    final seeding = await _start('seed', path);
    expect(await seeding.exitCode, 0);
    final random = Random(7);
    var kills = 0;
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
      final generations = <String>{};
      for (var key = 0; key < probeKeys; key++) {
        final value = stored<String?>(await lease.read(probeArea, 'k$key'));
        generations.add((value ?? '0').split('-').first);
      }
      expect(generations, hasLength(1), reason: 'run $run: a torn write');
      expect(
        [last('wrote'), last('wrote') + 1],
        contains(int.parse(generations.single)),
        reason: 'run $run',
      );
      await engine.close();
    }
    expect(kills, 24);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
