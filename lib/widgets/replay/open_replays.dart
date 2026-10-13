import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/config/platform_policy.dart';
import 'package:icarus/const/app_navigator.dart';
import 'package:icarus/const/routes.dart';
import 'package:icarus/providers/agent_filter_provider.dart';
import 'package:icarus/providers/delete_menu_provider.dart';
import 'package:icarus/providers/interaction_state_provider.dart';
import 'package:icarus/providers/library_navigation_provider.dart';
import 'package:icarus/providers/replay_library_provider.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:icarus/replay/replay_files.dart';
import 'package:icarus/services/app_error_reporter.dart';
import 'package:icarus/services/unsaved_strategy_guard.dart';
import 'package:icarus/widgets/mouse_navigation.dart';
import 'package:icarus/widgets/replay/replay_library_content.dart';
import 'package:path/path.dart' as p;

bool isReplayPath(String path) =>
    p.extension(path).toLowerCase() == ReplayFiles.extension;

/// Opens waiting their turn. Each runs after the one before it finishes,
/// so two arriving together (a drop and an Explorer open, or two Explorer
/// opens) never interleave their navigation or stack two guard dialogs.
final _waiting = <({WidgetRef ref, List<String> paths})>[];
var _opening = false;

/// Brings replays opened from outside the Replays tab (dropped anywhere on
/// the window, or opened from Explorer) into Icarus the way Add Replay does,
/// then shows them: one replay opens in the viewer, several land on the
/// Replays tab, and files that aren't readable replays only get the add's
/// toast. Leaving the editor goes through the unsaved-work guard; staying
/// keeps the editor, with the replays already added.
Future<void> openReplays(WidgetRef ref, List<String> paths) async {
  _waiting.add((ref: ref, paths: paths));
  if (_opening) return;
  _opening = true;
  try {
    while (_waiting.isNotEmpty) {
      final next = _waiting.removeAt(0);
      try {
        await _openReplays(next.ref, next.paths);
      } catch (error, stackTrace) {
        AppErrorReporter.reportError(
          "Couldn't open the replay.",
          error: error,
          stackTrace: stackTrace,
          source: 'openReplays',
        );
      }
    }
  } finally {
    _opening = false;
  }
}

Future<void> _openReplays(WidgetRef ref, List<String> paths) async {
  if (paths.isEmpty) return;
  if (!ref.read(platformPolicyProvider).supports(PlatformFeature.replays)) {
    return;
  }

  // Adds them the way Add Replay does, with its toast and its reveal. When
  // none could be added, that toast has said why and there is nothing to
  // show.
  final result = await addReplays(ref, paths);
  final shown = [...?result?.added, ...?result?.alreadyListed];
  if (shown.isEmpty) return;
  // One replay opens in the viewer.
  final listing = paths.length == 1 && shown.length == 1
      ? ref
          .read(replayLibraryProvider)
          .valueOrNull
          ?.where((listing) => listing.file.path == shown.single)
          .firstOrNull
      : null;

  // From here to the navigation nothing waits but the guard's own dialog,
  // so whatever is on screen now is what gets left.
  final navigator = appNavigatorKey.currentState;
  if (navigator == null || !navigator.mounted) return;
  final inEditor = ref.read(strategyProvider).stratName != null ||
      mouseNavigationRouteObserver.topRoute?.settings.name ==
          Routes.strategyView;
  if (inEditor) {
    final left = await guardUnsavedStrategyExit(
      context: navigator.context,
      ref: ref,
      source: 'openReplays',
      onContinue: () async {
        ref
            .read(interactionStateProvider.notifier)
            .update(InteractionState.navigation);
        ref
            .read(agentFilterProvider.notifier)
            .updateFilterState(FilterState.all);
        ref.read(deleteMenuProvider.notifier).requestClose();
        await ref.read(strategyProvider.notifier).clearCurrentStrategy();
      },
    );
    if (!left || !navigator.mounted) return;
  }

  navigator.popUntil((route) => route.isFirst);
  ref.read(libraryNavigationProvider).showReplays();
  if (listing != null) openReplayListing(navigator.context, listing);
}

/// Catches .vrf files dropped anywhere on the window. Other files go on to
/// whichever drop target sits under the pointer, which skips replays.
class ReplayWindowDropTarget extends ConsumerWidget {
  const ReplayWindowDropTarget({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(platformPolicyProvider).supports(PlatformFeature.replays)) {
      return child;
    }
    return DropTarget(
      onDragDone: (details) {
        final replays = [
          for (final file in details.files)
            if (isReplayPath(file.path)) file.path,
        ];
        if (replays.isNotEmpty) unawaited(openReplays(ref, replays));
      },
      child: child,
    );
  }
}
