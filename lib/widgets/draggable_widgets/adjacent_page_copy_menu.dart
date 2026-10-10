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
  final directions = notifier.copyDirectionsForPlacedWidget(widgetId);

  Future<void> copy(PageTransitionDirection direction) async {
    final result = await notifier.copyPlacedWidgetToAdjacentPage(
      widgetId: widgetId,
      direction: direction,
    );
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
