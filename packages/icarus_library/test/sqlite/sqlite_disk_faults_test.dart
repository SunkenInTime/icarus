@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/sqlite/library_file.dart';
import 'package:icarus_library/src/sqlite/rows_database.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../store_support.dart';
import '../support.dart';
import 'fault_disk.dart';
import '../crash_harness.dart';
import 'fault_harness.dart';

ElementPatchOp _move(String opId, int revision, num x) => ElementPatchOp(
  opId: opId,
  elementPublicId: 'jett',
  expectedElementRevision: revision,
  payload: agentPayload('jett', {
    'type': 'jett',
    'position': {'dx': x, 'dy': 0},
  }),
  merge: FieldMerge(fields: ['position']),
);

Future<(num, int)> _jett(LibraryStore store) async {
  final page = pageOf(await store.readPage(strategyId, 'page-a'));
  final jett = page.elements.whereType<LiveElement>().singleWhere(
    (row) => row.publicId == 'jett',
  );
  return switch (jett.payload.data['position']) {
    final JsonObject position when position['dx'] is num => (
      position['dx']! as num,
      jett.revision,
    ),
    final other => fail('jett has no position: $other'),
  };
}

Future<List<(int, CommitResult)>> _moves(
  LibraryStore store,
  String run,
  int count,
) async {
  final outcomes = <(int, CommitResult)>[];
  for (var move = 1; move <= count; move++) {
    final int revision;
    switch (await store.readPage(strategyId, 'page-a')) {
      case Found():
        revision = (await _jett(store)).$2;
      case _:
        revision = 0;
    }
    outcomes.add((
      move,
      await store.commit(strategyId, _move('$run-$move', revision, move)),
    ));
  }
  return outcomes;
}

Set<num> _allowed(List<(int, CommitResult)> outcomes, num start) {
  num last = start;
  final inDoubt = <num>{};
  for (final (move, result) in outcomes) {
    switch (result) {
      case Saved():
        last = move;
        inDoubt.clear();
      case SaveInDoubt():
        inDoubt.add(move);
      case NotSaved() || NothingToSave() || Refused():
        break;
    }
  }
  return {last, ...inDoubt};
}

const _losses = [
  KeepsUnsynced(),
  DropsUnsynced(),
  TearsUnsynced(3),
  TearsUnsynced(4),
];

void _savesAfterCreation(FaultDrive drive, PowerLoss loss, String reason) {
  final rows = opened(drive.open());
  expect(
    rows.commit(const [Put('a', 'k', 'saved')]),
    isA<CommitApplied>(),
    reason: reason,
  );
  drive.disk.crashed = true;
  _closeAfterCrash(rows);
  drive.disk.powerLoss(loss);
  final reopened = opened(drive.open());
  expect(
    reopened.read('a', 'k'),
    isA<KeyHeld>().having((held) => held.value, 'value', 'saved'),
    reason: reason,
  );
  reopened.close();
}

void _closeAfterCrash(RowsDatabase rows) {
  try {
    rows.close();
  } on SqliteException {
    return;
  }
}

final class _RacedFiles implements LibraryFiles {
  _RacedFiles(this._files, this._meanwhile);

  final LibraryFiles _files;
  void Function()? _meanwhile;

  @override
  int? size(String path) {
    final found = _files.size(path);
    final meanwhile = _meanwhile;
    _meanwhile = null;
    meanwhile?.call();
    return found;
  }

  @override
  Uint8List head(String path, int length) => _files.head(path, length);

  @override
  Database open(String path) => _files.open(path);

  @override
  void pause(Duration duration) {}
}

void main() {
  late Contents seeded;

  setUpAll(() async {
    seeded = await seededContents();
  });

  test('a failed sync is a failure the caller receives, and after a power cut '
      'every saved move is there and none reported unsaved', () async {
    final harness = SqliteCrashHarness(const DropsUnsynced());
    addTearDown(harness.finish);
    var syncsFailed = 0;
    var failuresSeen = 0;
    for (var sync = 1; sync <= 30; sync++) {
      await harness.start(seeded);
      final store = await openStore(await harness.open());
      final (start, _) = await _jett(store);
      final target = harness.disk.syncs + sync;
      harness.disk.fault = FailSyncAt(target);
      final outcomes = await _moves(store, 'sync-$sync', 32);
      if (harness.disk.syncs >= target) syncsFailed++;
      if (outcomes.any((outcome) => outcome.$2 is! Saved)) failuresSeen++;
      await harness.crash();
      final reopened = await openStore(await harness.open());
      final (x, _) = await _jett(reopened);
      expect(
        _allowed(outcomes, start),
        contains(x),
        reason:
            'sync $sync failed: ${outcomes.map((o) => describeSaving(o.$2))}',
      );
    }
    expect(syncsFailed, greaterThanOrEqualTo(20));
    expect(failuresSeen, greaterThan(0));
  });

  test('a full disk is a failure the caller receives, the store saves again '
      'once there is room, and a power cut loses nothing saved', () async {
    final harness = SqliteCrashHarness(const DropsUnsynced());
    addTearDown(harness.finish);
    var refusedSeen = 0;
    for (var room = 0; room <= 40000; room += 2000) {
      await harness.start(seeded);
      final store = await openStore(await harness.open());
      final (start, _) = await _jett(store);
      harness.disk.fault = FullAfter(harness.disk.usedBytes + room);
      final full = await _moves(store, 'full-$room', 6);
      if (full.any((outcome) => outcome.$2 is NotSaved)) refusedSeen++;
      harness.disk.fault = const NoFault();
      final LibraryStore after;
      if (full.any((outcome) => outcome.$2 is SaveInDoubt)) {
        await store.close();
        after = await openStore(await harness.open());
      } else {
        after = store;
      }
      final (_, revision) = await _jett(after);
      savedValue(
        await after.commit(strategyId, _move('room-$room', revision, 99)),
      );
      await harness.crash();
      final reopened = await openStore(await harness.open());
      expect((await _jett(reopened)).$1, 99, reason: 'room $room');
      expect(
        _allowed(full, start),
        isNotEmpty,
        reason: full.map((o) => describeSaving(o.$2)).join(', '),
      );
    }
    expect(refusedSeen, greaterThan(5));
  });

  test('creating the library survives a crash or a power cut at any step: '
      'the next open has the library with its tables, and a save acknowledged '
      'after it survives a power cut', () async {
    for (final loss in _losses) {
      for (var step = 1; ; step++) {
        final drive = FaultDrive();
        drive.disk.fault = CrashAt(step);
        final created = drive.open();
        final reason = 'creation cut at step $step, ${lossName(loss)}';
        if (created case RowsOpened(:final rows)) rows.close();
        drive.disk.powerLoss(loss);
        _savesAfterCreation(drive, loss, reason);
        drive.unregister();
        if (created is RowsOpened) break;
      }
    }
  });

  test(
    'a sync that fails at any point of creating the library, with or '
    'without a power cut after it: the next open has the library with its '
    'tables, and a save acknowledged after it survives a power cut',
    () async {
      for (final loss in _losses) {
        var hit = true;
        for (var sync = 1; hit; sync++) {
          final drive = FaultDrive();
          drive.disk.fault = FailSyncAt(sync);
          if (drive.open() case RowsOpened(:final rows)) rows.close();
          hit = drive.disk.syncs >= sync;
          drive.disk.powerLoss(loss);
          _savesAfterCreation(
            drive,
            loss,
            'sync $sync of creating the library failed, then ${lossName(loss)}',
          );
          drive.unregister();
        }
      }
    },
  );

  test('a library file that is gone or empty while a log or a journal that '
      'holds pages remains, or a library whose first page is blank over more '
      'pages, is refused and every byte is left as it was', () async {
    final written = FaultDrive();
    final rows = opened(written.open());
    committed(rows.commit(const [Put('a', 'k', 'saved in the log')]));
    written.disk.crashed = true;
    _closeAfterCrash(rows);
    written.disk.powerLoss(const KeepsUnsynced());
    final log = written.disk.bytesOf('$libraryPath-wal');
    final library = written.disk.bytesOf(libraryPath);
    written.unregister();
    expect(log, isNotEmpty);
    expect(library.length, greaterThan(4096));

    final cases = <String, Map<String, Uint8List>>{
      'an empty file beside its log': {
        libraryPath: Uint8List(0),
        '$libraryPath-wal': log,
      },
      'an empty file beside a journal that holds pages': {
        libraryPath: Uint8List(0),
        '$libraryPath-journal': journalHoldingPages(),
      },
      'no file beside its log': {'$libraryPath-wal': log},
      'no file beside a journal that holds pages': {
        '$libraryPath-journal': journalHoldingPages(),
      },
      'a blank first page over more pages': {
        libraryPath: Uint8List.fromList(library)
          ..setRange(0, 4096, blankDatabasePage()),
      },
    };
    for (final MapEntry(key: name, value: files) in cases.entries) {
      final drive = FaultDrive();
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        drive.disk.replace(path, bytes);
      }
      expect(
        drive.open(),
        isA<RowsRefused>().having(
          (refused) => refused.failure,
          'failure',
          name.startsWith('a blank first page')
              ? isA<DamagedLibrary>()
              : isA<LibraryFileGone>(),
        ),
        reason: name,
      );
      for (final MapEntry(key: path, value: bytes) in files.entries) {
        expect(drive.disk.bytesOf(path), bytes, reason: '$name: $path');
      }
      for (final path in [
        libraryPath,
        '$libraryPath-wal',
        '$libraryPath-journal',
      ]) {
        expect(
          drive.disk.exists(path),
          files.containsKey(path),
          reason: '$name: $path',
        );
      }
      drive.unregister();
    }
  });

  test('an opener that looks while another creates the library sees it held, '
      'not a file gone with its log left behind', () async {
    final drive = FaultDrive();
    late final RowsDatabase winner;
    final files = _RacedFiles(
      FaultLibraryFiles(drive.disk, drive.vfs),
      () => winner = opened(drive.open()),
    );
    expect(openLibraryFile(libraryPath, files), isA<RowsHeld>());
    winner.close();
    drive.unregister();
  });

  test(
    'a commit whose outcome is unknown, followed by one that applies, '
    'writing or empty: after an app crash or a power cut the first is gone for good',
    () async {
      for (final loss in const [
        KeepsUnsynced(),
        DropsUnsynced(),
        TearsUnsynced(5),
      ]) {
        for (final second in const <List<Change>>[
          [Put('b', 'k', 'second')],
          [],
        ]) {
          final harness = SqliteCrashHarness(loss);
          await harness.start(const {});
          final lease = await leaseOf(await harness.open());
          committed(await lease.commit(const [Put('b', 'k', 'before')]));
          harness.disk.fault = FailSyncAt(harness.disk.syncs + 1);
          expect(
            await lease.commit(const [Put('a', 'k', 'first')]),
            isA<CommitUnknown>(),
            reason: '$loss',
          );
          harness.disk.fault = const NoFault();
          committed(await lease.commit(second));
          await harness.crash();
          final reopened = await leaseOf(await harness.open());
          expect(
            valueOf(await reopened.read('a', 'k')),
            isNull,
            reason: '$loss, second commit $second',
          );
          expect(
            valueOf(await reopened.read('b', 'k')),
            second.isEmpty ? 'before' : 'second',
            reason: '$loss',
          );
          await harness.finish();
        }
      }
    },
  );

  test(
    'damage to the file is an explicit failure, never a shorter library',
    () async {
      final harness = SqliteCrashHarness(const KeepsUnsynced());
      addTearDown(harness.finish);
      await harness.start(seeded);
      final seeding = await openStore(await harness.open());
      savedValue(
        await seeding.editLibrary([
          for (var i = 0; i < 40; i++)
            AddStrategy(sampleStrategy(id: 'extra-$i', prefix: 'extra-$i-')),
        ]),
      );
      final strategies = listOf(seeding).strategies.length;
      await seeding.close();
      final pristine = harness.disk.bytesOf(libraryPath);
      expect(pristine.length, greaterThan(8 * 4096));

      final damages = <String, Uint8List>{
        'cut in half': Uint8List.sublistView(pristine, 0, pristine.length ~/ 2),
        'header zeroed': Uint8List.fromList(pristine)..fillRange(0, 100, 0),
        for (var page = 1; page < pristine.length ~/ 4096; page++)
          'page $page overwritten': Uint8List.fromList(pristine)
            ..setRange(
              page * 4096,
              page * 4096 + 4096,
              List.generate(4096, (i) => (i * 7919 + page) & 0xff),
            ),
        for (var seed = 0; seed < 300; seed++)
          'bytes flipped, seed $seed': () {
            final random = Random(seed);
            final bytes = Uint8List.fromList(pristine);
            for (var flip = 0; flip < 1 + random.nextInt(8); flip++) {
              final at = random.nextInt(bytes.length);
              bytes[at] ^= 1 << random.nextInt(8);
            }
            return bytes;
          }(),
      };
      for (final MapEntry(key: damage, value: bytes) in damages.entries) {
        harness.disk.replace(libraryPath, bytes);
        final engine = await harness.open();
        switch (await LibraryStore.open(
          engine,
          canRead: readsKnownKinds,
          clock: fixedClock,
        )) {
          case StoreNotOpened(:final problem):
            expect(
              problem,
              isA<OpenStorageFailed>().having(
                (failed) => failed.failure,
                'failure',
                isA<DamagedLibrary>(),
              ),
              reason: damage,
            );
          case StoreOpened(:final store):
            final library = listOf(store);
            expect(
              library.strategies.length + library.unreadableStrategies.length,
              greaterThanOrEqualTo(strategies),
              reason: '$damage: the library opened shorter',
            );
            await store.close();
        }
      }
    },
  );
}
