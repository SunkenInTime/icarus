import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import '../store/engine.dart';
import 'rows_database.dart';

abstract interface class LibraryFiles {
  bool exists(String path);

  void delete(String path);

  void rename(String from, String to);

  Database open(String path, {required bool create});

  void pause(Duration duration);
}

final class DiskLibraryFiles implements LibraryFiles {
  const DiskLibraryFiles();

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  void delete(String path) => File(path).deleteSync();

  @override
  void rename(String from, String to) => File(from).renameSync(to);

  @override
  Database open(String path, {required bool create}) => sqlite3.open(
    path,
    mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite,
  );

  @override
  void pause(Duration duration) => sleep(duration);
}

const _patience = Duration(milliseconds: 250);

RowsOpening openLibraryFile(String path, LibraryFiles files) {
  final waited = Stopwatch()..start();
  final random = Random();
  while (true) {
    final opening = _openOnce(path, files);
    if (opening is! RowsHeld || waited.elapsed >= _patience) return opening;
    files.pause(Duration(milliseconds: 2 + random.nextInt(20)));
  }
}

RowsOpening _openOnce(String path, LibraryFiles files) {
  try {
    if (!files.exists(path)) {
      if (files.exists('$path-wal')) {
        return refusedFor('the file is gone and its log is still there');
      }
      if (_create(path, files) case _NotMade(:final refusal)) return refusal;
    }
    return RowsDatabase.open(files.open(path, create: false));
  } on FileSystemException catch (error) {
    return RowsRefused(DeviceFailure('$error'));
  } on SqliteException catch (error) {
    return openingFailed(error);
  }
}

sealed class _Making {
  const _Making();
}

final class _InPlace extends _Making {
  const _InPlace();
}

final class _NotMade extends _Making {
  const _NotMade(this.refusal);

  final RowsOpening refusal;
}

_Making _create(String path, LibraryFiles files) {
  final lock = files.open('$path.lock', create: true);
  try {
    lock
      ..execute('PRAGMA locking_mode = EXCLUSIVE')
      ..execute('BEGIN EXCLUSIVE');
  } on SqliteException catch (error) {
    lock.close();
    return _NotMade(openingFailed(error));
  }
  try {
    if (files.exists(path)) return const _InPlace();
    final creating = '$path.creating';
    for (final leftover in [creating, '$creating-wal', '$creating-journal']) {
      if (files.exists(leftover)) files.delete(leftover);
    }
    switch (RowsDatabase.create(files.open(creating, create: true))) {
      case NotCreated(:final failure):
        return _NotMade(RowsRefused(failure));
      case Created():
        break;
    }
    switch (RowsDatabase.verifyCreated(files.open(creating, create: false))) {
      case NotCreated(:final failure):
        return _NotMade(RowsRefused(failure));
      case Created():
        files.rename(creating, path);
        return const _InPlace();
    }
  } finally {
    lock.close();
  }
}
