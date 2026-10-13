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

/// The open that is still running. Each open waits for the one before it,
/// so replays arriving together (Explorer starts one launch per selected
/// file) never interleave their navigation.
Future<void> _previousOpen = Future.value();

/// Brings replays opened from outside the Replays tab (dropped anywhere on
/// the window, or opened from Explorer) into Icarus the way Add Replay does,
/// then shows them: one replay opens in the viewer, several land on the
/// Replays tab. Leaving the editor goes through the unsaved-work guard;
/// staying there cancels the open, and nothing is added.
Future<void> openReplays(WidgetRef ref, List<String> paths) {
  final open = _previousOpen.then((_) => _openReplays(ref, paths));
  _previousOpen = open.catchError((Object _) {});
  return open;
}

Future<void> _openReplays(WidgetRef ref, List<String> paths) async {
  if (paths.isEmpty) return;
  if (!ref.read(platformPolicyProvider).supports(PlatformFeature.replays)) {
    return;
  }
  final navigator = appNavigatorKey.currentState;
  if (navigator == null) return;

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
        if (navigator.mounted) navigator.popUntil((route) => route.isFirst);
      },
    );
    if (!left || !navigator.mounted) return;
  }

  final listings = <ReplayListing>[];
  for (final path in paths) {
    try {
      listings.add(await ref.read(replayLibraryProvider.notifier).import(path));
    } catch (error, stackTrace) {
      AppErrorReporter.reportError(
        "Couldn't add ${p.basename(path)}.",
        error: error,
        stackTrace: stackTrace,
        source: 'openReplays',
      );
    }
  }
  if (!navigator.mounted) return;

  navigator.popUntil((route) => route.isFirst);
  ref.read(libraryNavigationProvider).showReplays();
  if (paths.length == 1 && listings.length == 1) {
    openReplayListing(navigator.context, listings.single);
  }
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
