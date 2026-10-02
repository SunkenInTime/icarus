import 'dart:typed_data';

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

  /// 0 to 1 while decoding; 1 once read from the cache.
  double get progress => _job?.progress ?? 0;

  /// Stops a decode in progress; [load] then fails as cancelled.
  void cancel() => _job?.cancel();

  Future<ReplayDocument> load() async {
    final cached = await files.readCache(file, probe.decoderVersion);
    if (cached != null) {
      try {
        return ReplayDocument.fromBytes(cached);
      } on FormatException {
        // A cache from an older format: decode again below.
      }
    }
    final job = _job = decodeReplay(file.path);
    final Uint8List bytes = await job.result;
    final document = ReplayDocument.fromBytes(bytes);
    // A failed cache write only costs a decode next time.
    try {
      await files.writeCache(file, probe.decoderVersion, bytes);
    } on Exception catch (_) {}
    return document;
  }
}
