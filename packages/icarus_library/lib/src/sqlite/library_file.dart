import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'rows_database.dart';

abstract interface class LibraryFiles {
  bool exists(String path);

  Database open(String path);

  void pause(Duration duration);
}

final class DiskLibraryFiles implements LibraryFiles {
  const DiskLibraryFiles();

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  Database open(String path) =>
      sqlite3.open(path, mode: OpenMode.readWriteCreate);

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
  final companions = [
    for (final companion in ['$path-wal', '$path-journal'])
      if (files.exists(companion)) companion,
  ];
  if (companions.isNotEmpty && !files.exists(path)) {
    return refusedFor(
      'the file is gone and ${companions.first} is still there',
    );
  }
  try {
    return RowsDatabase.open(files.open(path));
  } on SqliteException catch (error) {
    return openingFailed(error);
  }
}
