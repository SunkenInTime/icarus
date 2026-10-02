import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_files.dart';

/// Which collection the library screen shows.
enum LibraryTab { strategies, replays }

final libraryTabProvider = StateProvider<LibraryTab>(
  (ref) => LibraryTab.strategies,
);

final replayFilesProvider = Provider<ReplayFiles>((ref) => ReplayFiles());

/// One replay in the Replays tab: its file and what its header says.
class ReplayListing {
  const ReplayListing({required this.file, this.probe, this.error});

  final ReplayFile file;
  final ReplayProbe? probe;

  /// Why the header could not be read; the file is still listed.
  final ReplayDecodeException? error;

  bool get canOpen => probe != null && probe!.supported;
}

final replayLibraryProvider =
    AsyncNotifierProvider<ReplayLibrary, List<ReplayListing>>(
  ReplayLibrary.new,
);

class ReplayLibrary extends AsyncNotifier<List<ReplayListing>> {
  /// Headers already read, by file cache key: a refresh only probes new files.
  final _probes = <String, ReplayListing>{};

  @override
  Future<List<ReplayListing>> build() => _load();

  Future<List<ReplayListing>> _load() async {
    final files = await ref.read(replayFilesProvider).list();
    final listings = <ReplayListing>[];
    for (final file in files) {
      listings.add(_probes[file.cacheKey] ??= await _probe(file));
    }
    return listings;
  }

  Future<ReplayListing> _probe(ReplayFile file) async {
    try {
      return ReplayListing(file: file, probe: await probeReplay(file.path));
    } on ReplayDecodeException catch (error) {
      return ReplayListing(file: file, error: error);
    }
  }

  Future<void> refresh() async {
    state = await AsyncValue.guard(_load);
  }

  /// Copies [path] into Icarus's replays folder and lists it.
  Future<ReplayListing> import(String path) async {
    final file = await ref.read(replayFilesProvider).import(path);
    await refresh();
    return _probes[file.cacheKey] ?? await _probe(file);
  }
}
