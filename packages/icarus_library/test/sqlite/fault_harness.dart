import 'dart:math';

import 'package:icarus_library/engine_contract.dart';
import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/src/engines/commit.dart';
import 'package:icarus_library/src/sqlite/library_file.dart';
import 'package:icarus_library/src/sqlite/rows_database.dart';
import 'package:sqlite3/sqlite3.dart';

import '../crash_harness.dart';
import '../store_support.dart';
import 'fault_disk.dart';

const libraryPath = '/library.sqlite';

final _isolateMark = Random.secure().nextInt(1 << 32);

var _vfsCount = 0;

final class FaultDrive {
  FaultDrive() : disk = FaultDisk() {
    vfs = FaultVfs(disk, name: 'fault-$_isolateMark-${_vfsCount++}');
    sqlite3.registerVirtualFileSystem(vfs);
  }

  final FaultDisk disk;
  late final FaultVfs vfs;
  final _open = <InlineLease>[];

  RowsOpening open() =>
      openLibraryFile(libraryPath, FaultLibraryFiles(disk, vfs));

  void crash(PowerLoss loss) {
    disk.crashed = true;
    for (final lease in [..._open]) {
      lease.end();
    }
    disk.powerLoss(loss);
  }

  void unregister() {
    for (final lease in [..._open]) {
      lease.end();
    }
    sqlite3.unregisterVirtualFileSystem(vfs);
  }
}

final class FaultEngine implements StorageEngine {
  FaultEngine(this.drive);

  final FaultDrive drive;

  @override
  Future<Leasing> lease() async => switch (drive.open()) {
    RowsOpened(:final rows) => Leased(InlineLease(drive, rows, this)),
    RowsHeld() => const HeldByAnotherWriter(),
    RowsRefused(:final failure) => LeaseFailed(failure),
  };

  Future<void> close() async {
    for (final lease in [...drive._open]) {
      if (identical(lease.engine, this)) lease.end();
    }
  }
}

final class InlineLease implements StorageLease {
  InlineLease(this._drive, this.rows, this.engine) {
    _drive._open.add(this);
  }

  final FaultDrive _drive;
  final RowsDatabase rows;
  final FaultEngine engine;

  @override
  int get maxKeyLength => rowsMaxKeyLength;

  @override
  LeaseStatus get status => _ended ? const Ended() : const Holding();

  @override
  Future<KeyRead> read(String area, String key) async =>
      _ended ? const KeyNotRead(LeaseEnded()) : rows.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _ended ? const StorageFailed(LeaseEnded()) : rows.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      _ended ? const StorageFailed(LeaseEnded()) : rows.entries(area, prefix);

  Future<Committing> commit(List<Change> changes) async =>
      _ended ? const CommitRefused(LeaseEnded()) : rows.commit(changes);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async =>
      storedOf(
        await commit([
          for (final MapEntry(:key, :value) in values.entries)
            ChangePut(area, key, value),
        ]),
      );

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async =>
      storedOf(await commit([for (final key in keys) ChangeDelete(area, key)]));

  var _ended = false;

  void end() {
    if (!_drive._open.remove(this)) return;
    _ended = true;
    try {
      rows.close();
    } on SqliteException {
      return;
    }
  }

  @override
  Future<Releasing> release() async {
    end();
    return const Released();
  }
}

RowsDatabase opened(RowsOpening opening) => switch (opening) {
  RowsOpened(:final rows) => rows,
  RowsHeld() => throw StateError('held by another writer'),
  RowsRefused(:final failure) => throw StateError('not opened: $failure'),
};

String lossName(PowerLoss loss) => switch (loss) {
  KeepsUnsynced() => 'keeps unsynced writes (an app crash)',
  DropsUnsynced() => 'drops unsynced writes (a power cut)',
  TearsUnsynced(:final seed) =>
    'keeps a random part of unsynced writes, seed $seed (a power cut mid-write)',
};

final class SqliteCrashHarness implements CrashHarness {
  SqliteCrashHarness(this.loss);

  final PowerLoss loss;
  FaultDrive? _drive;
  int _armedFrom = 0;

  FaultDrive get drive => _drive!;

  FaultDisk get disk => drive.disk;

  @override
  String get name => 'SQLite on a disk that ${lossName(loss)}';

  @override
  Future<void> start(Contents seed) async {
    _drive?.unregister();
    final drive = _drive = FaultDrive();
    final rows = opened(drive.open());
    for (final MapEntry(key: area, value: values) in seed.entries) {
      if (rows.commit([
            for (final MapEntry(:key, :value) in values.entries)
              ChangePut(area, key, value),
          ])
          case CommitRefused(:final failure) || CommitInDoubt(:final failure)) {
        throw StateError('seed not written: $failure');
      }
    }
    rows.close();
  }

  @override
  Future<StorageEngine> open() async => FaultEngine(drive);

  @override
  void arm(int step) {
    _armedFrom = disk.steps;
    disk.fault = CrashAt(disk.steps + step);
  }

  @override
  int get stepsSinceArmed => disk.steps - _armedFrom;

  @override
  void disarm() {
    _armedFrom = disk.steps;
    disk.fault = const NoFault();
  }

  @override
  bool get crashed => disk.crashed;

  @override
  Future<void> crash() async => drive.crash(loss);

  @override
  Future<void> finish() async {
    _drive?.unregister();
    _drive = null;
  }
}

final class FaultContractHarness implements EngineHarness {
  FaultContractHarness(this.loss);

  final PowerLoss loss;
  final drive = FaultDrive();

  @override
  Future<StorageEngine> open() async => FaultEngine(drive);

  @override
  Future<void> close(StorageEngine engine) => (engine as FaultEngine).close();

  @override
  Future<void> crash(StorageEngine engine) async => drive.crash(loss);
}
