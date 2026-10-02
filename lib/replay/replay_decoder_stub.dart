import 'replay_decoder.dart';

const bool replayDecoderAvailable = false;

Future<ReplayProbe> probeReplay(String path) => Future.error(
      const ReplayDecodeException(
        'io',
        'Replays can only be opened in the desktop app.',
      ),
    );

ReplayDecodeJob decodeReplay(String path) => throw const ReplayDecodeException(
      'io',
      'Replays can only be opened in the desktop app.',
    );
