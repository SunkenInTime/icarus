import 'package:icarus/const/drawing_element.dart';
import 'package:icarus/const/page_copy_id.dart';
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
    final copiedFrom = _pairedCopies(prev, next);
    final paired = copiedFrom.values.toSet();

    // Move / appear
    next.forEach((id, to) {
      final from = prev[id] ?? prev[copiedFrom[id]];
      if (from != null) {
        if (PageTransitionEntry.visualsDiffer(from, to)) {
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
      if (!next.containsKey(id) && !paired.contains(id)) {
        entries.add(PageTransitionEntry.disappear(from: from, order: order));
        order++;
      }
    });

    return entries;
  }

  /// Items of [next] paired with an item of [prev] by the id they were
  /// copied from (see page_copy_id.dart), next id to prev id. Items with
  /// the same id pair first. Then a root pairs two items only when it is on
  /// each page exactly once and both are the same kind of item; anything
  /// else would be a guess, so those items appear and disappear instead.
  static Map<String, String> _pairedCopies(
    Map<String, PlacedWidget> prev,
    Map<String, PlacedWidget> next,
  ) {
    Map<String, List<String>> byRoot(Map<String, PlacedWidget> page) {
      final roots = <String, List<String>>{};
      for (final id in page.keys) {
        (roots[pageCopyRoot(id)] ??= []).add(id);
      }
      return roots;
    }

    final prevByRoot = byRoot(prev);
    final nextByRoot = byRoot(next);
    final pairs = <String, String>{};
    nextByRoot.forEach((root, nextIds) {
      final prevIds = prevByRoot[root];
      if (nextIds.length != 1 || prevIds == null || prevIds.length != 1) {
        return;
      }
      final nextId = nextIds.single;
      final prevId = prevIds.single;
      if (nextId == prevId) return;
      if (next.containsKey(prevId) || prev.containsKey(nextId)) return;
      if (next[nextId]!.runtimeType != prev[prevId]!.runtimeType) return;
      pairs[nextId] = prevId;
    });
    return pairs;
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
