import 'package:sqlite3/sqlite3.dart';

import '../engines/names.dart';
import '../store/engine.dart';

const libraryApplicationId = 0x49434c42;

const librarySchemaVersion = 1;

const rowsMaxKeyLength = 1024;

String _undescribed(FormatException error) =>
    'SQLite reported a problem in text it could not decode: ${error.message}';

StorageFailure failureOf(SqliteException error) =>
    DeviceFailure('SQLite ${error.extendedResultCode}: ${error.message}');

sealed class RowsOpening {
  const RowsOpening();
}

final class RowsOpened extends RowsOpening {
  const RowsOpened(this.rows);

  final RowsDatabase rows;
}

final class RowsHeld extends RowsOpening {
  const RowsHeld();
}

final class RowsRefused extends RowsOpening {
  const RowsRefused(this.failure);

  final StorageFailure failure;
}

RowsRefused refusedFor(String why) =>
    RowsRefused(DeviceFailure('the library cannot be opened: $why'));

RowsOpening openingFailed(SqliteException error) => switch (error.resultCode) {
  SqlError.SQLITE_BUSY || SqlError.SQLITE_LOCKED => const RowsHeld(),
  SqlError.SQLITE_NOTADB => refusedFor('not an Icarus library'),
  SqlError.SQLITE_CORRUPT => refusedFor('damaged (${error.message})'),
  _ => RowsRefused(failureOf(error)),
};

sealed class _Connection {
  const _Connection();
}

final class _Usable extends _Connection {
  const _Usable();
}

final class _AfterFailedWrite extends _Connection {
  const _AfterFailedWrite();
}

final class _Unusable extends _Connection {
  const _Unusable(this.failure);

  final StorageFailure failure;
}

final class RowsDatabase {
  RowsDatabase._(
    this._db, {
    required PreparedStatement get,
    required PreparedStatement keysFrom,
    required PreparedStatement keysBetween,
    required PreparedStatement entriesFrom,
    required PreparedStatement entriesBetween,
    required PreparedStatement put,
    required PreparedStatement remove,
    required PreparedStatement supersede,
    required PreparedStatement clearArea,
  }) : _get = get,
       _keysFrom = keysFrom,
       _keysBetween = keysBetween,
       _entriesFrom = entriesFrom,
       _entriesBetween = entriesBetween,
       _put = put,
       _remove = remove,
       _supersede = supersede,
       _clearArea = clearArea;

  static String? _prepareConnection(Database db) {
    db
      ..execute('PRAGMA locking_mode = EXCLUSIVE')
      ..execute('PRAGMA busy_timeout = 0');
    final mode = db.select('PRAGMA journal_mode = WAL').single.columnAt(0);
    if (mode != 'wal') return 'no write-ahead log ($mode)';
    db
      ..execute('PRAGMA synchronous = FULL')
      ..execute('PRAGMA fullfsync = ON')
      ..execute('PRAGMA journal_size_limit = 4194304')
      ..execute('BEGIN IMMEDIATE');
    return null;
  }

  static RowsOpening? create(Database db) {
    try {
      if (_prepareConnection(db) case final problem?) {
        db.close();
        return refusedFor(problem);
      }
      db
        ..execute(
          'CREATE TABLE rows (area TEXT NOT NULL, key TEXT NOT NULL, '
          'value TEXT NOT NULL, PRIMARY KEY (area, key)) STRICT',
        )
        ..execute('CREATE TABLE generation (value INTEGER NOT NULL) STRICT')
        ..execute('INSERT INTO generation VALUES (0)')
        ..execute('PRAGMA user_version = $librarySchemaVersion')
        ..execute('PRAGMA application_id = $libraryApplicationId')
        ..execute('COMMIT')
        ..close();
      return null;
    } on SqliteException catch (error) {
      db.close();
      return openingFailed(error);
    } on FormatException catch (error) {
      db.close();
      return refusedFor('damaged (${_undescribed(error)})');
    }
  }

  static RowsOpening open(Database db) {
    final prepared = <PreparedStatement>[];
    PreparedStatement prepare(String sql) {
      final statement = db.prepare(sql, persistent: true);
      prepared.add(statement);
      return statement;
    }

    try {
      if (_prepareConnection(db) case final problem?) {
        db.close();
        return refusedFor(problem);
      }
      if (_problemIn(db) case final problem?) {
        db
          ..execute('ROLLBACK')
          ..close();
        return refusedFor(problem);
      }
      db.execute('COMMIT');
      return RowsOpened(
        RowsDatabase._(
          db,
          get: prepare('SELECT value FROM rows WHERE area = ?1 AND key = ?2'),
          keysFrom: prepare(
            'SELECT key FROM rows WHERE area = ?1 AND key >= ?2 ORDER BY key',
          ),
          keysBetween: prepare(
            'SELECT key FROM rows WHERE area = ?1 AND key >= ?2 AND key < ?3 '
            'ORDER BY key',
          ),
          entriesFrom: prepare(
            'SELECT key, value FROM rows WHERE area = ?1 AND key >= ?2 '
            'ORDER BY key',
          ),
          entriesBetween: prepare(
            'SELECT key, value FROM rows WHERE area = ?1 AND key >= ?2 '
            'AND key < ?3 ORDER BY key',
          ),
          put: prepare(
            'INSERT INTO rows (area, key, value) VALUES (?1, ?2, ?3) '
            'ON CONFLICT (area, key) DO UPDATE SET value = excluded.value',
          ),
          remove: prepare('DELETE FROM rows WHERE area = ?1 AND key = ?2'),
          supersede: prepare('UPDATE generation SET value = value + 1'),
          clearArea: prepare('DELETE FROM rows WHERE area = ?1'),
        ),
      );
    } on SqliteException catch (error) {
      _discard(db, prepared);
      return openingFailed(error);
    } on FormatException catch (error) {
      _discard(db, prepared);
      return refusedFor('damaged (${_undescribed(error)})');
    }
  }

  static void _discard(Database db, List<PreparedStatement> prepared) {
    for (final statement in prepared) {
      statement.close();
    }
    db.close();
  }

  static String? _problemIn(Database db) {
    final applicationId = db.select('PRAGMA application_id').single.columnAt(0);
    if (applicationId != libraryApplicationId) {
      return 'not an Icarus library (application id $applicationId)';
    }
    switch (db.select('PRAGMA user_version').single.columnAt(0)) {
      case librarySchemaVersion:
        break;
      case final int version when version > librarySchemaVersion:
        return 'written by a newer build (schema version $version)';
      case final version:
        return 'not an Icarus library (schema version $version)';
    }
    final check = [
      for (final row in db.select('PRAGMA integrity_check'))
        '${row.columnAt(0)}',
    ];
    if (check case ['ok']) return null;
    return 'damaged (${check.take(5).join('; ')})';
  }

  final Database _db;
  final PreparedStatement _get;
  final PreparedStatement _keysFrom;
  final PreparedStatement _keysBetween;
  final PreparedStatement _entriesFrom;
  final PreparedStatement _entriesBetween;
  final PreparedStatement _put;
  final PreparedStatement _remove;
  final PreparedStatement _supersede;
  final PreparedStatement _clearArea;
  _Connection _connection = const _Usable();

  Stored<T> _guarded<T>(Stored<T> Function() task) {
    if (_connection case _Unusable(:final failure)) {
      return StorageFailed(failure);
    }
    try {
      return task();
    } on SqliteException catch (error) {
      return StorageFailed(failureOf(error));
    } on FormatException catch (error) {
      return StorageFailed(DeviceFailure(_undescribed(error)));
    }
  }

  static const _notTextFailure = DeviceFailure(
    'the library holds a value that is not text',
  );

  static const _notText = StorageFailed<Never>(_notTextFailure);

  KeyRead read(String area, String key) =>
      pastLimit(area, key, rowsMaxKeyLength)
      ? const KeyMissing()
      : _read(area, key);

  KeyRead _read(String area, String key) => switch (_guarded(
    () => Done(_get.select([area, key]).firstOrNull?.columnAt(0)),
  )) {
    StorageFailed(:final failure) => KeyNotRead(failure),
    Done(value: null) => const KeyMissing(),
    Done(value: final String value) => KeyHeld(value),
    Done() => const KeyNotRead(_notTextFailure),
  };

  Stored<List<String>> keys(String area, String prefix) => _guarded(() {
    final keys = <String>[];
    for (final row in switch (_after(prefix)) {
      null => _keysFrom.select([area, prefix]),
      final upper => _keysBetween.select([area, prefix, upper]),
    }) {
      switch (row.columnAt(0)) {
        case final String key:
          keys.add(key);
        case _:
          return _notText;
      }
    }
    return Done(keys);
  });

  Stored<List<StoredEntry>> entries(String area, String prefix) => _guarded(() {
    final found = <StoredEntry>[];
    for (final row in switch (_after(prefix)) {
      null => _entriesFrom.select([area, prefix]),
      final upper => _entriesBetween.select([area, prefix, upper]),
    }) {
      switch ((row.columnAt(0), row.columnAt(1))) {
        case (final String key, final String value):
          found.add((key: key, value: value));
        case _:
          return _notText;
      }
    }
    return Done(found);
  });

  static String? _after(String prefix) {
    final points = prefix.runes.toList();
    while (points.isNotEmpty) {
      final last = points.removeLast();
      if (last < 0x10FFFF) {
        return String.fromCharCodes([
          ...points,
          last == 0xD7FF ? 0xE000 : last + 1,
        ]);
      }
    }
    return null;
  }

  Committing commit(List<Change> changes) {
    if (_connection case _Unusable(:final failure)) {
      return CommitRefused(failure);
    }
    if (refusedName(changes, rowsMaxKeyLength) case final failure?) {
      return CommitRefused(failure);
    }
    var committing = false;
    try {
      _db.execute('BEGIN IMMEDIATE');
      for (final change in changes) {
        switch (change) {
          case Put(:final area, :final key, :final value):
            _put.execute([area, key, value]);
          case Delete(:final area, :final key):
            _remove.execute([area, key]);
          case ClearArea(:final area):
            _clearArea.execute([area]);
        }
      }
      if (_connection is _AfterFailedWrite) _supersede.execute();
      committing = true;
      _db.execute('COMMIT');
      _connection = const _Usable();
      return const CommitApplied();
    } on SqliteException catch (error) {
      return _failedCommit(failureOf(error), committing: committing);
    } on FormatException catch (error) {
      return _failedCommit(
        DeviceFailure(_undescribed(error)),
        committing: committing,
      );
    }
  }

  Committing _failedCommit(StorageFailure failure, {required bool committing}) {
    if (committing) _connection = const _AfterFailedWrite();
    if (!_db.autocommit) _rollBack(failure);
    return committing ? CommitUnknown(failure) : CommitRefused(failure);
  }

  void _rollBack(StorageFailure cause) {
    try {
      _db.execute('ROLLBACK');
    } on SqliteException catch (error) {
      _connection = _Unusable(
        DeviceFailure('$cause, and the rollback failed: ${failureOf(error)}'),
      );
    } on FormatException catch (error) {
      _connection = _Unusable(
        DeviceFailure(
          '$cause, and the rollback failed: ${_undescribed(error)}',
        ),
      );
    }
  }

  void close() {
    _connection = const _Unusable(LeaseEnded());
    for (final statement in [
      _get,
      _keysFrom,
      _keysBetween,
      _entriesFrom,
      _entriesBetween,
      _put,
      _remove,
      _supersede,
      _clearArea,
    ]) {
      statement.close();
    }
    _db.close();
  }
}
