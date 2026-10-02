import 'dart:typed_data';

export 'replay_decoder_stub.dart' if (dart.library.io) 'replay_decoder_io.dart';

/// Why a replay could not be read. [code] is one of the error codes in
/// `docs/replay-format.md`.
class ReplayDecodeException implements Exception {
  const ReplayDecodeException(this.code, this.message, {this.build});

  final String code;
  final String message;

  /// The replay's game build, when the failure is about the build.
  final String? build;

  bool get isUnsupportedBuild => code == 'unsupportedBuild';
  bool get isCancelled => code == 'cancelled';

  factory ReplayDecodeException.fromJson(Map<String, dynamic> json) =>
      ReplayDecodeException(
        json['code'] as String? ?? 'corrupt',
        json['message'] as String? ?? 'The replay could not be read.',
        build: json['build'] as String?,
      );

  @override
  String toString() => 'ReplayDecodeException($code): $message';
}

/// What a replay's header says, read without decoding the match.
class ReplayProbe {
  const ReplayProbe({
    required this.matchId,
    required this.mapPath,
    required this.build,
    required this.durationMs,
    required this.supported,
    required this.decoderVersion,
    required this.agentIds,
    this.recordedAt,
  });

  final String matchId;
  final String mapPath;
  final String build;
  final int durationMs;
  final DateTime? recordedAt;

  /// Whether this build's payload transform is known, so a decode can work.
  final bool supported;

  /// Changes whenever the decoder's output could; decoded caches key by it.
  final String decoderVersion;

  /// Agent UUIDs of the ten players, in header order.
  final List<String> agentIds;

  factory ReplayProbe.fromJson(Map<String, dynamic> json) => ReplayProbe(
        matchId: json['id'] as String,
        mapPath: json['mapPath'] as String,
        build: json['build'] as String,
        durationMs: json['durationMs'] as int,
        recordedAt: DateTime.tryParse(json['recordedAt'] as String? ?? ''),
        supported: json['supported'] as bool? ?? false,
        decoderVersion: json['decoderVersion'] as String,
        agentIds: [
          for (final player in (json['players'] as List? ?? const []))
            ((player as Map)['agentId'] as String).toLowerCase(),
        ],
      );
}

/// A decode in flight. [progress] can be read from any frame; [cancel]
/// stops the decoder at its next chunk boundary and [result] then fails
/// with a `cancelled` [ReplayDecodeException].
abstract class ReplayDecodeJob {
  Future<Uint8List> get result;

  /// 0 to 1.
  double get progress;

  void cancel();
}
