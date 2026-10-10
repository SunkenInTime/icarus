import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

List<ShadContextMenuItem> buildAdjacentPageCopyMenuItems(
  WidgetRef ref,
  String widgetId,
) {
  if (widgetId.isEmpty) return const [];
  final notifier = ref.read(strategyProvider.notifier);
  return _copyMenuItems(
    notifier.copyDirectionsForPlacedWidget(widgetId),
    (direction) => notifier.copyPlacedWidgetToAdjacentPage(
      widgetId: widgetId,
      direction: direction,
    ),
  );
}

/// The same items for the lineups [linkIds]: every lineup at the spot the
/// user right-clicked, copied together with the spots they aim at.
List<ShadContextMenuItem> buildLineUpAdjacentPageCopyMenuItems(
  WidgetRef ref,
  Set<String> linkIds,
) {
  if (linkIds.isEmpty) return const [];
  final notifier = ref.read(strategyProvider.notifier);
  return _copyMenuItems(
    notifier.copyDirectionsForLineUps(linkIds),
    (direction) => notifier.copyLineUpsToAdjacentPage(
      linkIds: linkIds,
      direction: direction,
    ),
  );
}

List<ShadContextMenuItem> _copyMenuItems(
  List<PageTransitionDirection> directions,
  Future<PageCopyResult> Function(PageTransitionDirection direction) copyTo,
) {
  Future<void> copy(PageTransitionDirection direction) async {
    final result = await copyTo(direction);
    final page = direction == PageTransitionDirection.forward
        ? 'next page'
        : 'previous page';
    switch (result) {
      case PageCopyResult.alreadyThere:
        Settings.showToast(
          message: 'The $page already has it.',
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      case PageCopyResult.unreachable:
        Settings.showToast(
          message: "Couldn't reach the cloud, so nothing was copied.",
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      case PageCopyResult.notSaved:
        Settings.showToast(
          message: "Couldn't save the copy on this device, so nothing was "
              'copied.',
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      case PageCopyResult.copied || PageCopyResult.unavailable:
        break;
    }
  }

  return [
    if (directions.contains(PageTransitionDirection.backward))
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.arrowUp, size: 16),
        child: const Text('Copy to previous page'),
        onPressed: () => copy(PageTransitionDirection.backward),
      ),
    if (directions.contains(PageTransitionDirection.forward))
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.arrowDown, size: 16),
        child: const Text('Copy to next page'),
        onPressed: () => copy(PageTransitionDirection.forward),
      ),
  ];
}
