import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/strategy_capabilities.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

export 'package:icarus/collab/strategy_capabilities.dart';

final currentStrategyCapabilitiesProvider =
    Provider<StrategyCapabilities>((ref) {
  final strategy = ref.watch(
    strategyProvider.select((value) => (value.source, value.strategyId)),
  );
  if (strategy.$1 != StrategySource.cloud) {
    return StrategyCapabilities.fullAccess();
  }
  final header = ref.watch(remoteEditorSnapshotProvider).valueOrNull?.header;
  final role = header?.publicId == strategy.$2 ? header?.role : null;
  return StrategyCapabilities.fromCloudRole(role);
});

/// Last non-null cloud role reported for the currently open strategy.
///
/// [remoteEditorSnapshotProvider] transiently loses its value during
/// reloads, refresh errors, and auth incidents, so role-dependent UI (like
/// the editor's "View only" chip) must not read `valueOrNull` directly or it
/// flickers off mid-session. This provider remembers the last role seen for
/// the open strategy and only resets when a different strategy is opened.
/// It is null only before the role has ever been known.
final lastKnownCloudRoleProvider =
    NotifierProvider<LastKnownCloudRoleNotifier, String?>(
  LastKnownCloudRoleNotifier.new,
);

class LastKnownCloudRoleNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Rebuild (and therefore reset the cached role) whenever a different
    // strategy is opened.
    ref.watch(strategyProvider.select((value) => value.strategyId));

    ref.listen(remoteEditorSnapshotProvider, (previous, next) {
      final role = next.valueOrNull?.header.role;
      if (role != null) {
        state = role;
      }
    });

    return ref.read(remoteEditorSnapshotProvider).valueOrNull?.header.role;
  }
}
