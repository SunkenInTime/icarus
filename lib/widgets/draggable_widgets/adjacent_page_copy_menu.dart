import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:icarus/const/settings.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/l10n/l10n.dart';
import 'package:icarus/providers/strategy_provider.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

List<ShadContextMenuItem> buildAdjacentPageCopyMenuItems(
  WidgetRef ref,
  String widgetId,
) {
  if (widgetId.isEmpty) return const [];
  final notifier = ref.read(strategyProvider.notifier);
  return _copyMenuItems(
    ref.read(l10nProvider),
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
    ref.read(l10nProvider),
    notifier.copyDirectionsForLineUps(linkIds),
    (direction) => notifier.copyLineUpsToAdjacentPage(
      linkIds: linkIds,
      direction: direction,
    ),
  );
}

List<ShadContextMenuItem> _copyMenuItems(
  AppLocalizations l10n,
  List<PageTransitionDirection> directions,
  Future<PageCopyResult> Function(PageTransitionDirection direction) copyTo,
) {
  Future<void> copy(PageTransitionDirection direction) async {
    final result = await copyTo(direction);
    switch (result) {
      case PageCopyResult.alreadyThere:
        Settings.showToast(
          message: direction == PageTransitionDirection.forward
              ? l10n.canvasItemNextPageAlreadyHasIt
              : l10n.canvasItemPreviousPageAlreadyHasIt,
          backgroundColor: Settings.tacticalVioletTheme.primary,
        );
      case PageCopyResult.unreachable:
        Settings.showToast(
          message: l10n.canvasItemCopyUnreachable,
          backgroundColor: Settings.tacticalVioletTheme.destructive,
        );
      case PageCopyResult.notSaved:
        Settings.showToast(
          message: l10n.canvasItemCopyNotSaved,
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
        child: Text(l10n.canvasItemCopyToPreviousPage),
        onPressed: () => copy(PageTransitionDirection.backward),
      ),
    if (directions.contains(PageTransitionDirection.forward))
      ShadContextMenuItem(
        leading: const Icon(LucideIcons.arrowDown, size: 16),
        child: Text(l10n.canvasItemCopyToNextPage),
        onPressed: () => copy(PageTransitionDirection.forward),
      ),
  ];
}
