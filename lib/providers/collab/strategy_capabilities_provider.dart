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
  // The role last read is stale once access is confirmed gone.
  if (ref.watch(strategyAccessLostProvider)) {
    return StrategyCapabilities.fromCloudRole(null);
  }
  final header = ref.watch(remoteEditorSnapshotProvider).valueOrNull?.header;
  final role = header?.publicId == strategy.$2 ? header?.role : null;
  return StrategyCapabilities.fromCloudRole(role);
});

/// Whether the signed-in reader lost their access to the open cloud strategy
/// while they had it open (see [StrategyAccessLost]).
final strategyAccessLostProvider = Provider<bool>((ref) {
  return ref.watch(
    remoteEditorSnapshotProvider.select(
      (snapshot) => snapshot.error is StrategyAccessLost,
    ),
  );
});

/// Asked by every mutator that commits a user's edit to the open strategy's
/// page content: placing, moving, changing or removing what is on a page,
/// lineups included, and undo and redo. Access can drop while an edit is in
/// hand (a drag, an open dialog), and the server refuses whatever a reader
/// who cannot edit sends; such an edit changes nothing here rather than show
/// work that will never land. Loading and merging what the server holds
/// never ask. Local strategies can always be edited.
extension PageEditAccess on Ref {
  // Asked of the container, as a one-off question rather than a dependency:
  // the capabilities follow strategyProvider, which listens to the providers
  // that ask, and Riverpod refuses a ref.read back along that path.
  bool get canEditPages =>
      container.read(currentStrategyCapabilitiesProvider).canEditPages;
}

/// Whether the open strategy is view-only for this reader, by the last role
/// the server reported. The editor leaves out its editing panels then, since
/// none of their controls would respond. Layout reads the last known role so
/// a refresh that briefly fails cannot drop an editor's panels mid-session.
final isViewOnlyStrategyProvider = Provider<bool>((ref) {
  final source = ref.watch(strategyProvider.select((value) => value.source));
  return source == StrategySource.cloud &&
      (ref.watch(lastKnownCloudRoleProvider) == 'viewer' ||
          ref.watch(strategyAccessLostProvider));
});

/// Last non-null cloud role reported for the currently open strategy.
///
/// [remoteEditorSnapshotProvider] transiently loses its value during
/// reloads, refresh errors, and auth incidents, so role-dependent UI (like
/// the "View only" note on the cloud sync button) must not read
/// `valueOrNull` directly or it flickers off mid-session. This provider
/// remembers the last role seen for the open strategy and only resets when a
/// different strategy is opened.
/// It is null before the role has ever been known, and once the reader's
/// access is gone: the role last seen no longer holds.
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
      if (next.error is StrategyAccessLost) {
        state = null;
        return;
      }
      final role = next.valueOrNull?.header.role;
      if (role != null) {
        state = role;
      }
    });

    final snapshot = ref.read(remoteEditorSnapshotProvider);
    if (snapshot.error is StrategyAccessLost) return null;
    return snapshot.valueOrNull?.header.role;
  }
}
