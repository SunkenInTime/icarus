import 'dart:async';

/// Broadcast stream of args received when a second instance is launched.
///
/// Used to forward args into the running app instance (e.g. opened file paths).
final StreamController<List<String>> secondInstanceArgsController =
    StreamController<List<String>>.broadcast();

void publishSecondInstanceArgs(List<String> args) {
  if (args.isEmpty) return;
  secondInstanceArgsController.add(args);
}
