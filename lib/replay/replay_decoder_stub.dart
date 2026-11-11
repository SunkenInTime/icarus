import 'replay_decoder.dart';

const bool replayDecoderAvailable = false;

Future<ReplayProbe> probeReplay(String path) => Future.error(
      const ReplayDecodeException(
        'io',
        replayDesktopOnlyMessage,
      ),
    );

ReplayDecodeJob decodeReplay(String path) => throw const ReplayDecodeException(
      'io',
      replayDesktopOnlyMessage,
    );
