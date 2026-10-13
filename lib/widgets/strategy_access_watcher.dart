import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/providers/collab/remote_strategy_snapshot_provider.dart';
import 'package:icarus/providers/collab/strategy_capabilities_provider.dart';
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

  Future<void> _showAccessLost() async {
    if (_showingAccessLost) return;
    _showingAccessLost = true;
    final name = ref.read(strategyProvider).strategyName?.trim();
    final strategy = name == null || name.isEmpty ? 'this strategy' : '"$name"';
    try {
      await showShadDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => ShadDialog.alert(
          title: const Text('You no longer have access'),
          description: Text(
            'The owner removed you from $strategy, or stopped sharing it.',
          ),
          actions: [
            ShadButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to library'),
            ),
          ],
        ),
      );
    } finally {
      _showingAccessLost = false;
    }
    if (!mounted) return;
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
