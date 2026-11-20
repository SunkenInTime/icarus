import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../store/engine.dart';
import 'rows_database.dart';

abstract interface class LibraryFiles {
  bool exists(String path);

  void delete(String path);

  void rename(String from, String to);

  Database open(String path, {required bool create});
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
}

RowsOpening openLibraryFile(String path, LibraryFiles files) {
  try {
    if (!files.exists(path)) {
      if (files.exists('$path-wal')) {
        return refusedFor('the file is gone and its log is still there');
      }
      if (_create(path, files) case final RowsOpening refused) return refused;
    }
    return RowsDatabase.open(files.open(path, create: false), fresh: false);
  } on FileSystemException catch (error) {
    return RowsRefused(DeviceFailure('$error'));
  } on SqliteException catch (error) {
    return openingFailed(error);
  }
}

RowsOpening? _create(String path, LibraryFiles files) {
  final creating = '$path.creating';
  for (final leftover in [creating, '$creating-wal', '$creating-journal']) {
    if (files.exists(leftover)) files.delete(leftover);
  }
  switch (RowsDatabase.open(files.open(creating, create: true), fresh: true)) {
    case RowsOpened(:final rows):
      rows.close();
    case final refused:
      return refused;
  }
  files.rename(creating, path);
  return null;
}
