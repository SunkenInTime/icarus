import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/auth_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/remote_library_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/library_workspace_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/strategy_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class CloudOutboxSummaryBanner extends ConsumerWidget {
  const CloudOutboxSummaryBanner({super.key, this.onOpenStrategy});

  final ValueChanged<String>? onOpenStrategy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(libraryWorkspaceProvider) != LibraryWorkspace.cloud) {
      return const SizedBox.shrink();
    }
    final opQueue = ref.watch(strategyOpQueueProvider);
    final mediaQueue = ref.watch(cloudMediaUploadQueueProvider);
    final auth = ref.watch(authProvider);
    final strategyNames = ref.watch(cloudStrategyNamesProvider);
    final connected = ref.watch(convexConnectionProvider).valueOrNull ?? true;
    final strategyIds = <String>{
      ...opQueue.accountOutbox.strategies.keys,
      for (final job in mediaQueue.jobs) job.strategyPublicId,
    };
    final workCount = opQueue.accountOutbox.workCount + mediaQueue.jobs.length;
    final failedMediaByStrategy = <String, int>{};
    for (final job in mediaQueue.jobs.where((job) => job.isFailed)) {
      failedMediaByStrategy.update(
        job.strategyPublicId,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final attentionIds = <String>{
      for (final summary in opQueue.accountOutbox.strategies.values)
        if (summary.needsAttention) summary.strategyPublicId,
      ...failedMediaByStrategy.keys,
    };
    final hasDurabilityProblem = !opQueue.outboxIsReliable ||
        !mediaQueue.outboxIsReliable ||
        opQueue.loadIssues.isNotEmpty ||
        mediaQueue.loadIssues.isNotEmpty;
    final authBlocked = workCount > 0 &&
        (auth.hasActiveAuthIncident || !auth.isConvexUserReady);
    if (workCount == 0 && !hasDurabilityProblem) {
      return const SizedBox.shrink();
    }

    final needsAttention =
        hasDurabilityProblem || authBlocked || attentionIds.isNotEmpty;
    final title = needsAttention
        ? 'Cloud work needs attention'
        : connected
            ? 'Syncing cloud work'
            : 'Working offline';
    final detail = hasDurabilityProblem
        ? 'Icarus cannot read some saved cloud work on this device. Stay '
            'signed in and review it.'
        : authBlocked
            ? 'Reconnect this account before Icarus can send its saved work.'
            : needsAttention
                ? '$workCount saved ${workCount == 1 ? 'change needs' : 'changes need'} '
                    'review across ${strategyIds.length} '
                    '${strategyIds.length == 1 ? 'strategy' : 'strategies'}.'
                : connected
                    ? '$workCount saved ${workCount == 1 ? 'change is' : 'changes are'} '
                        'being sent from ${strategyIds.length} '
                        '${strategyIds.length == 1 ? 'strategy' : 'strategies'}.'
                    : '$workCount saved ${workCount == 1 ? 'change is' : 'changes are'} '
                        'waiting on this device and will resume when the '
                        'connection returns.';
    final theme = ShadTheme.of(context);
    return Container(
      key: const ValueKey('cloud-outbox-summary'),
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Settings.tacticalVioletTheme.card,
        border: Border.all(color: Settings.tacticalVioletTheme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            needsAttention
                ? LucideIcons.circleAlert
                : connected
                    ? LucideIcons.cloudUpload
                    : LucideIcons.cloudOff,
            size: 18,
            color: needsAttention
                ? theme.colorScheme.destructive
                : theme.colorScheme.mutedForeground,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.small.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: theme.textTheme.small.copyWith(
                    color: theme.colorScheme.mutedForeground,
                  ),
                ),
                if (attentionIds.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final strategyId in attentionIds)
                        ShadButton.outline(
                          size: ShadButtonSize.sm,
                          onPressed: () => _openStrategy(context, strategyId),
                          child: Text(_attentionLabel(
                            strategyId,
                            strategyNames[strategyId],
                            opQueue
                                .accountOutbox.strategies[strategyId]?.reason,
                            failedMediaByStrategy[strategyId] ?? 0,
                          )),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openStrategy(BuildContext context, String strategyId) {
    final callback = onOpenStrategy;
    if (callback != null) {
      callback(strategyId);
      return;
    }
    Navigator.of(context).push(
      StrategyView.route(
        initialStrategyId: strategyId,
        initialStrategySource: StrategySource.cloud,
      ),
    );
  }

  String _attentionLabel(
    String id,
    String? strategyName,
    String? reason,
    int failedMediaCount,
  ) {
    final label = strategyName?.trim().isNotEmpty == true
        ? strategyName!.trim()
        : 'A cloud strategy';
    if (reason != null && reason.isNotEmpty) {
      return '$label: review sync';
    }
    if (failedMediaCount > 0) {
      return '$label: $failedMediaCount '
          '${failedMediaCount == 1 ? 'image failed' : 'images failed'}';
    }
    return '$label: review';
  }
}
