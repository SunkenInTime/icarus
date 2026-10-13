import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:path/path.dart' as p;

final replayFilesProvider = Provider<ReplayFiles>((ref) => ReplayFiles());

/// Reads a replay's header. Tests swap it for one that needs no native
/// decoder.
final replayProbeProvider =
    Provider<Future<ReplayProbe> Function(String path)>((ref) => probeReplay);

/// One replay in the Replays tab: its file and what its header says.
class ReplayListing {
  const ReplayListing({required this.file, this.probe, this.error});

  final ReplayFile file;
  final ReplayProbe? probe;

  /// Why the header could not be read; the file is still listed.
  final ReplayDecodeException? error;

  bool get canOpen => probe != null && probe!.supported;

  /// When the match was played, or the file's time when the header can't
  /// say. The tile shows this date and the tab sorts by it.
  DateTime get date => probe?.recordedAt ?? file.modified;

  /// The match this replay records. Valorant names the file after it, but a
  /// copy may have been renamed, so the header wins when it can be read.
  String get matchId => probe?.matchId.toLowerCase() ?? file.matchId;
}

/// What adding replay files did, so the user can be told.
class ReplayAddResult {
  const ReplayAddResult({
    this.added = const [],
    this.alreadyListed = const [],
    this.unreadable = const [],
    this.failed = const [],
  });

  /// Listed paths of the replays this add brought in.
  final List<String> added;

  /// Listed paths of replays whose match was already in the tab. Nothing
  /// was copied for them.
  final List<String> alreadyListed;

  /// Picked paths that aren't replays Icarus can read. Nothing was copied.
  final List<String> unreadable;

  /// Picked paths that are replays but couldn't be copied.
  final List<String> failed;
}

final replayLibraryProvider =
    AsyncNotifierProvider<ReplayLibrary, List<ReplayListing>>(
  ReplayLibrary.new,
);

/// Replays the tab should scroll to and light up once, because the user just
/// added them. The tab clears it when it has shown them.
final replayRevealProvider = StateProvider<ReplayReveal?>((ref) => null);

class ReplayReveal {
  const ReplayReveal(this.paths);

  /// Listed paths, in the order they were added.
  final List<String> paths;
}

class ReplayLibrary extends AsyncNotifier<List<ReplayListing>> {
  /// What each file's header said, by file cache key, so a refresh only
  /// probes files it hasn't seen. The listing itself is rebuilt each time
  /// from the file as it is now.
  final _probes =
      <String, ({ReplayProbe? probe, ReplayDecodeException? error})>{};

  @override
  Future<List<ReplayListing>> build() => _load();

  /// Newest match first, by the date each tile shows.
  Future<List<ReplayListing>> _load() async {
    final files = await ref.read(replayFilesProvider).list();
    final listings = [for (final file in files) await _listing(file)];
    return listings
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : a.file.path.compareTo(b.file.path);
      });
  }

  Future<ReplayListing> _listing(ReplayFile file) async {
    final header = _probes[file.cacheKey] ??= await _probe(file.path);
    return ReplayListing(file: file, probe: header.probe, error: header.error);
  }

  /// One unreadable file is listed as such; it never hides the others.
  Future<({ReplayProbe? probe, ReplayDecodeException? error})> _probe(
    String path,
  ) async {
    try {
      return (probe: await ref.read(replayProbeProvider)(path), error: null);
    } on ReplayDecodeException catch (error) {
      return (probe: null, error: error);
    } catch (error) {
      return (
        probe: null,
        error: const ReplayDecodeException(
          'corrupt',
          "This file couldn't be read.",
        ),
      );
    }
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_load);
  }

  /// Copies [path] into Icarus's replays folder and lists it.
  Future<ReplayListing> import(String path) async {
    final file = await ref.read(replayFilesProvider).import(path);
    await refresh();
    return _listing(file);
  }

  /// Brings replay files the user picked or dropped into Icarus's replays
  /// folder. A file whose match is already listed is not copied again, and
  /// one that isn't a replay Icarus can read is not copied at all.
  Future<ReplayAddResult> add(List<String> paths) async {
    final files = ref.read(replayFilesProvider);
    final listedByMatch = {
      for (final listing in await _load()) listing.matchId: listing.file.path,
    };
    final added = <String>[];
    final alreadyListed = <String>[];
    final unreadable = <String>[];
    final failed = <String>[];
    for (final path in paths) {
      final header = p.extension(path).toLowerCase() == ReplayFiles.extension
          ? await _probe(path)
          : null;
      final probe = header?.probe;
      if (probe == null) {
        unreadable.add(path);
        continue;
      }
      final matchId = probe.matchId.toLowerCase();
      final listedPath = listedByMatch[matchId];
      if (listedPath != null) {
        if (!added.contains(listedPath) &&
            !alreadyListed.contains(listedPath)) {
          alreadyListed.add(listedPath);
        }
        continue;
      }
      try {
        final copy = await files.import(path);
        _probes[copy.cacheKey] = header!;
        listedByMatch[matchId] = copy.path;
        added.add(copy.path);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          "Couldn't copy ${p.basename(path)} into Icarus's replays folder.",
          error: error,
          stackTrace: stackTrace,
          source: 'ReplayLibrary.add',
          promptUser: false,
        );
        failed.add(path);
      }
    }
    await refresh();
    return ReplayAddResult(
      added: added,
      alreadyListed: alreadyListed,
      unreadable: unreadable,
      failed: failed,
    );
  }
}
