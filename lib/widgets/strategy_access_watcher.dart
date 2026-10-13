import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/collab/convex_strategy_repository.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/cloud_media_upload_queue_provider.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
import 'package:icarus/providers/collab/strategy_op_queue_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// Tells the reader when their access to the open cloud strategy changes
/// while they have it open. An owner making them a viewer gets a toast, and
/// the editor's own gates take away what they can no longer do. Losing
/// access altogether gets a dialog whose only way on is [onLeave], back to
/// the library.
class StrategyAccessWatcher extends ConsumerStatefulWidget {
  const StrategyAccessWatcher({
    super.key,
    required this.onLeave,
    required this.child,
  });

  /// Leaves the editor for the library.
  final Future<void> Function() onLeave;
  final Widget child;

  @override
  ConsumerState<StrategyAccessWatcher> createState() =>
      _StrategyAccessWatcherState();
}

/// The open strategy and the reader's role on it, as the server last said.
typedef _OpenRole = ({String strategyId, String? role});

class _StrategyAccessWatcherState extends ConsumerState<StrategyAccessWatcher> {
  bool _showingAccessLost = false;

  void _onRoleChanged(_OpenRole? previous, _OpenRole? next) {
    // Only a change on the strategy that stays open: opening another one
    // with less access is not a demotion.
    if (previous == null ||
        next == null ||
        previous.strategyId != next.strategyId ||
        next.role != 'viewer' ||
        !StrategyCapabilities.fromCloudRole(previous.role).canEditPages) {
      return;
    }
    Settings.showToast(
      message: 'Your access to this strategy changed to view only.',
      backgroundColor: Settings.tacticalVioletTheme.primary,
    );
  }

  /// Changes to [strategyId] this device still holds for the cloud, with
  /// images waiting to upload. None of them can be saved once access is
  /// gone.
  int _unsentChanges(String? strategyId) {
    final queue = ref.read(strategyOpQueueProvider);
    final uploads = ref
        .read(cloudMediaUploadQueueProvider)
        .jobs
        .where((job) => job.strategyPublicId == strategyId)
        .length;
    return queue.queuedByEntityKey.length +
        queue.inFlightByEntityKey.length +
        queue.pausedByEntityKey.length +
        queue.attentionByEntityKey.length +
        uploads;
  }

  /// Asks the server again, as [accountId], whether it still refuses
  /// [strategyId]: the dialog may have been open a while, and the owner may
  /// have given access back meanwhile.
  Future<_Recheck> _recheck(String strategyId, String accountId) async {
    bool sameAccount() =>
        ref.read(strategyOpQueueProvider).accountId == accountId;
    if (!sameAccount()) return _Recheck.unsure;
    try {
      await ref.read(convexStrategyRepositoryProvider).fetchShell(strategyId);
      return _Recheck.openAgain;
    } catch (error) {
      return isTypedConvexForbiddenError(error) && sameAccount()
          ? _Recheck.refused
          : _Recheck.unsure;
    }
  }

  /// Discards [accountId]'s unsent work for [strategyId] once the server
  /// has refused it again, and says what happened otherwise.
  Future<void> _discard(String strategyId, String accountId) async {
    void tell(String message) => Settings.showToast(
          message: message,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
    switch (await _recheck(strategyId, accountId)) {
      case _Recheck.openAgain:
        tell('You can open this strategy again, so nothing was discarded.');
        return;
      case _Recheck.unsure:
        tell("Couldn't confirm you lost access, so nothing was discarded.");
        return;
      case _Recheck.refused:
        break;
    }
    final removed = await ref
        .read(strategyOpQueueProvider.notifier)
        .discardUnsendableWork(strategyId, accountId: accountId);
    // Images go only with the changes that place them: an upload a change
    // still refers to (one being sent, say) stays.
    final uploadsGone = removed &&
        await ref
            .read(cloudMediaUploadQueueProvider.notifier)
            .discardUnreferencedJobs(strategyId, accountId: accountId);
    if (!uploadsGone) {
      tell("Couldn't discard everything. Try again from the library.");
    }
  }

  static String _unsentNote(int unsent) => switch (unsent) {
        0 => '',
        1 => " 1 change you made here hasn't reached the cloud and can't be "
            'saved.',
        _ => " $unsent changes you made here haven't reached the cloud and "
            "can't be saved.",
      };

  Future<void> _showAccessLost() async {
    if (_showingAccessLost) return;
    _showingAccessLost = true;
    final open = ref.read(strategyProvider);
    // A strategy refused as it opened never became the open one.
    final lost = ref.read(remoteEditorSnapshotProvider).error;
    final strategyId =
        lost is StrategyAccessLost ? lost.strategyPublicId : open.strategyId;
    final name =
        open.strategyId == strategyId ? open.strategyName?.trim() : null;
    final strategy = name == null || name.isEmpty ? 'this strategy' : '"$name"';
    final accountId = ref.read(strategyOpQueueProvider).accountId;
    final unsent = _unsentChanges(strategyId);
    bool? discard;
    try {
      discard = await showShadDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ShadDialog.alert(
          title: const Text('You no longer have access'),
          description: Text(
            'The owner removed you from $strategy, or stopped sharing it.'
            '${_unsentNote(unsent)}',
          ),
          actions: [
            if (unsent > 0)
              ShadButton.destructive(
                key: const ValueKey('access-lost-discard'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Discard'),
              ),
            ShadButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Back to library'),
            ),
          ],
        ),
      );
    } finally {
      _showingAccessLost = false;
    }
    if (!mounted) return;
    // Kept, they wait on this device: the library shows them, and leads
    // back here.
    if (discard == true && strategyId != null && accountId != null) {
      try {
        await _discard(strategyId, accountId);
      } catch (_) {
        Settings.showToast(
          message: "Couldn't discard everything. Try again from the library.",
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      }
      if (!mounted) return;
    }
    // Whatever the reader had open over the editor (a lineup dialog, a
    // menu) goes first, so leaving takes the editor itself off the stack.
    final editorRoute = ModalRoute.of(context);
    if (editorRoute != null) {
      Navigator.of(context).popUntil((route) => route == editorRoute);
    }
    await widget.onLeave();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<_OpenRole?>(
      remoteEditorSnapshotProvider.select((snapshot) {
        final header = snapshot.valueOrNull?.header;
        return header == null
            ? null
            : (strategyId: header.publicId, role: header.role);
      }),
      _onRoleChanged,
    );
    ref.listen<bool>(strategyAccessLostProvider, (previous, next) {
      if (next && previous != true) _showAccessLost();
    });
    return widget.child;
  }
}

/// What a second look at a refused strategy found.
enum _Recheck {
  /// Still refused, for the same account: its unsent work can go.
  refused,

  /// It opens again: the work may still land.
  openAgain,

  /// Offline, or the account changed: nothing is decided.
  unsure,
}
