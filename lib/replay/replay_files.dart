import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where replay files come from.
enum ReplaySource {
  /// Valorant's own download folder. Valorant may clear it.
  valorant,

  /// Icarus's replays folder: files the user brought in from elsewhere.
  icarus,
}

/// One `.vrf` on disk.
class ReplayFile {
  const ReplayFile({
    required this.path,
    required this.source,
    required this.sizeBytes,
    required this.modified,
  });

  final String path;
  final ReplaySource source;
  final int sizeBytes;
  final DateTime modified;

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
  })  : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
        _valorantDemosPath = valorantDemosPath ?? defaultValorantDemosPath();

  final Future<Directory> Function() _supportDirectory;
  final String? _valorantDemosPath;

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
      byMatch[file.matchId] = file;
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

  /// Copies a replay into Icarus's folder, keeping its match-id name, and
  /// returns the copy. The same file already there is returned as is; a
  /// different one of the same name (a partial download) is replaced.
  Future<ReplayFile> import(String sourcePath) async {
    final directory = await icarusReplaysDirectory();
    final destination = File(p.join(directory.path, p.basename(sourcePath)));
    final source = File(sourcePath);
    final alreadyKept = await destination.exists() &&
        await destination.length() == await source.length();
    if (!p.equals(destination.path, sourcePath) && !alreadyKept) {
      // Copy to a temporary name first so a half-copied file is never
      // listed as a replay.
      final partial = _partial(destination);
      try {
        await source.copy(partial.path);
        if (await destination.exists()) await destination.delete();
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
