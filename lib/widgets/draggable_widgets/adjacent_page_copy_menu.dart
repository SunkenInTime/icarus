import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

  return [
    if (directions.contains(PageTransitionDirection.backward))
      ShadContextMenuItem(
        leading: const Icon(Icons.arrow_upward),
        child: const Text('Copy to previous page'),
        onPressed: () async {
          await notifier.copyPlacedWidgetToAdjacentPage(
            widgetId: widgetId,
            direction: PageTransitionDirection.backward,
          );
        },
      ),
    if (directions.contains(PageTransitionDirection.forward))
      ShadContextMenuItem(
        leading: const Icon(Icons.arrow_downward),
        child: const Text('Copy to next page'),
        onPressed: () async {
          await notifier.copyPlacedWidgetToAdjacentPage(
            widgetId: widgetId,
            direction: PageTransitionDirection.forward,
          );
        },
      ),
  ];
}
