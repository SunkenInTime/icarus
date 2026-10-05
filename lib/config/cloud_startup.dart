import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether cloud sync came up when the app started. When it did not, this run
/// is local mode only: nobody can sign in, the cloud outboxes are left
/// untouched on disk, and the library on this device works as usual.
class CloudStartup {
  const CloudStartup._(this.unavailableReason);

  const CloudStartup.unavailable(String reason) : this._(reason);

  static const CloudStartup ready = CloudStartup._(null);

  /// What the user is told about it, or null when the cloud is up.
  final String? unavailableReason;

  bool get isAvailable => unavailableReason == null;
}

/// Set once by `main` before the app is shown.
final cloudStartupProvider = StateProvider<CloudStartup>(
  (ref) => CloudStartup.ready,
);

/// Raised by cloud actions in a run where cloud sync did not start. Its
/// [message] is the reason, worded for the user.
class CloudUnavailableException implements Exception {
  const CloudUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
