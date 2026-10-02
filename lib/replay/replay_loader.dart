import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/replay/replay_document.dart';
import 'package:icarus/replay/replay_files.dart';

/// Opens one replay: from the decoded cache when this decoder has read the
/// file before, otherwise by decoding it and caching the result.
class ReplayLoader {
  ReplayLoader({required this.files, required this.file, required this.probe});

  final ReplayFiles files;
  final ReplayFile file;
  final ReplayProbe probe;

  ReplayDecodeJob? _job;
  bool _cancelled = false;

  /// 0 to 1 while decoding.
  double get progress => _job?.progress ?? 0;

  /// Stops the load wherever it is; [load] then fails as cancelled.
  void cancel() {
    _cancelled = true;
    _job?.cancel();
  }

  void _throwIfCancelled() {
    if (_cancelled) {
      throw const ReplayDecodeException('cancelled', 'Opening was cancelled.');
    }
  }

  Future<ReplayDocument> load() async {
    final cached = await _readCache();
    _throwIfCancelled();
    if (cached != null) return cached;

    final job = _job = decodeReplay(file.path);
    final bytes = await job.result;
    _throwIfCancelled();
    final document = ReplayDocument.fromBytes(bytes);
    try {
      await files.writeCache(file, probe.decoderVersion, bytes);
    } on Exception {
      // A failed cache write only costs a decode next time.
    }
    return document;
  }

  /// The cached document, or null when there is none or it can't be used:
  /// an unreadable or outdated cache is simply decoded again.
  Future<ReplayDocument?> _readCache() async {
    try {
      final bytes = await files.readCache(file, probe.decoderVersion);
      return bytes == null ? null : ReplayDocument.fromBytes(bytes);
    } on Exception {
      return null;
    }
  }
}
