@TestOn('vm')
library;

import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:icarus_library/src/sqlite/sqlite_engine.dart'
    show SqliteLeaseWorker;
import 'package:test/test.dart';

import '../crash_harness.dart';
import 'library_process_launcher.dart';

void main() {
  late Directory directory;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('icarus-lifecycle-');
    path = '${directory.path}/library.sqlite';
  });

  tearDown(() => directory.delete(recursive: true));

  tearDownAll(removeLibraryProcess);

  test('a lease asked for while the engine closes is refused or ended by the '
      'close, and once close returns the next engine can lease', () async {
    for (var round = 0; round < 10; round++) {
      final file = '${directory.path}/closing-$round.sqlite';
      final engine = SqliteEngine(file);
      final leasing = engine.lease();
      final closing = engine.close();
      await closing;
      switch (await leasing) {
        case Leased(:final lease):
          expect(lease.status, isA<Ended>(), reason: 'round $round');
        case LeaseFailed(failure: EngineClosed()):
          break;
        case final other:
          fail('round $round: $other');
      }
      final next = SqliteEngine(file);
      expect(await next.lease(), isA<Leased>(), reason: 'round $round');
      await next.close();
    }
  });

  test('a worker that stops with a commit held and a release queued answers '
      'every call, close returns, and the file can be leased again', () async {
    final engine = SqliteEngine(path);
    final lease = await leaseOf(engine) as SqliteLease;
    committed(await lease.commit(const [Put('a', 'k', 'before')]));
    final pending = engine.holdNextCommit();
    final writing = lease.commit(const [Put('a', 'k', 'held')]);
    await pending.reached;
    final releasing = lease.release();
    await lease.stopWorker();
    expect(
      await writing.timeout(const Duration(seconds: 10)),
      isA<CommitUnknown>(),
    );
    expect(
      await releasing.timeout(const Duration(seconds: 10)),
      isA<ReleaseFailed>(),
    );
    expect(lease.status, isA<Ended>());
    expect(
      await lease.commit(const [Put('a', 'k', 'late')]),
      isA<CommitRefused>().having(
        (refused) => refused.failure,
        'failure',
        isA<LeaseEnded>(),
      ),
    );
    await engine.close().timeout(const Duration(seconds: 10));
    final next = SqliteEngine(path);
    final reopened = await leaseOf(next);
    expect(valueOf(await reopened.read('a', 'k')), anyOf('before', 'held'));
    await next.close();
  });

  test('a worker killed while it holds the lease lets go of the file: this '
      'process and another can lease it at once', () async {
    Future<SqliteEngine> killedHolder(String file) async {
      final engine = SqliteEngine(file);
      final lease = await leaseOf(engine) as SqliteLease;
      committed(await lease.commit(const [Put('a', 'k', 'v')]));
      await lease.stopWorker();
      return engine;
    }

    for (final round in [1, 2, 3]) {
      final file = '${directory.path}/killed-$round.sqlite';
      final first = await killedHolder(file);
      final here = SqliteEngine(file);
      expect(await here.lease(), isA<Leased>(), reason: 'round $round, here');
      await here.close();
      final second = await killedHolder(file);
      final elsewhere = await runLibraryProcess('try', file);
      expect(
        '${elsewhere.stdout}'.trim(),
        'leased',
        reason: 'round $round, another process',
      );
      await first.close();
      await second.close();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('two closes at once both finish with the same answer', () async {
    final engine = SqliteEngine(path);
    for (var lease = 0; lease < 3; lease++) {
      await (await leaseOf(engine)).release();
    }
    await leaseOf(engine);
    final closing = [engine.close(), engine.close()];
    final [first, second] = await Future.wait(closing);
    expect(first, isA<Released>());
    expect(identical(first, second), isTrue);
  });

  test('a commit held for the contract is let through when its worker stops '
      'before it is reached, so a test waiting on it cannot hang', () async {
    final engine = SqliteEngine(path);
    final lease = await leaseOf(engine) as SqliteLease;
    final pending = engine.holdNextCommit();
    await lease.stopWorker();
    await pending.reached.timeout(const Duration(seconds: 10));
    expect(
      await lease.commit(const [Put('a', 'k', 'v')]),
      isA<CommitRefused>(),
    );
    await engine.close();
  });

  test('a library path ending in the name of one of SQLite\'s own companion '
      'files, in any case, is refused when the engine is made', () {
    for (final suffix in ['-wal', '-shm', '-journal', '-WAL', '-Journal']) {
      expect(
        () => SqliteEngine('$path$suffix'),
        throwsArgumentError,
        reason: suffix,
      );
    }
  });

  test('a commit with one bad name in any kind of change is refused whole, '
      'whatever the kind', () async {
    final engine = SqliteEngine(path);
    final lease = await leaseOf(engine);
    committed(
      await lease.commit(const [Put('a', 'x', 'old'), Put('b', 'y', 'old')]),
    );
    final long = 'k' * (lease.maxKeyLength + 1);
    for (final bad in <Change>[
      const Put('a', 'Bad', 'v'),
      const Delete('a', 'Bad'),
      const ClearArea('Bad'),
      Put('a', long, 'v'),
      Delete('a', long),
      const ClearArea(''),
    ]) {
      expect(
        await lease.commit([
          const Put('a', 'x', 'new'),
          bad,
          const ClearArea('b'),
        ]),
        isA<CommitRefused>(),
        reason: '$bad',
      );
      expect(valueOf(await lease.read('a', 'x')), 'old', reason: '$bad');
      expect(valueOf(await lease.read('b', 'y')), 'old', reason: '$bad');
    }
    await engine.close();
  });
}
