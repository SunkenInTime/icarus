import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/client_upgrade_required_provider.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/lineup_conflicts_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/lineup_group_changes.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:icarus/widgets/client_upgrade_button.dart';
import 'package:icarus/widgets/dialogs/deleted_page_dialog.dart';
import 'package:icarus/widgets/editor_toolbar.dart';
import 'package:icarus/widgets/strategy_save_icon_button.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _glyphSwitchDuration = Duration(milliseconds: 150);
const _conflictToastGap = Duration(seconds: 5);

enum _SyncStatus { synced, editing, syncing, offline, attention }

/// The save button of a cloud strategy. Its glyph is the sync state, so the
/// promise that work is on the server has a face without a text chip:
/// synced, editing, syncing, offline, or needs attention.
///
/// Pressing it saves now. When sync needs attention the press opens a popover
/// that explains what happened and offers recovery instead. Conflicts (the
/// server rejected an edit while the local intent was kept) surface as a toast.
/// Unsaved work on a page a teammate deleted asks the user what to do with it.
///
/// Renders nothing for local strategies; [AutoSaveButton] covers those.
class CloudSyncButton extends ConsumerStatefulWidget {
  const CloudSyncButton({super.key, required this.style});

  final EditorToolbarButtonStyle style;

  @override
  ConsumerState<CloudSyncButton> createState() => _CloudSyncButtonState();
}

class _CloudSyncButtonState extends ConsumerState<CloudSyncButton> {
  final ShadPopoverController _popoverController = ShadPopoverController();
  DateTime? _lastConflictToast;
  Timer? _pendingConflictToast;
  bool _isResolving = false;
  String? _resolutionError;
  bool _showingDeletedPage = false;

  @override
  void initState() {
    super.initState();
    // The editor may have been rebuilt while a deleted page was waiting.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final page = ref.read(strategyPageSessionProvider).deletedPage;
      if (page != null) _showDeletedPage(page);
    });
  }

  Future<void> _showDeletedPage(DeletedPage page) async {
    if (_showingDeletedPage) return;
    _showingDeletedPage = true;
    try {
      await DeletedPageDialog.show(context, page);
    } finally {
      _showingDeletedPage = false;
    }
  }

  @override
  void dispose() {
    _pendingConflictToast?.cancel();
    _popoverController.dispose();
    super.dispose();
  }

  void _onConflicts(int previousCount, int count) {
    if (count <= previousCount) {
      return;
    }
    final now = DateTime.now();
    final sinceLastToast = _lastConflictToast == null
        ? _conflictToastGap
        : now.difference(_lastConflictToast!);
    if (sinceLastToast >= _conflictToastGap) {
      _showConflictToast();
    } else {
      // Throttled: hold the conflicts and notify once the window expires so
      // no rebase goes completely unannounced.
      _pendingConflictToast ??= Timer(_conflictToastGap - sinceLastToast, () {
        _pendingConflictToast = null;
        if (!mounted) {
          return;
        }
        if (ref.read(strategyConflictProvider).isNotEmpty) {
          _showConflictToast();
        }
      });
    }
  }

  void _showConflictToast() {
    _lastConflictToast = DateTime.now();
    final specificReason = ref
        .read(strategyConflictProvider)
        .map((conflict) => conflict.message)
        .whereType<String>()
        .where(isSpecificAttentionReason)
        .firstOrNull;
    Settings.showToast(
      message: specificReason != null
          ? friendlyCloudSyncError(specificReason)
          : 'Another edit reached the cloud first. Your version is still on '
              'this device and needs attention.',
      backgroundColor: Settings.tacticalVioletTheme.destructive,
    );
    ref.read(strategyConflictProvider.notifier).clearAll();
  }

  Future<void> _handlePressed(_SyncStatus status) async {
    if (status == _SyncStatus.attention) {
      _popoverController.toggle();
      return;
    }
    await saveStrategyNow(context, ref);
  }

  Future<void> _retry() async {
    if (_isResolving) return;
    setState(() {
      _isResolving = true;
      _resolutionError = null;
    });
    _popoverController.hide();
    try {
      await ref
          .read(cloudMediaUploadQueueProvider.notifier)
          .retryNow(ignoreBackoff: true);
      final opQueue = ref.read(strategyOpQueueProvider.notifier);
      await opQueue.retryPaused(flushImmediately: false);
      await opQueue.retryRejected(flushImmediately: false);
      await opQueue.flushNow();
      opQueue.clearStaleError();
    } finally {
      if (mounted) setState(() => _isResolving = false);
    }
  }

  Future<void> _useCloudVersions() async {
    if (_isResolving) return;
    setState(() {
      _isResolving = true;
      _resolutionError = null;
    });
    String? resolutionError;
    try {
      final resolved = await ref
          .read(strategyPageSessionProvider.notifier)
          .useCloudVersionsForRejected();
      if (resolved) {
        _popoverController.hide();
      } else {
        resolutionError = 'Could not load the cloud version. '
            'Your saved version was not changed.';
      }
    } catch (error, stackTrace) {
      log(
        'Failed to use the cloud version: $error',
        name: 'cloud_conflict_resolution',
        error: error,
        stackTrace: stackTrace,
      );
      resolutionError = 'Could not load the cloud version. '
          'Your saved version was not changed.';
    } finally {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _resolutionError = resolutionError;
        });
      }
    }
  }

  Future<void> _keepBoth() async {
    if (_isResolving) return;
    setState(() {
      _isResolving = true;
      _resolutionError = null;
    });
    String? resolutionError;
    try {
      switch (await ref
          .read(strategyPageSessionProvider.notifier)
          .keepBothForRejected()) {
        case KeepBothOutcome.kept:
          _popoverController.hide();
        case KeepBothOutcome.unchanged:
          resolutionError = 'Could not load the cloud version. '
              'Nothing was changed.';
        case KeepBothOutcome.copiesOnly:
          resolutionError = 'Your version was added as a copy, but the '
              'cloud version could not be loaded. Choose Use cloud to '
              'finish.';
      }
    } catch (error, stackTrace) {
      log(
        'Failed to keep both versions: $error',
        name: 'cloud_conflict_resolution',
        error: error,
        stackTrace: stackTrace,
      );
      resolutionError = 'Could not keep both versions. '
          'Your version is still saved on this device.';
    } finally {
      if (mounted) {
        setState(() {
          _isResolving = false;
          _resolutionError = resolutionError;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(strategyProvider.select((state) => state.source));
    ref.listen(strategyConflictProvider, (previous, next) {
      _onConflicts(previous?.length ?? 0, next.length);
    });
    ref.listen(strategyPageSessionProvider.select((state) => state.deletedPage),
        (previous, next) {
      if (next != null && previous == null) _showDeletedPage(next);
    });

    if (source != StrategySource.cloud) {
      return const SizedBox.shrink();
    }

    final saveState = ref.watch(strategySaveStateProvider);
    // Work that may not be on this device outranks the refusal: its own
    // recovery shows, and nothing offers to throw the session away.
    final upgradeRequired = ref.watch(clientUpgradeRequiredProvider) &&
        !ref.watch(cloudWorkDurabilityUncertainProvider);
    final opQueueState = ref.watch(strategyOpQueueProvider);
    final mediaQueueState = ref.watch(cloudMediaUploadQueueProvider);
    final activeStrategyId = ref.watch(
      strategyProvider.select((state) => state.strategyId),
    );
    final hasOtherStrategyWork = opQueueState.accountOutbox.strategies.values
            .any((summary) => summary.strategyPublicId != activeStrategyId) ||
        mediaQueueState.jobs.any(
          (job) => job.strategyPublicId != activeStrategyId,
        );
    final hasOtherStrategyAttention =
        opQueueState.accountOutbox.strategies.values.any((summary) =>
                summary.strategyPublicId != activeStrategyId &&
                summary.needsAttention) ||
            mediaQueueState.jobs.any(
              (job) => job.strategyPublicId != activeStrategyId && job.isFailed,
            );
    final hasActiveStrategyAttention = opQueueState.needsAttention ||
        saveState.cloudSyncError != null ||
        saveState.mediaSyncErrorCount > 0 ||
        mediaQueueState.jobs.any(
          (job) => job.strategyPublicId == activeStrategyId && job.isFailed,
        );
    final status = switch (ref.watch(cloudSyncStatusProvider)) {
      CloudSyncStatus.synced => _SyncStatus.synced,
      CloudSyncStatus.editing => _SyncStatus.editing,
      CloudSyncStatus.syncing => _SyncStatus.syncing,
      CloudSyncStatus.offline => _SyncStatus.offline,
      CloudSyncStatus.attention => _SyncStatus.attention,
    };

    final syncTooltip = _tooltip(status, saveState.lastPersistedAt);
    // The editor carries no status chips, so a viewer learns here why their
    // edits do not stick.
    final tooltip = ref.watch(lastKnownCloudRoleProvider) == 'viewer'
        ? 'View only · $syncTooltip'
        : syncTooltip;
    final foreground = status == _SyncStatus.attention
        ? Settings.tacticalVioletTheme.destructive
        : null;

    return ShadPopover(
      controller: _popoverController,
      padding: const EdgeInsets.all(14),
      anchor: const ShadAnchor(
        offset: Offset(0, 8),
        childAlignment: Alignment.topLeft,
        overlayAlignment: Alignment.bottomLeft,
      ),
      popover: (context) => _SyncStatusPopover(
        status: status,
        upgradeRequired: upgradeRequired,
        saveState: saveState,
        rejectedCount: opQueueState.attentionByEntityKey.length,
        lineupConflicts: ref.watch(lineupConflictsProvider),
        hasOtherStrategyWork: hasOtherStrategyWork,
        hasOtherStrategyAttention: hasOtherStrategyAttention,
        hasActiveStrategyAttention: hasActiveStrategyAttention,
        isResolving: _isResolving,
        resolutionError: _resolutionError,
        onRetry: _retry,
        onUseCloudVersions: _useCloudVersions,
        onKeepBoth: _keepBoth,
      ),
      child: EditorToolbarButton(
        key: ValueKey('cloud-sync-button-${status.name}'),
        style: widget.style,
        tooltip: tooltip,
        semanticsLabel: tooltip,
        foregroundColor: foreground,
        onPressed: () => _handlePressed(status),
        icon: AnimatedSwitcher(
          duration: _glyphSwitchDuration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeOutCubic,
          child: _glyph(status, foreground),
        ),
      ),
    );
  }

  Widget _glyph(_SyncStatus status, Color? color) {
    // Lucide's cloud sits low in its box and reads smaller than the upload
    // and camera glyphs beside it, so it gets 2px more.
    final size = widget.style.iconSize + 2;
    switch (status) {
      case _SyncStatus.synced:
        return Icon(
          LucideIcons.cloudCheck200,
          key: const ValueKey('synced'),
          size: size,
          color: color,
        );
      case _SyncStatus.editing:
        return Icon(
          LucideIcons.cloudUpload200,
          key: const ValueKey('editing'),
          size: size,
          color: color,
        );
      case _SyncStatus.syncing:
        return SizedBox(
          key: const ValueKey('syncing'),
          width: size - 4,
          height: size - 4,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            valueColor: AlwaysStoppedAnimation<Color>(
              color ?? Settings.tacticalVioletTheme.mutedForeground,
            ),
          ),
        );
      case _SyncStatus.offline:
        return Icon(
          LucideIcons.cloudOff200,
          key: const ValueKey('offline'),
          size: size,
          color: color,
        );
      case _SyncStatus.attention:
        return Icon(
          LucideIcons.cloudAlert200,
          key: const ValueKey('attention'),
          size: size,
          color: color,
        );
    }
  }

  /// One line, what the glyph means and what a press will do.
  static String _tooltip(_SyncStatus status, DateTime? lastSynced) {
    switch (status) {
      case _SyncStatus.synced:
        return lastSynced == null
            ? 'Synced'
            : 'Synced at ${_SyncStatusPopover._formatTime(lastSynced)}';
      case _SyncStatus.editing:
        return 'Edit not synced yet';
      case _SyncStatus.syncing:
        return 'Syncing…';
      case _SyncStatus.offline:
        return 'Offline, changes stay on this device';
      case _SyncStatus.attention:
        return 'Sync needs attention';
    }
  }
}

class _SyncStatusPopover extends StatelessWidget {
  const _SyncStatusPopover({
    required this.status,
    required this.upgradeRequired,
    required this.saveState,
    required this.rejectedCount,
    required this.lineupConflicts,
    required this.hasOtherStrategyWork,
    required this.hasOtherStrategyAttention,
    required this.hasActiveStrategyAttention,
    required this.isResolving,
    required this.resolutionError,
    required this.onRetry,
    required this.onUseCloudVersions,
    required this.onKeepBoth,
  });

  final _SyncStatus status;

  /// The server refuses this build. Nothing here can fix that, so the
  /// popover says so and offers only the reload or update that can.
  final bool upgradeRequired;
  final StrategySaveState saveState;
  final int rejectedCount;

  /// What each side did to the lineup groups in conflict, when the refused
  /// work is all lineup groups on this page (see lineupConflictsProvider).
  /// Then the popover lists the changes and offers Keep both.
  final List<LineupGroupConflict>? lineupConflicts;
  final bool hasOtherStrategyWork;
  final bool hasOtherStrategyAttention;
  final bool hasActiveStrategyAttention;
  final bool isResolving;
  final String? resolutionError;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUseCloudVersions;
  final Future<void> Function() onKeepBoth;

  bool get hasRejectedWork => rejectedCount > 0;

  /// The lineup changes to list, when there is no more specific reason to
  /// show instead (a deleted page, an oversized change).
  List<LineupGroupConflict>? get _shownLineupConflicts {
    final error = saveState.cloudSyncError;
    if (error != null && isSpecificAttentionReason(error)) return null;
    return lineupConflicts;
  }

  @override
  Widget build(BuildContext context) {
    if (upgradeRequired) {
      return ClientUpgradeNotice(
        buttonSize: ShadButtonSize.sm,
        builder: (context, message, action) => _layout(
          context,
          explanation: message,
          actions: action == null
              ? null
              : Align(alignment: Alignment.centerRight, child: action),
        ),
      );
    }
    return _layout(
      context,
      explanation: _explanation,
      actions: status == _SyncStatus.attention &&
              (!hasOtherStrategyAttention || hasActiveStrategyAttention)
          ? Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (hasRejectedWork)
                  ShadButton.secondary(
                    size: ShadButtonSize.sm,
                    expands: false,
                    onPressed: isResolving ? null : onUseCloudVersions,
                    child: const Text('Use cloud'),
                  ),
                if (_shownLineupConflicts != null)
                  ShadButton.secondary(
                    size: ShadButtonSize.sm,
                    expands: false,
                    onPressed: isResolving ? null : onKeepBoth,
                    child: const Text('Keep both'),
                  ),
                ShadButton(
                  size: ShadButtonSize.sm,
                  expands: false,
                  onPressed: isResolving ? null : onRetry,
                  child: Text(
                    hasRejectedWork ? 'Keep mine' : 'Retry sync',
                  ),
                ),
              ],
            )
          : null,
    );
  }

  Widget _layout(
    BuildContext context, {
    required String explanation,
    required Widget? actions,
  }) {
    final theme = ShadTheme.of(context);
    final lastSynced = saveState.lastPersistedAt;

    // Text alignment is inherited from the editor, which centers, so pin it
    // here; the column's own alignment does not reach inside the Texts.
    return DefaultTextStyle.merge(
      textAlign: TextAlign.start,
      child: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _title,
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.foreground,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              explanation,
              style: theme.textTheme.small.copyWith(
                color: theme.colorScheme.mutedForeground,
                height: 1.35,
              ),
            ),
            if (_shownLineupConflicts case final conflicts?)
              _LineupConflictList(conflicts: conflicts),
            if (resolutionError != null) ...[
              const SizedBox(height: 8),
              Text(
                resolutionError!,
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.destructive,
                  height: 1.35,
                ),
              ),
            ],
            if (lastSynced != null) ...[
              const SizedBox(height: 8),
              Text(
                'Last synced at ${_formatTime(lastSynced)}',
                style: theme.textTheme.small.copyWith(
                  color: theme.colorScheme.mutedForeground,
                  fontSize: 11,
                ),
              ),
            ],
            if (actions != null) ...[
              const SizedBox(height: 12),
              actions,
            ],
          ],
        ),
      ),
    );
  }

  String get _title {
    switch (status) {
      case _SyncStatus.synced:
        return 'All changes synced';
      case _SyncStatus.editing:
        return 'Edit not synced yet';
      case _SyncStatus.syncing:
        return 'Syncing changes';
      case _SyncStatus.offline:
        return 'Working offline';
      case _SyncStatus.attention:
        return 'Sync needs attention';
    }
  }

  String get _explanation {
    switch (status) {
      case _SyncStatus.synced:
        return 'Your strategy is safely stored in the cloud.';
      case _SyncStatus.editing:
        return 'Finish editing or switch pages to send this change to the '
            'cloud.';
      case _SyncStatus.syncing:
        return hasOtherStrategyWork
            ? 'Saved changes from your cloud library are being sent in the '
                'background.'
            : 'Your edits are being sent to the cloud. You can keep '
                'working — this happens in the background.';
      case _SyncStatus.offline:
        return 'Changes are kept on this device and will sync automatically '
            'when your connection returns.';
      case _SyncStatus.attention:
        const otherStrategyExplanation =
            'Saved work in another strategy also needs attention. Open it '
            'from the Cloud library to review the reason.';
        if (!hasOtherStrategyAttention) return _attentionExplanation;
        if (hasActiveStrategyAttention) {
          return '$_attentionExplanation $otherStrategyExplanation';
        }
        return otherStrategyExplanation.replaceFirst(' also', '');
    }
  }

  String get _attentionExplanation {
    final mediaErrors = saveState.mediaSyncErrorCount;
    final parts = <String>[];
    final error = saveState.cloudSyncError;
    final hasSpecificReason = error != null && isSpecificAttentionReason(error);
    if (_shownLineupConflicts != null) {
      parts.add(
        'A teammate changed these lineups while you were working on them. '
        'Your version remains saved on this device.',
      );
      parts.add(
        'Keep mine replaces their changes, Use cloud replaces yours, and '
        'Keep both adds yours beside theirs as a copy.',
      );
    } else if (hasRejectedWork && !hasSpecificReason) {
      parts.add(
        'Another edit reached the cloud first. Your version remains saved '
        'on this device.',
      );
      parts.add(
        rejectedCount == 1
            ? 'Choose which version to keep for this conflicting change.'
            : 'Your choice applies to all $rejectedCount conflicting changes.',
      );
    }
    final retryUnavailable =
        error?.toLowerCase().contains('cannot be retried automatically') ??
            false;
    if (error != null &&
        (!hasRejectedWork || retryUnavailable || hasSpecificReason)) {
      parts.add(friendlyCloudSyncError(error));
    }
    if (error?.contains(otherWorkNeedsAttentionNote) ?? false) {
      parts.add(
        'Other changes here were not saved either. They remain on this '
        'device.',
      );
    }
    if (hasRejectedWork && hasSpecificReason && rejectedCount > 1) {
      parts.add(
        'Your choice applies to all $rejectedCount changes that need '
        'attention.',
      );
    }
    if (mediaErrors > 0) {
      parts.add(
        mediaErrors == 1
            ? 'One image failed to upload.'
            : '$mediaErrors images failed to upload.',
      );
    }
    if (parts.isEmpty) {
      parts.add("Some changes haven't reached the cloud yet.");
    }
    if (!hasRejectedWork) parts.add('Retry to send them now.');
    return parts.join(' ');
  }

  static String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

/// The lineups each side changed in the conflicting lineup groups: what
/// Keep mine would replace (the cloud's changes) and what Use cloud would
/// (the user's), so neither choice drops work the user cannot see.
class _LineupConflictList extends StatelessWidget {
  const _LineupConflictList({required this.conflicts});

  final List<LineupGroupConflict> conflicts;

  /// More lines than this read as a wall; the rest are counted instead.
  static const _maxLines = 4;

  @override
  Widget build(BuildContext context) {
    final yours = [for (final conflict in conflicts) ...conflict.yours];
    final cloud = [for (final conflict in conflicts) ...conflict.cloud];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        _section(context, 'Your changes', yours),
        const SizedBox(height: 8),
        _section(context, 'Cloud changes', cloud),
      ],
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    List<LineupChange> changes,
  ) {
    final theme = ShadTheme.of(context);
    final lineStyle = theme.textTheme.small.copyWith(
      color: theme.colorScheme.foreground,
      fontSize: 12,
      height: 1.35,
    );
    final mutedStyle = lineStyle.copyWith(
      color: theme.colorScheme.mutedForeground,
    );
    final shown = changes.take(_maxLines).toList();
    final hidden = changes.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.small.copyWith(
            color: theme.colorScheme.mutedForeground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        if (changes.isEmpty) Text('No lineup changes', style: mutedStyle),
        for (final change in shown)
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: change.label),
                TextSpan(text: ' · ${change.description}', style: mutedStyle),
              ],
            ),
            style: lineStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        if (hidden > 0)
          Text(
            hidden == 1 ? 'and 1 more lineup' : 'and $hidden more lineups',
            style: mutedStyle,
          ),
      ],
    );
  }
}
