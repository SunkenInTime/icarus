import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:icarus_library/src/sqlite/library_file.dart';
import 'package:sqlite3/sqlite3.dart';

const _sector = 512;

const _powersafeOverwrite = 0x00001000;

const _syncsDirectoryWhenCreated = 0x00000800 | 0x00004000 | 0x00080000;

sealed class Fault {
  const Fault();
}

final class NoFault extends Fault {
  const NoFault();
}

final class CrashAt extends Fault {
  const CrashAt(this.step);

  final int step;
}

final class FailSyncAt extends Fault {
  const FailSyncAt(this.sync);

  final int sync;
}

final class FullAfter extends Fault {
  const FullAfter(this.bytes);

  final int bytes;
}

final class FailRename extends Fault {
  const FailRename();
}

sealed class PowerLoss {
  const PowerLoss();
}

final class KeepsUnsynced extends PowerLoss {
  const KeepsUnsynced();
}

final class DropsUnsynced extends PowerLoss {
  const DropsUnsynced();
}

final class TearsUnsynced extends PowerLoss {
  const TearsUnsynced(this.seed);

  final int seed;
}

sealed class _Change {
  const _Change();
}

final class _Wrote extends _Change {
  const _Wrote(this.offset, this.bytes);

  final int offset;
  final Uint8List bytes;
}

final class _Truncated extends _Change {
  const _Truncated(this.size);

  final int size;
}

sealed class _DirectoryChange {
  const _DirectoryChange();
}

final class _Created extends _DirectoryChange {
  const _Created(this.path, this.file);

  final String path;
  final _DiskFile file;
}

final class _Deleted extends _DirectoryChange {
  const _Deleted(this.path);

  final String path;
}

final class _Renamed extends _DirectoryChange {
  const _Renamed(this.from, this.to);

  final String from;
  final String to;
}

final class _DiskFile {
  _DiskFile(this.durable) : visible = Uint8List.fromList(durable ?? const []);

  Uint8List? durable;
  Uint8List visible;
  final unsynced = <_Change>[];

  void write(int offset, Uint8List bytes) {
    final end = offset + bytes.length;
    if (end > visible.length) {
      visible = Uint8List(end)..setRange(0, visible.length, visible);
    }
    visible.setRange(offset, end, bytes);
    unsynced.add(_Wrote(offset, Uint8List.fromList(bytes)));
  }

  void truncate(int size) {
    visible = Uint8List(size)..setRange(0, min(size, visible.length), visible);
    unsynced.add(_Truncated(size));
  }

  void sync() {
    durable = Uint8List.fromList(visible);
    unsynced.clear();
  }

  Uint8List afterPowerLoss(bool Function() keep) {
    var bytes = Uint8List.fromList(durable ?? const []);
    for (final change in unsynced) {
      switch (change) {
        case _Truncated(:final size):
          if (keep()) {
            bytes = Uint8List(size)
              ..setRange(0, min(size, bytes.length), bytes);
          }
        case _Wrote(:final offset, bytes: final written):
          for (var start = 0; start < written.length; start += _sector) {
            if (!keep()) continue;
            final end = min(start + _sector, written.length);
            if (offset + end > bytes.length) {
              bytes = Uint8List(offset + end)..setRange(0, bytes.length, bytes);
            }
            bytes.setRange(offset + start, offset + end, written, start);
          }
      }
    }
    return bytes;
  }
}

final class FaultDisk {
  var _files = <String, _DiskFile>{};
  var _durableNames = <String, _DiskFile>{};
  final _directoryChanges = <_DirectoryChange>[];
  final _locks = <String, Map<Object, int>>{};
  Fault fault = const NoFault();
  int steps = 0;
  int syncs = 0;
  bool crashed = false;

  int get usedBytes =>
      _files.values.fold(0, (total, file) => total + file.visible.length);

  bool exists(String path) => _files.containsKey(path);

  Uint8List bytesOf(String path) => Uint8List.fromList(_files[path]!.visible);

  void replace(String path, Uint8List bytes) {
    final file = _DiskFile(Uint8List.fromList(bytes));
    _files[path] = file;
    _durableNames[path] = file;
  }

  void _step() {
    if (crashed) throw const VfsException(SqlError.SQLITE_IOERR);
    steps++;
    if (fault case CrashAt(:final step) when steps >= step) {
      crashed = true;
      throw const VfsException(SqlError.SQLITE_IOERR);
    }
  }

  void _syncDirectory() {
    _durableNames = Map.of(_files);
    _directoryChanges.clear();
  }

  void _create(String path) {
    final file = _DiskFile(null);
    _files[path] = file;
    _directoryChanges.add(_Created(path, file));
  }

  void _delete(String path, {required bool syncDirectory}) {
    _files.remove(path);
    _directoryChanges.add(_Deleted(path));
    if (syncDirectory) _syncDirectory();
  }

  void _rename(String from, String to) {
    if (crashed) throw FileSystemException('the app stopped', from);
    steps++;
    if (fault case CrashAt(:final step) when steps >= step) {
      crashed = true;
      throw FileSystemException('the app stopped', from);
    }
    if (fault is FailRename) {
      throw FileSystemException('the rename failed', from);
    }
    final file = _files.remove(from);
    if (file == null) throw FileSystemException('no such file', from);
    _files[to] = file;
    _directoryChanges.add(_Renamed(from, to));
  }

  void powerLoss(PowerLoss loss) {
    final random = switch (loss) {
      TearsUnsynced(:final seed) => Random(seed),
      KeepsUnsynced() || DropsUnsynced() => null,
    };
    bool keep() => switch (loss) {
      KeepsUnsynced() => true,
      DropsUnsynced() => false,
      TearsUnsynced() => random!.nextBool(),
    };
    final names = Map.of(_durableNames);
    final applied = switch (loss) {
      KeepsUnsynced() => _directoryChanges.length,
      DropsUnsynced() => 0,
      TearsUnsynced() => random!.nextInt(_directoryChanges.length + 1),
    };
    for (final change in _directoryChanges.take(applied)) {
      switch (change) {
        case _Created(:final path, :final file):
          names[path] = file;
        case _Deleted(:final path):
          names.remove(path);
        case _Renamed(:final from, :final to):
          if (names.remove(from) case final file?) names[to] = file;
      }
    }
    _files = {
      for (final MapEntry(key: path, value: file) in names.entries)
        path: _DiskFile(switch (loss) {
          KeepsUnsynced() => Uint8List.fromList(file.visible),
          DropsUnsynced() || TearsUnsynced() => file.afterPowerLoss(keep),
        }),
    };
    _syncDirectory();
    _locks.clear();
    fault = const NoFault();
    crashed = false;
  }

  int _othersHighest(String path, Object holder) => [
    for (final MapEntry(:key, :value) in (_locks[path] ?? const {}).entries)
      if (!identical(key, holder)) value,
  ].fold(SqlFileLockingLevels.SQLITE_LOCK_NONE, max);

  void _lock(String path, Object holder, int level) {
    final others = _othersHighest(path, holder);
    final blocked = switch (level) {
      SqlFileLockingLevels.SQLITE_LOCK_SHARED =>
        others >= SqlFileLockingLevels.SQLITE_LOCK_PENDING,
      SqlFileLockingLevels.SQLITE_LOCK_RESERVED ||
      SqlFileLockingLevels.SQLITE_LOCK_PENDING =>
        others >= SqlFileLockingLevels.SQLITE_LOCK_RESERVED,
      _ => others >= SqlFileLockingLevels.SQLITE_LOCK_SHARED,
    };
    if (blocked) throw const VfsException(SqlError.SQLITE_BUSY);
    (_locks[path] ??= {})[holder] = level;
  }

  void _unlock(String path, Object holder, int level) {
    if (level == SqlFileLockingLevels.SQLITE_LOCK_NONE) {
      _locks[path]?.remove(holder);
    } else {
      (_locks[path] ??= {})[holder] = level;
    }
  }
}

final class FaultVfs extends BaseVirtualFileSystem {
  FaultVfs(this.disk, {required super.name});

  final FaultDisk disk;

  @override
  int xAccess(String path, int flags) => disk.exists(path) ? 1 : 0;

  @override
  void xDelete(String path, int syncDir) {
    disk._step();
    disk._delete(path, syncDirectory: syncDir != 0);
  }

  @override
  String xFullPathName(String path) => path;

  @override
  XOpenResult xOpen(Sqlite3Filename path, int flags) {
    final name = path.path ?? '/temp-${random.nextInt(1 << 32)}';
    final creates = !disk.exists(name);
    if (creates) {
      if (flags & SqlFlag.SQLITE_OPEN_CREATE == 0) {
        throw const VfsException(SqlError.SQLITE_CANTOPEN);
      }
      disk._create(name);
    }
    return (
      outFlags: 0,
      file: _FaultFile(
        disk,
        name,
        deleteOnClose: flags & SqlFlag.SQLITE_OPEN_DELETEONCLOSE != 0,
        syncsDirectory: creates && flags & _syncsDirectoryWhenCreated != 0,
      ),
    );
  }

  @override
  void xSleep(Duration duration) {}
}

final class _FaultFile extends BaseVfsFile {
  _FaultFile(
    this.disk,
    this.path, {
    required this.deleteOnClose,
    required this.syncsDirectory,
  });

  final FaultDisk disk;
  final String path;
  final bool deleteOnClose;
  bool syncsDirectory;
  _DiskFile get _file =>
      disk._files[path] ?? (throw const VfsException(SqlError.SQLITE_IOERR));

  @override
  int get xDeviceCharacteristics => _powersafeOverwrite;

  @override
  int readInto(Uint8List buffer, int offset) {
    final bytes = _file.visible;
    if (offset >= bytes.length) return 0;
    final available = min(buffer.length, bytes.length - offset);
    buffer.setRange(0, available, bytes, offset);
    return available;
  }

  @override
  void xWrite(Uint8List buffer, int fileOffset) {
    disk._step();
    if (disk.fault case FullAfter(:final bytes)) {
      final grows = max(0, fileOffset + buffer.length - _file.visible.length);
      if (disk.usedBytes + grows > bytes) {
        throw const VfsException(SqlError.SQLITE_FULL);
      }
    }
    _file.write(fileOffset, buffer);
  }

  @override
  void xTruncate(int size) {
    disk._step();
    _file.truncate(size);
  }

  @override
  void xSync(int flags) {
    disk._step();
    disk.syncs++;
    if (disk.fault case FailSyncAt(:final sync) when disk.syncs == sync) {
      _file.unsynced.clear();
      throw const VfsException(SqlExtendedError.SQLITE_IOERR_FSYNC);
    }
    _file.sync();
    if (syncsDirectory) {
      disk._syncDirectory();
      syncsDirectory = false;
    }
  }

  @override
  int xFileSize() => _file.visible.length;

  @override
  void xLock(int mode) => disk._lock(path, this, mode);

  @override
  void xUnlock(int mode) => disk._unlock(path, this, mode);

  @override
  int xCheckReservedLock() =>
      disk._othersHighest(path, this) >=
          SqlFileLockingLevels.SQLITE_LOCK_RESERVED
      ? 1
      : 0;

  @override
  void xClose() {
    disk._unlock(path, this, SqlFileLockingLevels.SQLITE_LOCK_NONE);
    if (deleteOnClose && disk.exists(path)) {
      disk._delete(path, syncDirectory: false);
    }
  }
}

final class FaultLibraryFiles implements LibraryFiles {
  const FaultLibraryFiles(this.disk, this.vfs);

  final FaultDisk disk;
  final FaultVfs vfs;

  @override
  bool exists(String path) => disk.exists(path);

  @override
  void delete(String path) {
    if (disk.crashed) throw FileSystemException('the app stopped', path);
    disk._delete(path, syncDirectory: false);
  }

  @override
  void rename(String from, String to) => disk._rename(from, to);

  @override
  void pause(Duration duration) {}

  @override
  Database open(String path, {required bool create}) => sqlite3.open(
    path,
    vfs: vfs.name,
    mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite,
  );
}
