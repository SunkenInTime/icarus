import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/collab_models.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/library_store/cloud_sender_provider.dart';
import 'package:icarus/library_store/library_store_switch.dart';

final editorSubscriptionsProvider = Provider<EditorSubscriptions>(
  (ref) => switch (ref.watch(cloudStoreSwitchProvider)) {
    CloudStoreOff() =>
      TodaysSubscriptions(ref.watch(convexStrategyRepositoryProvider)),
    CloudStoreSend() =>
      StampedSubscriptions(ref.watch(storeRepositoryProvider)),
  },
);

sealed class EditorSubscriptions {
  const EditorSubscriptions(this.repository);

  final ConvexStrategyRepository repository;

  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  });

  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  });
}

final class TodaysSubscriptions extends EditorSubscriptions {
  const TodaysSubscriptions(super.repository);

  @override
  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      repository.watchShell(strategyPublicId, shareToken: shareToken);

  @override
  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      repository.watchPageSnapshot(
        strategyPublicId: strategyPublicId,
        pagePublicId: pagePublicId,
        shareToken: shareToken,
      );
}

final class StampedSubscriptions extends EditorSubscriptions {
  const StampedSubscriptions(super.repository);

  @override
  Stream<RemoteStrategyShell> shell(
    String strategyPublicId, {
    String? shareToken,
  }) =>
      asPlainWatch(
        repository.watchShellStamped(strategyPublicId, shareToken: shareToken),
      );

  @override
  Stream<RemotePageSnapshot> page({
    required String strategyPublicId,
    required String pagePublicId,
    String? shareToken,
  }) =>
      asPlainWatch(
        repository.watchPageSnapshotStamped(
          strategyPublicId: strategyPublicId,
          pagePublicId: pagePublicId,
          shareToken: shareToken,
        ),
      );
}
