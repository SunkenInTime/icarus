import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/cloud_sync_error_message.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/cloud_sync_status_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_page_session_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
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
    Settings.showToast(
      message: 'Another edit reached the cloud first. Your version is still on '
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

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(strategyProvider.select((state) => state.source));
    ref.listen(strategyConflictProvider, (previous, next) {
      _onConflicts(previous?.length ?? 0, next.length);
    });

    if (source != StrategySource.cloud) {
      return const SizedBox.shrink();
    }

    final saveState = ref.watch(strategySaveStateProvider);
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

    final tooltip = _tooltip(status, saveState.lastPersistedAt);
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
        saveState: saveState,
        rejectedCount: opQueueState.attentionByEntityKey.length,
        hasOtherStrategyWork: hasOtherStrategyWork,
        hasOtherStrategyAttention: hasOtherStrategyAttention,
        hasActiveStrategyAttention: hasActiveStrategyAttention,
        isResolving: _isResolving,
        resolutionError: _resolutionError,
        onRetry: _retry,
        onUseCloudVersions: _useCloudVersions,
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
          LucideIcons.cloudCheck300,
          key: const ValueKey('synced'),
          size: size,
          color: color,
        );
      case _SyncStatus.editing:
        return Icon(
          LucideIcons.cloudUpload300,
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
          LucideIcons.cloudOff300,
          key: const ValueKey('offline'),
          size: size,
          color: color,
        );
      case _SyncStatus.attention:
        return Icon(
          LucideIcons.cloudAlert300,
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
    required this.saveState,
    required this.rejectedCount,
    required this.hasOtherStrategyWork,
    required this.hasOtherStrategyAttention,
    required this.hasActiveStrategyAttention,
    required this.isResolving,
    required this.resolutionError,
    required this.onRetry,
    required this.onUseCloudVersions,
  });

  final _SyncStatus status;
  final StrategySaveState saveState;
  final int rejectedCount;
  final bool hasOtherStrategyWork;
  final bool hasOtherStrategyAttention;
  final bool hasActiveStrategyAttention;
  final bool isResolving;
  final String? resolutionError;
  final Future<void> Function() onRetry;
  final Future<void> Function() onUseCloudVersions;

  bool get hasRejectedWork => rejectedCount > 0;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final lastSynced = saveState.lastPersistedAt;

    return SizedBox(
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _title,
            style: theme.textTheme.small.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _explanation,
            style: theme.textTheme.small.copyWith(
              color: theme.colorScheme.mutedForeground,
              height: 1.35,
            ),
          ),
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
          if (status == _SyncStatus.attention &&
              (!hasOtherStrategyAttention || hasActiveStrategyAttention)) ...[
            const SizedBox(height: 12),
            if (hasRejectedWork) ...[
              ShadButton.secondary(
                size: ShadButtonSize.sm,
                expands: false,
                onPressed: isResolving ? null : onUseCloudVersions,
                child: const Text('Use cloud'),
              ),
              const SizedBox(height: 8),
            ],
            ShadButton(
              size: ShadButtonSize.sm,
              expands: false,
              onPressed: isResolving ? null : onRetry,
              child: Text(
                hasRejectedWork ? 'Keep mine' : 'Retry sync',
              ),
            ),
          ],
        ],
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
    final hasOversizedWork =
        error?.toLowerCase().contains('too large for cloud sync') ?? false;
    if (hasRejectedWork && !hasOversizedWork) {
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
        (!hasRejectedWork || retryUnavailable || hasOversizedWork)) {
      parts.add(friendlyCloudSyncError(error));
    }
    if (hasRejectedWork && hasOversizedWork) {
      parts.add(
        rejectedCount == 1
            ? 'Choose whether to keep this local change or use the cloud '
                'version.'
            : 'Your choice applies to all $rejectedCount changes that need '
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
