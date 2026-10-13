import 'dart:io';
import 'dart:typed_data';

import 'package:icarus/replay/recycle_bin.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where replay files come from.
enum ReplaySource {
  /// Valorant's own download folder. Valorant may clear it.
  valorant,

  /// Icarus's replays folder: files the user brought in from elsewhere.
  icarus,
}

/// Why [ReplayFiles.remove] deleted nothing.
enum ReplayRemoveRefusal {
  /// The file isn't in Icarus's own replays folder, or that folder leads
  /// into Valorant's folder or the cache.
  outsideIcarus,

  /// The file on disk isn't the one the user chose to remove.
  fileChanged,

  /// Valorant's folder gained or lost this match since the user was told
  /// what removing would leave behind.
  valorantCopyChanged,
}

class ReplayRemoveRefused implements Exception {
  const ReplayRemoveRefused(this.reason, {this.current});

  final ReplayRemoveRefusal reason;

  /// The file as it is now, for [ReplayRemoveRefusal.valorantCopyChanged].
  final ReplayFile? current;

  @override
  String toString() => 'ReplayRemoveRefused(${reason.name})';
}

/// One `.vrf` on disk.
class ReplayFile {
  const ReplayFile({
    required this.path,
    required this.source,
    required this.sizeBytes,
    required this.modified,
    this.valorantHasCopy = false,
  });

  final String path;
  final ReplaySource source;
  final int sizeBytes;
  final DateTime modified;

  /// For a replay kept in Icarus: Valorant's folder has the match too.
  final bool valorantHasCopy;

  /// Valorant names replays after their match id. Lower-cased: Windows
  /// paths don't care about case, so neither does the match id.
  String get matchId => p.basenameWithoutExtension(path).toLowerCase();

  /// Identifies this exact file for caching. Valorant never rewrites a
  /// replay; one re-downloaded or replaced gets a new size or time, and so a
  /// new key.
  String get cacheKey =>
      '$matchId-$sizeBytes-${modified.millisecondsSinceEpoch}';
}

/// Finds replay files and keeps the decoded cache. Nothing here touches the
/// library: replays are files, and a decoded replay is a cache rebuilt from
/// its file.
class ReplayFiles {
  ReplayFiles({
    Future<Directory> Function()? supportDirectory,
    String? valorantDemosPath,
    Future<void> Function(String path)? recycle,
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _valorantDemosPath = valorantDemosPath ?? defaultValorantDemosPath(),
        _recycle = recycle ?? moveToRecycleBin;

  final Future<Directory> Function() _supportDirectory;
  final String? _valorantDemosPath;

  /// Moves a file to the Recycle Bin, or throws [RecycleBinUnavailable].
  final Future<void> Function(String path) _recycle;

  static const extension = '.vrf';

  /// `%LOCALAPPDATA%\VALORANT\Saved\Demos` on Windows; Valorant has no other
  /// desktop platform.
  static String? defaultValorantDemosPath() {
    if (!Platform.isWindows) return null;
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null) return null;
    return p.join(localAppData, 'VALORANT', 'Saved', 'Demos');
  }

  /// Accounts that have played Valorant on this machine. Valorant keeps a
  /// `<subject>-<region>` config folder per account; a replay is seen from
  /// the team of whichever of these played in it.
  Future<Set<String>> localSubjects() async {
    final demos = _valorantDemosPath;
    if (demos == null) return const {};
    final config = Directory(p.join(p.dirname(demos), 'Config'));
    if (!await config.exists()) return const {};
    final subject = RegExp(
      r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})-',
      caseSensitive: false,
    );
    final subjects = <String>{};
    await for (final entity in config.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final match = subject.firstMatch(p.basename(entity.path));
      if (match != null) subjects.add(match.group(1)!.toLowerCase());
    }
    return subjects;
  }

  Future<Directory> icarusReplaysDirectory() async => Directory(
        p.join((await _supportDirectory()).path, 'replays'),
      ).create(recursive: true);

  Future<Directory> _cacheDirectory() async => Directory(
        p.join((await _supportDirectory()).path, 'replay_cache'),
      ).create(recursive: true);

  /// Every replay in both folders, newest first. A match present in both is
  /// listed once, from Icarus's folder, which Valorant will not clear. A
  /// folder that can't be read lists nothing; the other still does.
  Future<List<ReplayFile>> list() async {
    final byMatch = <String, ReplayFile>{};
    final valorant = _valorantDemosPath;
    if (valorant != null) {
      for (final file in await _scan(Directory(valorant))) {
        byMatch[file.matchId] = ReplayFile(
          path: file.path,
          source: ReplaySource.valorant,
          sizeBytes: file.sizeBytes,
          modified: file.modified,
        );
      }
    }
    final Directory kept;
    try {
      kept = await icarusReplaysDirectory();
    } on FileSystemException {
      return _newestFirst(byMatch.values);
    }
    for (final file in await _scan(kept)) {
      byMatch[file.matchId] = byMatch.containsKey(file.matchId)
          ? ReplayFile(
              path: file.path,
              source: ReplaySource.icarus,
              sizeBytes: file.sizeBytes,
              modified: file.modified,
              valorantHasCopy: true,
            )
          : file;
    }
    return _newestFirst(byMatch.values);
  }

  static List<ReplayFile> _newestFirst(Iterable<ReplayFile> files) =>
      files.toList()..sort((a, b) => b.modified.compareTo(a.modified));

  Future<List<ReplayFile>> _scan(Directory directory) async {
    try {
      return await _scanOrThrow(directory);
    } on FileSystemException {
      return const [];
    }
  }

  Future<List<ReplayFile>> _scanOrThrow(Directory directory) async {
    if (!await directory.exists()) return const [];
    final files = <ReplayFile>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (p.extension(entity.path).toLowerCase() != extension) continue;
      final stat = await entity.stat();
      files.add(
        ReplayFile(
          path: entity.path,
          source: ReplaySource.icarus,
          sizeBytes: stat.size,
          modified: stat.modified,
        ),
      );
    }
    return files;
  }

  /// Copies a replay into Icarus's folder, named after its match, and
  /// returns the copy. [matchId] is the one the replay's header names, when
  /// the caller read it; otherwise the file's own name stands for it, as it
  /// does in Valorant's folder. The same file already there is returned as
  /// is; a different one of the same name (a partial download) is replaced.
  /// A same-size file counts as the same unless [replace] says the caller
  /// knows the one there isn't this replay.
  Future<ReplayFile> import(
    String sourcePath, {
    String? matchId,
    bool replace = false,
  }) async {
    final directory = await icarusReplaysDirectory();
    // A header is file content, so only a plain id becomes a file name.
    final named =
        matchId != null && RegExp(r'^[0-9A-Za-z-]+$').hasMatch(matchId);
    final name = named ? '$matchId$extension' : p.basename(sourcePath);
    final destination = File(p.join(directory.path, name));
    final source = File(sourcePath);
    final alreadyKept = !replace &&
        await destination.exists() &&
        await destination.length() == await source.length();
    if (!p.equals(destination.path, sourcePath) && !alreadyKept) {
      // Copy to a temporary name first so a half-copied file is never
      // listed as a replay.
      final partial = _partial(destination);
      try {
        await source.copy(partial.path);
        // Replaces a kept copy in one step, so a failure leaves it intact.
        await partial.rename(destination.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
    final stat = await destination.stat();
    return ReplayFile(
      path: destination.path,
      source: ReplaySource.icarus,
      sizeBytes: stat.size,
      modified: stat.modified,
    );
  }

  /// Moves a replay kept in Icarus's folder to the Recycle Bin and deletes
  /// its decoded cache, and nothing else: Valorant's folder is Valorant's to
  /// clear. The replay is never deleted outright; when it can't go to the
  /// Recycle Bin this throws [RecycleBinUnavailable] and leaves it, and its
  /// cache, where they are.
  ///
  /// [file] is the replay as the user saw it when they chose Remove. Throws
  /// [ReplayRemoveRefused], touching nothing, when the file there now isn't
  /// that one, or when Valorant's folder no longer matches
  /// [ReplayFile.valorantHasCopy], which told them what would be left.
  Future<void> remove(ReplayFile file) async {
    if (file.source != ReplaySource.icarus ||
        !await _isDirectlyInKeptFolder(file.path)) {
      throw const ReplayRemoveRefused(ReplayRemoveRefusal.outsideIcarus);
    }
    final replay = File(file.path);
    final FileStat stat = await replay.stat();
    final valorantCopy = await _valorantCopy(file);
    final current = ReplayFile(
      path: file.path,
      source: ReplaySource.icarus,
      sizeBytes: stat.size,
      modified: stat.modified,
      valorantHasCopy: valorantCopy != null,
    );
    if (stat.type == FileSystemEntityType.notFound ||
        current.cacheKey != file.cacheKey) {
      throw const ReplayRemoveRefused(ReplayRemoveRefusal.fileChanged);
    }
    if (current.valorantHasCopy != file.valorantHasCopy) {
      throw ReplayRemoveRefused(
        ReplayRemoveRefusal.valorantCopyChanged,
        current: current,
      );
    }
    try {
      await _recycle(file.path);
    } on RecycleBinUnavailable catch (error) {
      // Say what happened, not what was meant to: the file is either still
      // there or Windows deleted it anyway. The cache stays either way.
      final gone = await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound;
      throw RecycleBinUnavailable(
        file.path,
        hresult: error.hresult,
        deleted: gone,
      );
    }
    // A copy Keep made is the same file as Valorant's, down to its time, so
    // the two share one cache. Valorant's still needs it.
    if (valorantCopy?.cacheKey == file.cacheKey) return;
    final cache = await _cacheDirectory();
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is File && _isCacheOf(file, p.basename(entity.path))) {
        await entity.delete();
      }
    }
  }

  /// Whether [path] sits right inside Icarus's replays folder, judged where
  /// the folders really are: a folder that is a link or junction into
  /// Valorant's folder or the cache doesn't count as Icarus's.
  Future<bool> _isDirectlyInKeptFolder(String path) async {
    final kept = await (await icarusReplaysDirectory()).resolveSymbolicLinks();
    final cache = await (await _cacheDirectory()).resolveSymbolicLinks();
    final parent = await Directory(p.dirname(path)).resolveSymbolicLinks();
    bool overlap(String a, String b) =>
        p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
    if (!p.equals(parent, kept) || overlap(kept, cache)) return false;
    final demos = _valorantDemosPath;
    if (demos != null && await Directory(demos).exists()) {
      final valorant = await Directory(demos).resolveSymbolicLinks();
      if (overlap(kept, valorant) || overlap(cache, valorant)) return false;
    }
    return true;
  }

  /// Valorant's file of the same match as [file], if its folder has one.
  Future<ReplayFile?> _valorantCopy(ReplayFile file) async {
    final demos = _valorantDemosPath;
    if (demos == null) return null;
    final original = File(p.join(demos, p.basename(file.path)));
    // Judged as the listing judges it: a link there, even one back to the
    // file being removed, isn't a copy.
    final type = await FileSystemEntity.type(original.path, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final stat = await original.stat();
    return ReplayFile(
      path: original.path,
      source: ReplaySource.valorant,
      sizeBytes: stat.size,
      modified: stat.modified,
    );
  }

  /// Whether [name] is a decoded cache of [file] under any decoder version.
  /// Cache names are `<match id>-<size>-<time>-<decoder version>.icrp`; the
  /// key is matched whole, so `a.vrf`'s cache never claims the cache of a
  /// replay whose name only starts with `a`'s key.
  static bool _isCacheOf(ReplayFile file, String name) {
    final match = RegExp(r'^(.+)-([^-]+)\.icrp$').firstMatch(name);
    return match != null && match.group(1) == file.cacheKey;
  }

  /// A temporary name beside [target], unique to this write, so two writes
  /// of the same file never share one. Never listed: it isn't a `.vrf`.
  static File _partial(File target) => File(
        '${target.path}.${DateTime.now().microsecondsSinceEpoch}.partial',
      );

  Future<File> _cacheFile(ReplayFile file, String decoderVersion) async => File(
        p.join(
          (await _cacheDirectory()).path,
          '${file.cacheKey}-$decoderVersion.icrp',
        ),
      );

  Future<Uint8List?> readCache(ReplayFile file, String decoderVersion) async {
    final cache = await _cacheFile(file, decoderVersion);
    if (!await cache.exists()) return null;
    return cache.readAsBytes();
  }

  /// Writes the decoded buffer, then drops older caches of the same match.
  Future<void> writeCache(
    ReplayFile file,
    String decoderVersion,
    Uint8List bytes,
  ) async {
    final cache = await _cacheFile(file, decoderVersion);
    final partial = _partial(cache);
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(cache.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
    await for (final entity in cache.parent.list()) {
      final name = p.basename(entity.path);
      if (entity is File &&
          name.startsWith('${file.matchId}-') &&
          name.endsWith('.icrp') &&
          !p.equals(entity.path, cache.path)) {
        await entity.delete();
      }
    }
  }
}
