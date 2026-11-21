import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../store/engine.dart';
import 'rows_database.dart';

abstract interface class LibraryFiles {
  int? size(String path);

  Uint8List head(String path, int length);

  Database open(String path);

  void pause(Duration duration);

  bool isMomentary(FileSystemException error);
}

const _windowsMomentary = {5, 32, 303};

final class DiskLibraryFiles implements LibraryFiles {
  const DiskLibraryFiles();

  @override
  int? size(String path) {
    try {
      return File(path).lengthSync();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Uint8List head(String path, int length) {
    final RandomAccessFile file;
    try {
      file = File(path).openSync();
    } on PathNotFoundException {
      return Uint8List(0);
    }
    try {
      return file.readSync(length);
    } finally {
      file.closeSync();
    }
  }

  @override
  Database open(String path) =>
      sqlite3.open(path, mode: OpenMode.readWriteCreate);

  @override
  void pause(Duration duration) => sleep(duration);

  @override
  bool isMomentary(FileSystemException error) =>
      Platform.isWindows &&
      _windowsMomentary.contains(error.osError?.errorCode);
}

const _patience = Duration(milliseconds: 250);

sealed class _Attempt {
  const _Attempt(this.opening);

  final RowsOpening opening;
}

final class _Settled extends _Attempt {
  const _Settled(super.opening);
}

final class _TryAgain extends _Attempt {
  const _TryAgain(super.opening);
}

RowsOpening openLibraryFile(
  String path,
  LibraryFiles files, {
  Duration Function()? elapsed,
}) {
  final waited = Stopwatch()..start();
  final now = elapsed ?? () => waited.elapsed;
  final random = Random();
  var seenHeld = false;
  while (true) {
    switch (_openOnce(path, files)) {
      case _Settled(:final opening):
        return seenHeld && opening is RowsRefused ? const RowsHeld() : opening;
      case _TryAgain(:final opening):
        seenHeld = seenHeld || opening is RowsHeld;
        final pause = Duration(milliseconds: 2 + random.nextInt(20));
        if (now() + pause >= _patience) {
          return seenHeld ? const RowsHeld() : opening;
        }
        files.pause(pause);
    }
  }
}

const _journalMagic = [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7];

bool _restoresPages(Uint8List header) =>
    header.length >= 20 &&
    [for (var i = 0; i < 8; i++) header[i]].join(',') ==
        _journalMagic.join(',') &&
    ByteData.sublistView(header).getUint32(16) > 0;

String? _strandedCompanion(String path, LibraryFiles files) {
  final log = '$path-wal';
  if ((files.size(log) ?? 0) > 0) return log;
  final journal = '$path-journal';
  if ((files.size(journal) ?? 0) > 0 &&
      _restoresPages(files.head(journal, 20))) {
    return journal;
  }
  return null;
}

_Attempt _unreadable(FileSystemException error, LibraryFiles files) {
  final refused = RowsRefused(
    DeviceFailure('the library files could not be read: $error'),
  );
  return files.isMomentary(error) ? _TryAgain(refused) : _Settled(refused);
}

_Attempt _openOnce(String path, LibraryFiles files) {
  final String? companion;
  final int? librarySize;
  try {
    companion = _strandedCompanion(path, files);
    librarySize = files.size(path);
  } on FileSystemException catch (error) {
    return _unreadable(error, files);
  }
  if (companion != null && (librarySize ?? 0) == 0) {
    return _TryAgain(RowsRefused(LibraryFileGone(companion)));
  }
  try {
    return switch (RowsDatabase.open(
      files.open(path),
      fileSize: () => files.size(path) ?? 0,
    )) {
      final RowsHeld held => _TryAgain(held),
      final opening => _Settled(opening),
    };
  } on SqliteException catch (error) {
    return switch (openingFailed(error)) {
      final RowsHeld held => _TryAgain(held),
      final opening => _Settled(opening),
    };
  } on FileSystemException catch (error) {
    return _unreadable(error, files);
  }
}
