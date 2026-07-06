import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/providers/collab/cloud_collab_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';

class StrategyCapabilities {
  const StrategyCapabilities({
    required this.canRenameStrategy,
    required this.canDeleteStrategy,
    required this.canDuplicateStrategy,
    required this.canMoveStrategy,
    required this.canEditPages,
    required this.canAddPage,
    required this.canRenamePage,
    required this.canDeletePage,
    required this.canReorderPages,
    required this.canCreateFolder,
    required this.canEditFolder,
    required this.canDeleteFolder,
    required this.canMoveFolder,
  });

  final bool canRenameStrategy;
  final bool canDeleteStrategy;
  final bool canDuplicateStrategy;
  final bool canMoveStrategy;
  final bool canEditPages;
  final bool canAddPage;
  final bool canRenamePage;
  final bool canDeletePage;
  final bool canReorderPages;
  final bool canCreateFolder;
  final bool canEditFolder;
  final bool canDeleteFolder;
  final bool canMoveFolder;

  factory StrategyCapabilities.fullAccess() {
    return const StrategyCapabilities(
      canRenameStrategy: true,
      canDeleteStrategy: true,
      canDuplicateStrategy: true,
      canMoveStrategy: true,
      canEditPages: true,
      canAddPage: true,
      canRenamePage: true,
      canDeletePage: true,
      canReorderPages: true,
      canCreateFolder: true,
      canEditFolder: true,
      canDeleteFolder: true,
      canMoveFolder: true,
    );
  }

  factory StrategyCapabilities.fromCloudRole(String? role) {
    final normalized = role ?? 'viewer';
    final canEdit = normalized == 'owner' || normalized == 'editor';
    final isOwner = normalized == 'owner';
    return StrategyCapabilities(
      canRenameStrategy: canEdit,
      canDeleteStrategy: isOwner,
      canDuplicateStrategy: canEdit,
      canMoveStrategy: canEdit,
      canEditPages: canEdit,
      canAddPage: canEdit,
      canRenamePage: canEdit,
      canDeletePage: canEdit,
      canReorderPages: canEdit,
      canCreateFolder: isOwner,
      canEditFolder: isOwner,
      canDeleteFolder: isOwner,
      canMoveFolder: isOwner,
    );
  }
}

final currentStrategyCapabilitiesProvider =
    Provider<StrategyCapabilities>((ref) {
  final strategySource =
      ref.watch(strategyProvider.select((value) => value.source));
  if (strategySource != StrategySource.cloud ||
      !ref.watch(isCloudCollabEnabledProvider)) {
    return StrategyCapabilities.fullAccess();
  }
  final role =
      ref.watch(remoteStrategySnapshotProvider).valueOrNull?.header.role;
  return StrategyCapabilities.fromCloudRole(role);
});

/// Last non-null cloud role reported for the currently open strategy.
///
/// [remoteStrategySnapshotProvider] transiently loses its value during
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

    ref.listen(remoteStrategySnapshotProvider, (previous, next) {
      final role = next.valueOrNull?.header.role;
      if (role != null) {
        state = role;
      }
    });

    return ref.read(remoteStrategySnapshotProvider).valueOrNull?.header.role;
  }
}
