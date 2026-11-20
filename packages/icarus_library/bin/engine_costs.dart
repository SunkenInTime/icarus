import 'dart:io';

import 'package:icarus_library/icarus_library.dart';
import 'package:icarus_library/sqlite_storage.dart';
import 'package:icarus_library/src/sqlite/library_file.dart';
import 'package:icarus_library/src/sqlite/rows_database.dart';

import '../tool/engine_costs/costs.dart';

final class _CallingIsolateEngine implements StorageEngine {
  _CallingIsolateEngine(this.path);

  final String path;
  final _granted = <_CallingIsolateLease>[];

  @override
  Future<Leasing> lease() async =>
      switch (openLibraryFile(path, const DiskLibraryFiles())) {
        RowsOpened(:final rows) => Leased(
          _granted.adding(_CallingIsolateLease(rows)),
        ),
        RowsHeld() => const HeldByAnotherWriter(),
        RowsRefused(:final failure) => LeaseFailed(failure),
      };

  Future<void> close() async {
    for (final lease in _granted) {
      await lease.release();
    }
    _granted.clear();
  }
}

extension<T> on List<T> {
  T adding(T value) {
    add(value);
    return value;
  }
}

final class _CallingIsolateLease implements StorageLease {
  _CallingIsolateLease(this._rows);

  final RowsDatabase _rows;
  var _ended = false;

  @override
  int get maxKeyLength => rowsMaxKeyLength;

  @override
  LeaseStatus get status => _ended ? const Ended() : const Holding();

  @override
  Future<KeyRead> read(String area, String key) async =>
      _ended ? const KeyNotRead(LeaseEnded()) : _rows.read(area, key);

  @override
  Future<Stored<List<String>>> keys(String area, String prefix) async =>
      _ended ? const StorageFailed(LeaseEnded()) : _rows.keys(area, prefix);

  @override
  Future<Stored<List<StoredEntry>>> entries(String area, String prefix) async =>
      _ended ? const StorageFailed(LeaseEnded()) : _rows.entries(area, prefix);

  @override
  Future<Stored<void>> write(String area, Map<String, String> values) async =>
      _ended ? const StorageFailed(LeaseEnded()) : _rows.write(area, values);

  @override
  Future<Stored<void>> delete(String area, Iterable<String> keys) async =>
      _ended
      ? const StorageFailed(LeaseEnded())
      : _rows.delete(area, keys.toList());

  @override
  Future<Releasing> release() async {
    if (!_ended) {
      _ended = true;
      _rows.close();
    }
    return const Released();
  }
}

Future<void> _report(String name, List<String> lines) async {
  stdout.writeln(name);
  for (final line in lines) {
    stdout.writeln('  $line');
  }
}

Future<void> main(List<String> arguments) async {
  final folder = arguments.isEmpty
      ? Directory.systemTemp.path
      : arguments.single;
  final directory = await Directory(folder).createTemp('icarus-engine-costs-');
  try {
    final storage = MemoryStorage();
    await _report(
      'memory engine',
      await measure(
        () => MemoryEngine(storage),
        (engine) => (engine as MemoryEngine).close(),
      ),
    );

    final path = '${directory.path}/library.sqlite';
    await _report(
      'SQLite engine, on its own isolate, files in ${directory.path}',
      await measure(
        () => SqliteEngine(path),
        (engine) => (engine as SqliteEngine).close(),
      ),
    );
    stdout.writeln(
      '  library file: ${(File(path).lengthSync() / 1048576).toStringAsFixed(1)} MiB',
    );

    final inline = '${directory.path}/inline.sqlite';
    await _report(
      'SQLite on the calling isolate, for comparison only',
      await measure(
        () => _CallingIsolateEngine(inline),
        (engine) => (engine as _CallingIsolateEngine).close(),
      ),
    );
  } finally {
    await directory.delete(recursive: true);
  }
}
