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
  /// What each file's header said, by file cache key, so a refresh only
  /// probes files it hasn't seen. The listing itself is rebuilt each time
  /// from the file as it is now.
  final _probes = <String, ({ReplayProbe? probe, ReplayDecodeException? error})>{};

  @override
  Future<List<ReplayListing>> build() => _load();

  Future<List<ReplayListing>> _load() async {
    final files = await ref.read(replayFilesProvider).list();
    return [for (final file in files) await _listing(file)];
  }

  Future<ReplayListing> _listing(ReplayFile file) async {
    final header = _probes[file.cacheKey] ??= await _probe(file);
    return ReplayListing(file: file, probe: header.probe, error: header.error);
  }

  /// One unreadable file is listed as such; it never hides the others.
  Future<({ReplayProbe? probe, ReplayDecodeException? error})> _probe(
    ReplayFile file,
  ) async {
    try {
      return (probe: await probeReplay(file.path), error: null);
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
}
