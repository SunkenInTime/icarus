/// Whether this build carries the verification driver in `lib/dev/drive/`.
/// Set with `--dart-define=ICARUS_DRIVE=true`, never in a shipped build: the
/// driver signs in, taps and quits on its own.
const bool driveBuild = bool.fromEnvironment('ICARUS_DRIVE');
