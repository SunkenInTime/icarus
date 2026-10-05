import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';

/// Whether the server refuses this build's cloud protocol. Set by the first
/// refusal anything notes. Only [recheck] clears it, when the server accepts
/// the protocol again (a rolled-back deploy); otherwise a reload (web) or an
/// update (desktop) is the way out, and either starts the app again.
final clientUpgradeRequiredProvider =
    NotifierProvider<ClientUpgradeRequiredNotifier, bool>(
  ClientUpgradeRequiredNotifier.new,
);

class ClientUpgradeRequiredNotifier extends Notifier<bool> {
  bool _disposed = false;

  @override
  bool build() {
    ref.onDispose(() => _disposed = true);
    return false;
  }

  /// Notes [error] when it is the server refusing this build, and returns
  /// whether it was.
  bool noteError(Object? error) {
    if (!isClientUpgradeRequiredError(error)) return false;
    state = true;
    return true;
  }

  /// Asks the server once, cheaply, whether it accepts this protocol again,
  /// and clears the refusal if it does. Anything short of a clear answer
  /// (offline, an older server) leaves it as it was.
  Future<void> recheck() async {
    if (!state) return;
    final bool accepted;
    try {
      accepted = await ref
          .read(convexStrategyRepositoryProvider)
          .serverAcceptsCloudProtocol();
    } catch (_) {
      return;
    }
    if (accepted && !_disposed) state = false;
  }
}
