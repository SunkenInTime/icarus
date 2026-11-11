import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/replay/replay_decoder.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart'
    show replayPatchLabel;

/// What the user reads about why a replay couldn't be read. The decoder's
/// messages are English written for us, so each known [code] gets its own
/// words; a message this doesn't know is shown as it came.
String replayFailureText(AppLocalizations l10n, ReplayDecodeException error) {
  final message = error.message;
  return switch (error.code) {
    'notAReplay' => l10n.replayLibraryNotAReplay,
    'unsupportedBuild' => switch (error.build) {
        final build? =>
          l10n.replayLibraryPatchUnsupported(replayPatchLabel(build)),
        null => l10n.replayFailureUnsupportedBuild,
      },
    'unsupportedCompression' => l10n.replayFailureUnsupportedCompression,
    'transformCheckFailed' => l10n.replayFailureTransformCheckFailed,
    'corrupt' => l10n.replayFailureUnreadable,
    'unsupportedMap' => l10n.replayMapNotSupported,
    // The rest of `io` is the system's own words about the file.
    'io' when message == replayDesktopOnlyMessage =>
      l10n.replayFailureDesktopOnly,
    'io'
        when message.startsWith(replayDecoderMissingPrefix) &&
            message.endsWith(').') =>
      l10n.replayFailureDecoderMissing(
        message.substring(
          replayDecoderMissingPrefix.length,
          message.length - 2,
        ),
      ),
    _ => message,
  };
}
