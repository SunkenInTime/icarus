import 'package:flutter/foundation.dart';
import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/placed_classes.dart';
import 'package:icarus/const/transition_data.dart';
import 'package:icarus/providers/drawing_provider.dart';
import 'package:icarus/providers/strategy_page.dart';

/// Shared page-transition planning used by both the live page switch and the
/// video exporter, so the two can never drift apart.
class TransitionPlanner {
  const TransitionPlanner._();

  static Map<String, PlacedWidget> placedWidgetMap({
    required List<PlacedAgentNode> agents,
    required List<PlacedAbility> abilities,
    required List<PlacedText> text,
    required List<PlacedImage> images,
    required List<PlacedUtility> utilities,
  }) {
    final map = <String, PlacedWidget>{};
    for (final a in agents) {
      map[a.id] = a;
    }
    for (final ab in abilities) {
      map[ab.id] = ab;
    }
    for (final t in text) {
      map[t.id] = t;
    }
    for (final img in images) {
      map[img.id] = img;
    }
    for (final u in utilities) {
      map[u.id] = u;
    }
    return map;
  }

  static Map<String, PlacedWidget> placedWidgetMapForPage(StrategyPage page) {
    return placedWidgetMap(
      agents: page.agentData,
      abilities: page.abilityData,
      text: page.textData,
      images: page.imageData,
      utilities: page.utilityData,
    );
  }

  static List<PageTransitionEntry> diff(
    Map<String, PlacedWidget> prev,
    Map<String, PlacedWidget> next,
  ) {
    final entries = <PageTransitionEntry>[];
    var order = 0;

    // Move / appear
    next.forEach((id, to) {
      final from = prev[id];
      if (from != null) {
        if (from.position != to.position ||
            PageTransitionEntry.rotationOf(from) !=
                PageTransitionEntry.rotationOf(to) ||
            PageTransitionEntry.lengthOf(from) !=
                PageTransitionEntry.lengthOf(to) ||
            !listEquals(
              PageTransitionEntry.armLengthsOf(from),
              PageTransitionEntry.armLengthsOf(to),
            ) ||
            PageTransitionEntry.scaleOf(from) !=
                PageTransitionEntry.scaleOf(to) ||
            PageTransitionEntry.textSizeOf(from) !=
                PageTransitionEntry.textSizeOf(to) ||
            PageTransitionEntry.agentStateOf(from) !=
                PageTransitionEntry.agentStateOf(to) ||
            PageTransitionEntry.customDiameterOf(from) !=
                PageTransitionEntry.customDiameterOf(to) ||
            PageTransitionEntry.customWidthOf(from) !=
                PageTransitionEntry.customWidthOf(to) ||
            PageTransitionEntry.customLengthOf(from) !=
                PageTransitionEntry.customLengthOf(to)) {
          entries
              .add(PageTransitionEntry.move(from: from, to: to, order: order));
        } else {
          // Unchanged: include as 'none' so it stays visible while base view is hidden
          entries.add(PageTransitionEntry.none(to: to, order: order));
        }
      } else {
        entries.add(PageTransitionEntry.appear(to: to, order: order));
      }
      order++;
    });

    // Disappear
    prev.forEach((id, from) {
      if (!next.containsKey(id)) {
        entries.add(PageTransitionEntry.disappear(from: from, order: order));
        order++;
      }
    });

    return entries;
  }

  /// Whether the drawing layer changes between two pages, and therefore
  /// whether it should fade in early during the transition. Compares the
  /// serialized form so geometry/style edits count, not just added or
  /// removed strokes.
  static bool drawingsChanged(
    List<DrawingElement> prev,
    List<DrawingElement> next,
  ) {
    if (identical(prev, next)) return false;
    if (prev.length != next.length) return true;
    return DrawingProvider.objectToJson(prev) !=
        DrawingProvider.objectToJson(next);
  }
}
