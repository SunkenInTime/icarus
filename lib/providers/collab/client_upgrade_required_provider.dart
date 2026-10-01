import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';

/// Whether the server has refused this build's cloud protocol. Set by the
/// first refusal anything notes, and never cleared: only a reload (web) or an
/// update (desktop) brings a build the server accepts, and either starts the
/// app again.
final clientUpgradeRequiredProvider =
    NotifierProvider<ClientUpgradeRequiredNotifier, bool>(
  ClientUpgradeRequiredNotifier.new,
);

class ClientUpgradeRequiredNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// Notes [error] when it is the server refusing this build, and returns
  /// whether it was.
  bool noteError(Object? error) {
    if (!isClientUpgradeRequiredError(error)) return false;
    state = true;
    return true;
  }
}
