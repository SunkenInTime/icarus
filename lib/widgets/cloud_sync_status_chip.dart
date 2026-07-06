import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/convex_connection_provider.dart';
import 'package:icarus/providers/collab/strategy_conflict_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/providers/strategy_save_state_provider.dart';
import 'package:icarus/strategy/strategy_page_models.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

const _chipSwitchDuration = Duration(milliseconds: 150);
const _conflictToastGap = Duration(seconds: 5);

enum _SyncStatus { synced, syncing, offline, attention }

/// Persistent cloud sync indicator for the strategy editor top strip.
///
/// Renders nothing for local strategies. For cloud strategies it shows one of
/// synced / syncing / offline / needs-attention, with a popover explaining the
/// state and offering retry when something failed. Also surfaces conflicts
/// (server rejected an edit and the view was rebased) as a toast — previously
/// those were collected and never shown.
class CloudSyncStatusChip extends ConsumerStatefulWidget {
  const CloudSyncStatusChip({super.key});

  @override
  ConsumerState<CloudSyncStatusChip> createState() =>
      _CloudSyncStatusChipState();
}

class _CloudSyncStatusChipState extends ConsumerState<CloudSyncStatusChip> {
  final ShadPopoverController _popoverController = ShadPopoverController();
  DateTime? _lastConflictToast;
  Timer? _pendingConflictToast;

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
      message:
          'A collaborator changed this page — your view was updated to the '
          'latest version.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
    ref.read(strategyConflictProvider.notifier).clearAll();
  }

  Future<void> _retry() async {
    _popoverController.hide();
    await ref
        .read(cloudMediaUploadQueueProvider.notifier)
        .retryNow(ignoreBackoff: true);
    final opQueue = ref.read(strategyOpQueueProvider.notifier);
    await opQueue.flushNow();
    // If everything queued was already dropped (max attempts), flushNow is a
    // no-op and the old error would pin the chip on "needs attention" with a
    // Retry that does nothing — clear it; the page has since rebased onto
    // the server state.
    opQueue.clearStaleError();
  }

  @override
  Widget build(BuildContext context) {
    final source =
        ref.watch(strategyProvider.select((state) => state.source));
    ref.listen(strategyConflictProvider, (previous, next) {
      _onConflicts(previous?.length ?? 0, next.length);
    });

    if (source != StrategySource.cloud) {
      return const SizedBox.shrink();
    }

    final saveState = ref.watch(strategySaveStateProvider);
    final isConnected = ref.watch(convexConnectionProvider).valueOrNull ?? true;

    final _SyncStatus status;
    if (!isConnected) {
      status = _SyncStatus.offline;
    } else if (saveState.cloudSyncError != null ||
        saveState.mediaSyncErrorCount > 0) {
      status = _SyncStatus.attention;
    } else if (saveState.isSaving ||
        saveState.hasPendingCloudSync ||
        saveState.hasPendingMediaSync) {
      status = _SyncStatus.syncing;
    } else {
      status = _SyncStatus.synced;
    }

    return ShadPopover(
      controller: _popoverController,
      padding: const EdgeInsets.all(14),
      anchor: const ShadAnchor(
        offset: Offset(0, 8),
        childAlignment: Alignment.topCenter,
        overlayAlignment: Alignment.bottomCenter,
      ),
      popover: (context) => _SyncStatusPopover(
        status: status,
        saveState: saveState,
        onRetry: _retry,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: _popoverController.toggle,
            child: AnimatedContainer(
              duration: _chipSwitchDuration,
              curve: Curves.easeOutCubic,
              height: 24,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: _chipBackground(status),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: _chipSwitchDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: _chipIcon(status),
                  ),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: _chipSwitchDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: Text(
                      _chipLabel(status),
                      key: ValueKey(status),
                      style: TextStyle(
                        color: _chipForeground(status),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _chipBackground(_SyncStatus status) {
    switch (status) {
      case _SyncStatus.attention:
        return Settings.tacticalVioletTheme.destructive
            .withValues(alpha: 0.14);
      case _SyncStatus.offline:
      case _SyncStatus.syncing:
      case _SyncStatus.synced:
        return Settings.tacticalVioletTheme.muted.withValues(alpha: 0.4);
    }
  }

  Color _chipForeground(_SyncStatus status) {
    switch (status) {
      case _SyncStatus.attention:
        return Settings.tacticalVioletTheme.destructive;
      case _SyncStatus.offline:
      case _SyncStatus.syncing:
      case _SyncStatus.synced:
        return Settings.tacticalVioletTheme.mutedForeground;
    }
  }

  Widget _chipIcon(_SyncStatus status) {
    final color = _chipForeground(status);
    switch (status) {
      case _SyncStatus.synced:
        return Icon(
          Icons.cloud_done_outlined,
          key: const ValueKey('synced'),
          size: 13,
          color: color,
        );
      case _SyncStatus.syncing:
        return SizedBox(
          key: const ValueKey('syncing'),
          width: 11,
          height: 11,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        );
      case _SyncStatus.offline:
        return Icon(
          Icons.cloud_off_outlined,
          key: const ValueKey('offline'),
          size: 13,
          color: color,
        );
      case _SyncStatus.attention:
        return Icon(
          Icons.error_outline,
          key: const ValueKey('attention'),
          size: 13,
          color: color,
        );
    }
  }

  String _chipLabel(_SyncStatus status) {
    switch (status) {
      case _SyncStatus.synced:
        return 'Synced';
      case _SyncStatus.syncing:
        return 'Syncing…';
      case _SyncStatus.offline:
        return 'Offline';
      case _SyncStatus.attention:
        return 'Needs attention';
    }
  }
}

class _SyncStatusPopover extends StatelessWidget {
  const _SyncStatusPopover({
    required this.status,
    required this.saveState,
    required this.onRetry,
  });

  final _SyncStatus status;
  final StrategySaveState saveState;
  final Future<void> Function() onRetry;

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
          if (status == _SyncStatus.attention) ...[
            const SizedBox(height: 12),
            ShadButton(
              size: ShadButtonSize.sm,
              onPressed: onRetry,
              leading: const Icon(LucideIcons.refreshCw, size: 14),
              child: const Text('Retry sync'),
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
      case _SyncStatus.syncing:
        return 'Your edits are being sent to the cloud. You can keep '
            'working — this happens in the background.';
      case _SyncStatus.offline:
        return 'Changes are kept on this device and will sync automatically '
            'when your connection returns.';
      case _SyncStatus.attention:
        return _attentionExplanation;
    }
  }

  String get _attentionExplanation {
    final mediaErrors = saveState.mediaSyncErrorCount;
    final parts = <String>[];
    final error = saveState.cloudSyncError;
    if (error != null) {
      parts.add(_friendlyError(error));
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
    parts.add('Retry to send them now.');
    return parts.join(' ');
  }

  static String _friendlyError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('auth')) {
      return 'Your cloud session needs to be refreshed — retry, or sign in '
          'again from the library.';
    }
    if (lower.contains('offline') || lower.contains('connection')) {
      return 'The cloud could not be reached.';
    }
    if (lower.contains('setup is not ready')) {
      return 'Cloud sync is still starting up.';
    }
    return "Some changes haven't reached the cloud yet.";
  }

  static String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
